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

  describe "day_entry/1" do
    test "resolves the version in force and the date's weekday entry" do
      # 2026-10-04 is a Sunday (7); the new version differs only on Sundays
      attrs = attrs_with_day(7, %{morning_start: ~T[08:00:00], early_bird_cutoff: ~T[09:00:00]})
      {:ok, _} = Schedules.change(attrs, ~U[2026-10-04 12:00:00Z])

      sunday_after = DateTime.new!(~D[2026-10-04], ~T[06:00:00], "America/Los_Angeles")
      sunday_before = DateTime.new!(~D[2026-10-04], ~T[04:59:00], "America/Los_Angeles")
      monday_after = DateTime.new!(~D[2026-10-05], ~T[06:00:00], "America/Los_Angeles")

      assert Schedules.day_entry(sunday_after).morning_start == ~T[08:00:00]
      assert Schedules.day_entry(sunday_before).morning_start == ~T[05:00:00]
      assert Schedules.day_entry(monday_after).morning_start == ~T[05:00:00]
      assert Schedules.day_entry(monday_after).weekday == 1
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

  describe "Night Owl cutoffs and bonus" do
    defp owl_attrs(weekday, cutoffs, overrides \\ %{}) do
      attrs_with_day(weekday, %{night_owl_cutoffs: cutoffs}, overrides)
    end

    defp cutoff_errors(cs, weekday) do
      [failed] = Enum.filter(cs.changes.days, &(&1.errors != [] or not &1.valid?))
      assert Ecto.Changeset.get_field(failed, :weekday) == weekday
      failed |> Ecto.Changeset.get_change(:night_owl_cutoffs, []) |> Enum.map(&errors_on/1)
    end

    test "a day holds one cutoff per kid and the version one bonus" do
      attrs =
        owl_attrs(2, [%{kid_id: 1, cutoff: ~T[21:00:00]}, %{kid_id: 2, cutoff: ~T[20:00:00]}], %{
          night_owl_bonus: 3
        })

      assert {:ok, v} = Schedules.change(attrs, @t0)
      assert v.night_owl_bonus == 3

      assert [%{kid_id: 1, cutoff: ~T[21:00:00]}, %{kid_id: 2, cutoff: ~T[20:00:00]}] =
               day(Schedules.current(), 2).night_owl_cutoffs

      assert day(Schedules.current(), 3).night_owl_cutoffs == []
    end

    test "a kid may have no cutoff on a day, and a blank cutoff is dropped" do
      attrs =
        owl_attrs(2, [%{kid_id: 1, cutoff: ~T[21:00:00]}, %{kid_id: 2, cutoff: ""}], %{
          night_owl_bonus: 3
        })

      assert {:ok, v} = Schedules.change(attrs, @t0)
      assert [%{kid_id: 1}] = day(v, 2).night_owl_cutoffs
    end

    test "a cutoff must fall strictly inside that day's evening window, on that kid's field" do
      for bad <- [~T[17:00:00], ~T[23:00:00], ~T[16:00:00], ~T[23:30:00]] do
        attrs = owl_attrs(4, [%{kid_id: 1, cutoff: ~T[20:00:00]}, %{kid_id: 2, cutoff: bad}])
        assert {:error, cs} = Schedules.change(attrs, @t0)
        assert [%{}, %{cutoff: ["must fall inside the evening window"]}] = cutoff_errors(cs, 4)
      end
    end

    test "the window checked is that day's own" do
      attrs = owl_attrs(4, [%{kid_id: 1, cutoff: ~T[22:00:00]}])

      attrs = %{
        attrs
        | days:
            Enum.map(
              attrs.days,
              &if(&1.weekday == 4, do: %{&1 | evening_end: ~T[21:00:00]}, else: &1)
            )
      }

      assert {:error, _} = Schedules.change(attrs, @t0)
    end

    test "two cutoffs for one kid on a day are refused" do
      attrs =
        owl_attrs(5, [%{kid_id: 1, cutoff: ~T[20:00:00]}, %{kid_id: 1, cutoff: ~T[21:00:00]}])

      assert {:error, cs} = Schedules.change(attrs, @t0)
      assert [%{}, %{kid_id: [_]}] = cutoff_errors(cs, 5)
    end

    test "a malformed cutoff is refused on that kid's field, not a crash" do
      attrs = owl_attrs(4, [%{kid_id: 1, cutoff: "garbage"}])
      assert {:error, cs} = Schedules.change(attrs, @t0)
      assert [%{cutoff: [_]}] = cutoff_errors(cs, 4)
    end

    test "the same kid on different days is fine" do
      attrs = owl_attrs(5, [%{kid_id: 1, cutoff: ~T[20:00:00]}], %{night_owl_bonus: 1})

      attrs =
        Map.update!(attrs, :days, fn days ->
          Enum.map(days, fn
            %{weekday: 6} = d ->
              Map.put(d, :night_owl_cutoffs, [%{kid_id: 1, cutoff: ~T[20:00:00]}])

            d ->
              d
          end)
        end)

      assert {:ok, _} = Schedules.change(attrs, @t0)
    end

    test "the bonus is required and non-negative; zero is accepted" do
      assert {:error, cs} = Schedules.change(valid_attrs(%{night_owl_bonus: nil}), @t0)
      assert errors_on(cs).night_owl_bonus != []
      assert {:error, cs} = Schedules.change(valid_attrs(%{night_owl_bonus: -1}), @t0)
      assert errors_on(cs).night_owl_bonus != []

      assert {:ok, v} =
               Schedules.change(valid_attrs(%{night_owl_bonus: 0, routine_bonus: 6}), @t0)

      assert v.night_owl_bonus == 0
    end

    test "a version stored in the pre-migration shape loads with no cutoffs and N = 0" do
      days =
        for w <- 1..7 do
          %{
            "weekday" => w,
            "morning_start" => "05:00:00",
            "morning_end" => "17:00:00",
            "evening_start" => "17:00:00",
            "evening_end" => "23:00:00",
            "early_bird_cutoff" => "07:45:00"
          }
        end

      Repo.query!(
        "INSERT INTO schedule_versions (effective_at, routine_bonus, early_bird_bonus, days, inserted_at, updated_at) VALUES (?, 5, 2, ?, ?, ?)",
        ["2026-01-01T00:00:00", Jason.encode!(days), "2026-01-01T00:00:00", "2026-01-01T00:00:00"]
      )

      old = Enum.find(Schedules.versions(), &(&1.effective_at.year == 2026))
      assert old.night_owl_bonus == 0
      assert Enum.all?(old.days, &(&1.night_owl_cutoffs == []))
    end

    test "the staging helpers carry N and every day's cutoffs forward" do
      cutoffs = [%{kid_id: 1, cutoff: ~T[20:00:00]}]
      {:ok, _} = Schedules.change(owl_attrs(2, cutoffs, %{night_owl_bonus: 3}), @t0)

      for restage <- [
            fn ->
              BearCub.ScheduleHelpers.put_windows(
                {~T[05:00:00], ~T[17:00:00]},
                {~T[17:00:00], ~T[23:00:00]}
              )
            end,
            fn -> BearCub.ScheduleHelpers.put_cutoff(~T[07:00:00]) end,
            fn -> BearCub.ScheduleHelpers.put_bonuses(6, 3, DateTime.add(@t0, 60)) end
          ] do
        restage.()
        current = Schedules.current()
        assert current.night_owl_bonus == 3
        assert [%{kid_id: 1, cutoff: ~T[20:00:00]}] = day(current, 2).night_owl_cutoffs
        assert day(current, 3).night_owl_cutoffs == []
      end
    end

    test "a save changing only N records a new version" do
      assert {:ok, v} = Schedules.change(valid_attrs(%{night_owl_bonus: 4}), @t0)
      assert length(Schedules.versions()) == 2
      assert v.night_owl_bonus == 4
    end

    test "a save changing only one kid's cutoff on one day records a new version" do
      cutoffs = fn t -> [%{kid_id: 1, cutoff: ~T[20:00:00]}, %{kid_id: 2, cutoff: t}] end

      {:ok, _} =
        Schedules.change(owl_attrs(2, cutoffs.(~T[21:00:00]), %{night_owl_bonus: 3}), @t0)

      assert {:ok, _} =
               Schedules.change(
                 owl_attrs(2, cutoffs.(~T[21:30:00]), %{night_owl_bonus: 3}),
                 DateTime.add(@t0, 5)
               )

      assert length(Schedules.versions()) == 3
    end

    test "a save matching bonus and cutoffs, in any order, records and broadcasts nothing" do
      {:ok, current} =
        Schedules.change(
          owl_attrs(
            2,
            [%{kid_id: 1, cutoff: ~T[20:00:00]}, %{kid_id: 2, cutoff: ~T[21:00:00]}],
            %{night_owl_bonus: 3}
          ),
          @t0
        )

      Schedules.subscribe()

      reordered =
        owl_attrs(2, [%{kid_id: 2, cutoff: ~T[21:00:00]}, %{kid_id: 1, cutoff: ~T[20:00:00]}], %{
          night_owl_bonus: 3
        })

      assert {:ok, ^current} = Schedules.change(reordered, DateTime.add(@t0, 5))
      assert length(Schedules.versions()) == 2
      refute_receive :schedule_changed
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
