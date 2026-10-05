defmodule BearCub.SchedulesTest do
  use BearCub.DataCase

  import BearCub.SchedulesFixtures

  alias BearCub.Schedules
  alias BearCub.Schedules.ScheduleVersion

  @epoch ~U[1970-01-01 00:00:00Z]
  @t0 ~U[2026-10-04 12:00:00Z]

  defp day(version, weekday), do: Enum.find(version.days, &(&1.weekday == weekday))

  describe "version 0 (SC-5)" do
    test "is the only version after migration, in force from the epoch" do
      assert [%ScheduleVersion{effective_at: @epoch}] = Schedules.versions()
    end

    test "round-trips through the schema with production's values on all seven days" do
      v0 = Schedules.current()

      assert v0.routine_bonus == 5
      assert v0.early_bird_bonus == 2
      assert Enum.map(v0.days, & &1.weekday) |> Enum.sort() == [1, 2, 3, 4, 5, 6, 7]

      for d <- v0.days do
        assert d.morning_start == ~T[05:00:00]
        assert d.morning_end == ~T[17:00:00]
        assert d.evening_start == ~T[17:00:00]
        assert d.evening_end == ~T[23:00:00]
        assert d.early_bird_cutoff == ~T[07:45:00]
      end
    end
  end

  describe "change/2" do
    test "inserts a new version effective at the given now, leaving earlier ones alone" do
      before = Schedules.versions()

      assert {:ok, %ScheduleVersion{} = v} =
               Schedules.change(valid_attrs(%{routine_bonus: 9}), @t0)

      assert v.effective_at == @t0
      assert v.routine_bonus == 9
      assert Schedules.current().id == v.id
      assert Schedules.versions() == before ++ [v]
    end

    test "each day can carry its own timings (SC-2)" do
      attrs = attrs_with_day(6, %{morning_start: ~T[08:00:00], early_bird_cutoff: ~T[09:30:00]})

      assert {:ok, v} = Schedules.change(attrs, @t0)
      assert day(v, 6).morning_start == ~T[08:00:00]
      assert day(v, 6).early_bird_cutoff == ~T[09:30:00]
      assert day(v, 5).morning_start == ~T[05:00:00]
      assert day(v, 5).early_bird_cutoff == ~T[07:45:00]
    end

    test "seven distinct days persist per weekday and reload intact (SC-2)" do
      days =
        for w <- 1..7 do
          day_attrs(w, %{
            morning_start: Time.new!(w, 0, 0),
            early_bird_cutoff: Time.new!(w + 7, 30, 0)
          })
        end

      assert {:ok, _} = Schedules.change(valid_attrs(%{days: days}), @t0)

      reloaded = Schedules.current()

      for w <- 1..7 do
        assert day(reloaded, w).morning_start == Time.new!(w, 0, 0)
        assert day(reloaded, w).early_bird_cutoff == Time.new!(w + 7, 30, 0)
      end
    end

    test "a save identical to the one in force records nothing and broadcasts nothing" do
      Schedules.subscribe()
      current = Schedules.current()

      assert {:ok, ^current} = Schedules.change(valid_attrs(), @t0)
      assert length(Schedules.versions()) == 1
      refute_receive :schedule_changed
    end

    test "broadcasts :schedule_changed on a successful save" do
      Schedules.subscribe()
      assert {:ok, _} = Schedules.change(valid_attrs(%{early_bird_bonus: 0}), @t0)
      assert_receive :schedule_changed
    end

    test "does not broadcast a refused save" do
      Schedules.subscribe()
      assert {:error, _} = Schedules.change(valid_attrs(%{routine_bonus: -1}), @t0)
      refute_receive :schedule_changed
    end

    test "a second save in the same second is refused as a changeset error" do
      assert {:ok, _} = Schedules.change(valid_attrs(%{routine_bonus: 6}), @t0)
      assert {:error, cs} = Schedules.change(valid_attrs(%{routine_bonus: 7}), @t0)
      assert "has already been taken" in errors_on(cs).effective_at
      assert Schedules.current().routine_bonus == 6
    end

    test "now defaults to the clock at the context boundary" do
      assert {:ok, v} = Schedules.change(valid_attrs(%{routine_bonus: 8}))
      assert DateTime.diff(DateTime.utc_now(), v.effective_at) in 0..5
    end
  end

  describe "validation (SC-2, SC-3)" do
    # The errors keyed by field on the one day entry that failed, asserting it is `weekday`'s
    # (replaced prefill entries also ride along in `days`, always valid).
    defp day_errors(cs, weekday) do
      [failed] = Enum.filter(cs.changes.days, &(&1.errors != []))
      assert Ecto.Changeset.get_field(failed, :weekday) == weekday
      errors_on(failed)
    end

    test "a window whose start is not before its end is refused on that day and field" do
      attrs = attrs_with_day(3, %{morning_start: ~T[17:00:00]})
      assert {:error, cs} = Schedules.change(attrs, @t0)
      assert %{morning_end: [_]} = day_errors(cs, 3)

      attrs = attrs_with_day(3, %{evening_start: ~T[23:00:00]})
      assert {:error, cs} = Schedules.change(attrs, @t0)
      assert %{evening_end: [_]} = day_errors(cs, 3)
    end

    test "the morning ending after the evening starts is refused" do
      attrs = attrs_with_day(2, %{morning_end: ~T[17:30:00]})
      assert {:error, cs} = Schedules.change(attrs, @t0)
      assert %{evening_start: [_]} = day_errors(cs, 2)
    end

    test "the morning ending exactly when the evening starts is allowed" do
      assert {:ok, _} = Schedules.change(attrs_with_day(2, %{morning_end: ~T[17:00:00]}), @t0)
    end

    test "the cutoff must fall strictly inside the morning window" do
      for bad <- [~T[05:00:00], ~T[17:00:00], ~T[04:00:00], ~T[18:00:00]] do
        attrs = attrs_with_day(1, %{early_bird_cutoff: bad})
        assert {:error, cs} = Schedules.change(attrs, @t0)
        assert %{early_bird_cutoff: [_]} = day_errors(cs, 1)
      end
    end

    test "negative bonuses are refused; zero is allowed" do
      assert {:error, cs} = Schedules.change(valid_attrs(%{routine_bonus: -1}), @t0)
      assert errors_on(cs).routine_bonus != []
      assert {:error, cs} = Schedules.change(valid_attrs(%{early_bird_bonus: -1}), @t0)
      assert errors_on(cs).early_bird_bonus != []
      assert {:ok, _} = Schedules.change(valid_attrs(%{early_bird_bonus: 0}), @t0)
    end

    test "days must be exactly one entry per weekday 1-7" do
      for days <- [
            Enum.map(1..6, &day_attrs/1),
            Enum.map(1..8, &day_attrs/1),
            Enum.map([1, 2, 3, 4, 5, 6, 6], &day_attrs/1),
            Enum.map([0, 1, 2, 3, 4, 5, 6], &day_attrs/1)
          ] do
        assert {:error, cs} = Schedules.change(valid_attrs(%{days: days}), @t0)
        assert errors_on(cs).days != []
      end
    end
  end

  describe "change_version/1" do
    test "is prefilled from the version in force" do
      cs = Schedules.change_version()
      assert Ecto.Changeset.get_field(cs, :routine_bonus) == 5
      assert length(Ecto.Changeset.get_field(cs, :days)) == 7
    end

    test "layers submitted attrs over the prefill" do
      cs = Schedules.change_version(%{routine_bonus: 11})
      assert Ecto.Changeset.get_field(cs, :routine_bonus) == 11
      assert Ecto.Changeset.get_field(cs, :early_bird_bonus) == 2
    end
  end

  describe "append-only (D120)" do
    test "the context exposes no update or delete path" do
      names = Schedules.__info__(:functions) |> Enum.map(&elem(&1, 0)) |> Enum.map(&to_string/1)
      refute Enum.any?(names, &String.match?(&1, ~r/^(update|delete|remove|put)/))
    end
  end
end
