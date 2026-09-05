defmodule BearCub.ChoresTest do
  use BearCub.DataCase

  alias BearCub.Chores
  alias BearCub.Chores.Completion
  alias BearCub.Chores.Kid
  alias BearCub.Routines

  describe "kids" do
    import BearCub.ChoresFixtures

    @invalid_attrs %{name: nil, color: nil, position: nil}

    test "list_kids/0 returns kids ordered by position" do
      right = kid_fixture(%{name: "Kid B", position: 1})
      left = kid_fixture(%{name: "Kid A", position: 0})

      assert Chores.list_kids() == [left, right]
    end

    test "get_kid!/1 returns the kid with given id" do
      kid = kid_fixture()
      assert Chores.get_kid!(kid.id) == kid
    end

    test "get_kid/1 returns nil for a vanished kid instead of raising" do
      kid = kid_fixture()
      assert Chores.get_kid(kid.id) == kid

      Repo.delete!(kid)
      assert Chores.get_kid(kid.id) == nil
    end

    test "create_kid/1 with valid data creates a kid" do
      valid_attrs = %{name: "Kid A", color: "#f59e0b", position: 0}

      assert {:ok, %Kid{} = kid} = Chores.create_kid(valid_attrs)
      assert kid.name == "Kid A"
      assert kid.color == "#f59e0b"
      assert kid.position == 0
    end

    test "create_kid/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Chores.create_kid(@invalid_attrs)
    end

    test "create_kid/1 rejects a non-hex color" do
      attrs = %{name: "Kid A", color: "amber", position: 0}

      assert {:error, changeset} = Chores.create_kid(attrs)
      assert %{color: ["must be a hex color like #f59e0b"]} = errors_on(changeset)
    end

    test "create_kid/1 rejects a negative position" do
      attrs = %{name: "Kid A", color: "#f59e0b", position: -1}

      assert {:error, changeset} = Chores.create_kid(attrs)
      assert %{position: _} = errors_on(changeset)
    end

    test "update_kid/2 with valid data updates the kid" do
      kid = kid_fixture()

      assert {:ok, %Kid{} = kid} = Chores.update_kid(kid, %{name: "Renamed", color: "#22c55e"})
      assert kid.name == "Renamed"
      assert kid.color == "#22c55e"
    end

    test "update_kid/2 with invalid data returns error changeset" do
      kid = kid_fixture()

      assert {:error, %Ecto.Changeset{}} = Chores.update_kid(kid, @invalid_attrs)
      assert kid == Chores.get_kid!(kid.id)
    end

    test "change_kid/1 returns a kid changeset" do
      kid = kid_fixture()
      assert %Ecto.Changeset{} = Chores.change_kid(kid)
    end
  end

  describe "chores" do
    import BearCub.ChoresFixtures

    test "list_chores/2 returns the kid's chores for a routine, in append order" do
      kid = kid_fixture()
      other_kid = kid_fixture(%{position: 1})
      first = chore_fixture(kid)
      second = chore_fixture(kid, %{name: "Make Bed", icon: "🛏️"})
      _evening = chore_fixture(kid, %{routine: "evening"})
      _other_kids = chore_fixture(other_kid)

      assert Chores.list_chores(kid, "morning") == [first, second]
    end

    test "list_chores/2 never returns an extra (nil-routine) chore" do
      kid = kid_fixture()
      morning = chore_fixture(kid)
      _extra = chore_fixture(kid, %{name: "Wash Car", icon: "🚗", routine: nil})

      assert Chores.list_chores(kid, "morning") == [morning]
      assert Chores.list_chores(kid, "evening") == []
    end

    test "create_chore/3 creates a chore owned by the kid" do
      kid = kid_fixture()
      attrs = %{name: "Brush Teeth", icon: "🪥", routine: "morning", position: 0}

      assert {:ok, chore} = Chores.create_chore(kid, attrs, la(~D[2026-07-10], ~T[08:00:00]))
      assert chore.kid_id == kid.id
      assert chore.icon == "🪥"
    end

    test "create_chore/3 stamps active_from from the caller's local datetime (D80, D86)" do
      kid = kid_fixture()
      attrs = %{name: "Brush Teeth", icon: "🪥", routine: "morning"}

      assert {:ok, chore} = Chores.create_chore(kid, attrs, la(~D[2026-07-10], ~T[19:30:00]))
      assert chore.active_from == ~D[2026-07-10]
    end

    test "create_chore/3 never casts active_from from attrs (D86)" do
      kid = kid_fixture()
      attrs = %{name: "Brush Teeth", icon: "🪥", routine: "morning", active_from: ~D[2020-01-01]}

      assert {:ok, chore} = Chores.create_chore(kid, attrs, la(~D[2026-07-10], ~T[08:00:00]))
      assert chore.active_from == ~D[2026-07-10]
    end

    test "create_chore/3 creates a live, one-off chore (D80, D82)" do
      kid = kid_fixture()
      attrs = %{name: "Brush Teeth", icon: "🪥", routine: "morning"}

      assert {:ok, chore} = Chores.create_chore(kid, attrs, la(~D[2026-07-10], ~T[08:00:00]))
      assert chore.archived_on == nil
      assert chore.recurring? == false
    end

    test "create_chore/3 requires an icon" do
      kid = kid_fixture()
      attrs = %{name: "Brush Teeth", routine: "morning", position: 0}

      assert {:error, changeset} =
               Chores.create_chore(kid, attrs, la(~D[2026-07-10], ~T[08:00:00]))

      assert %{icon: ["can't be blank"]} = errors_on(changeset)
    end

    test "create_chore/3 rejects an unknown routine" do
      kid = kid_fixture()
      attrs = %{name: "Nap", icon: "😴", routine: "afternoon", position: 0}

      assert {:error, changeset} =
               Chores.create_chore(kid, attrs, la(~D[2026-07-10], ~T[08:00:00]))

      assert %{routine: ["is invalid"]} = errors_on(changeset)
    end

    test "create_chore/3 with a nil routine creates an extra" do
      kid = kid_fixture()
      attrs = %{name: "Wash Car", icon: "🚗", routine: nil, position: 0}

      assert {:ok, chore} = Chores.create_chore(kid, attrs, la(~D[2026-07-10], ~T[08:00:00]))
      assert chore.routine == nil
    end

    test "create_chore/3 without points defaults to 5 (D39)" do
      kid = kid_fixture()
      attrs = %{name: "Brush Teeth", icon: "🪥", routine: "morning", position: 0}

      assert {:ok, chore} = Chores.create_chore(kid, attrs, la(~D[2026-07-10], ~T[08:00:00]))
      assert chore.points == 5
    end

    test "create_chore/3 casts an explicit points value (D39)" do
      kid = kid_fixture()
      attrs = %{name: "Wash Car", icon: "🚗", routine: nil, points: 10}

      assert {:ok, chore} = Chores.create_chore(kid, attrs, la(~D[2026-07-10], ~T[08:00:00]))
      assert chore.points == 10
    end

    test "create_chore/3 with routine omitted creates an extra" do
      kid = kid_fixture()
      attrs = %{name: "Wash Car", icon: "🚗", position: 0}

      assert {:ok, chore} = Chores.create_chore(kid, attrs, la(~D[2026-07-10], ~T[08:00:00]))
      assert chore.routine == nil
    end

    test "update_chore/2 can clear routine to nil, turning a chore into an extra" do
      chore = chore_fixture()

      assert {:ok, chore} = Chores.update_chore(chore, %{routine: nil})
      assert chore.routine == nil
    end

    test "update_chore/2 updates name and icon; position is not mass-assignable" do
      chore = chore_fixture()

      assert {:ok, chore} = Chores.update_chore(chore, %{name: "Floss", icon: "🦷", position: 9})
      assert chore.name == "Floss"
      assert chore.icon == "🦷"
      assert chore.position == 0
    end

    test "deleting a kid cascades its chores" do
      kid = kid_fixture()
      chore = chore_fixture(kid)

      Repo.delete!(kid)

      assert_raise Ecto.NoResultsError, fn -> Chores.get_chore!(chore.id) end
    end

    test "get_chore/1 returns nil for a vanished chore instead of raising" do
      chore = chore_fixture()

      assert Chores.get_chore(chore.id) == chore

      Repo.delete!(chore)
      assert Chores.get_chore(chore.id) == nil
    end
  end

  describe "chore ordering" do
    import BearCub.ChoresFixtures

    test "create_chore/3 appends to the end of the kid's routine (D22)" do
      kid = kid_fixture()

      first = chore_fixture(kid)
      second = chore_fixture(kid, %{name: "Make Bed", icon: "🛏️"})
      evening = chore_fixture(kid, %{name: "Pajamas On", icon: "🌙", routine: "evening"})

      assert first.position == 0
      assert second.position == 1
      # positions are independent per kid+routine
      assert evening.position == 0
    end

    test "position is not mass-assignable on create" do
      kid = kid_fixture()

      {:ok, chore} =
        Chores.create_chore(
          kid,
          %{name: "Brush Teeth", icon: "🪥", routine: "morning", position: 7},
          la(~D[2026-07-10], ~T[08:00:00])
        )

      assert chore.position == 0
    end

    test "move_chore/2 down swaps with the next chore and broadcasts once" do
      kid = kid_fixture()
      first = chore_fixture(kid)
      second = chore_fixture(kid, %{name: "Make Bed", icon: "🛏️"})
      :ok = Chores.subscribe()

      assert {:ok, moved} = Chores.move_chore(first, :down)
      assert moved.position == 1

      assert Enum.map(Chores.list_chores(kid, "morning"), & &1.id) == [second.id, first.id]
      assert_receive :chores_changed
      refute_receive :chores_changed, 50
    end

    test "move_chore/2 up swaps with the previous chore" do
      kid = kid_fixture()
      first = chore_fixture(kid)
      second = chore_fixture(kid, %{name: "Make Bed", icon: "🛏️"})

      assert {:ok, _} = Chores.move_chore(second, :up)
      assert Enum.map(Chores.list_chores(kid, "morning"), & &1.id) == [second.id, first.id]
    end

    test "move_chore/2 at the list edge is a silent no-op — no broadcast" do
      kid = kid_fixture()
      only = chore_fixture(kid)
      :ok = Chores.subscribe()

      assert {:ok, chore} = Chores.move_chore(only, :up)
      assert chore.position == only.position
      refute_receive :chores_changed, 50
    end

    test "move_chore/2 never crosses kid or routine boundaries" do
      kid = kid_fixture()
      other_kid = kid_fixture(%{position: 1})
      morning = chore_fixture(kid)
      _evening = chore_fixture(kid, %{routine: "evening"})
      _other = chore_fixture(other_kid)

      # nothing above or below it within kid+morning — both directions no-op
      assert {:ok, %{position: 0}} = Chores.move_chore(morning, :up)
      assert {:ok, %{position: 0}} = Chores.move_chore(morning, :down)
    end

    test "create_chore/3 appends extras (nil routine) to the end of their own bucket (D22)" do
      kid = kid_fixture()

      first = chore_fixture(kid, %{name: "Wash Car", icon: "🚗", routine: nil})
      second = chore_fixture(kid, %{name: "Water Plants", icon: "🪴", routine: nil})

      assert first.position == 0
      assert second.position == 1
    end

    test "update_chore/2 reclassifying morning -> evening re-appends to the evening bucket (D35)" do
      kid = kid_fixture()
      morning = chore_fixture(kid)
      _evening_a = chore_fixture(kid, %{name: "Pajamas On", icon: "🌙", routine: "evening"})
      _evening_b = chore_fixture(kid, %{name: "Read Book", icon: "📖", routine: "evening"})

      assert {:ok, moved} = Chores.update_chore(morning, %{routine: "evening"})

      assert moved.routine == "evening"
      assert moved.position == 2
    end

    test "update_chore/2 reclassifying into the extra bucket re-appends among existing extras" do
      kid = kid_fixture()
      _extra_a = chore_fixture(kid, %{name: "Wash Car", icon: "🚗", routine: nil})
      _extra_b = chore_fixture(kid, %{name: "Water Plants", icon: "🪴", routine: nil})
      morning = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥"})

      assert {:ok, moved} = Chores.update_chore(morning, %{routine: nil})

      assert moved.routine == nil
      assert moved.position == 2
    end

    test "update_chore/2 without a routine change does not touch position" do
      kid = kid_fixture()
      first = chore_fixture(kid)
      _second = chore_fixture(kid, %{name: "Make Bed", icon: "🛏️"})

      assert {:ok, updated} = Chores.update_chore(first, %{name: "Brush Teeth Well"})

      assert updated.position == 0
    end
  end

  describe "archive_chore/2 (Story 03, D78, D79)" do
    import BearCub.ChoresFixtures

    test "stamps archived_on from the caller's local date and broadcasts" do
      chore = chore_fixture()
      :ok = Chores.subscribe()

      assert {:ok, archived} = Chores.archive_chore(chore, la(~D[2026-07-10], ~T[19:30:00]))
      assert archived.archived_on == ~D[2026-07-10]
      assert_receive :chores_changed
    end

    test "leaves the chore's completions intact" do
      chore = chore_fixture()
      {:ok, completion} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")

      {:ok, _} = Chores.archive_chore(chore, la(~D[2026-07-11], ~T[08:00:00]))

      assert Repo.get!(Completion, completion.id)
    end

    test "a past fully-earned routine-day stays earned after a later archive (AC-4, D78, D81)" do
      kid = kid_fixture()
      a = chore_fixture(kid, %{name: "A", routine: "morning"}, la(~D[2026-07-01], ~T[08:00:00]))
      b = chore_fixture(kid, %{name: "B", routine: "morning"}, la(~D[2026-07-01], ~T[08:01:00]))

      {:ok, _} = Chores.complete_chore(a, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")
      {:ok, _} = Chores.complete_chore(b, la(~D[2026-07-10], ~T[07:01:00]), "kiosk")
      assert Chores.routine_day_contribution(kid, "morning", ~D[2026-07-10]) == Routines.bonus()

      {:ok, _} = Chores.archive_chore(b, la(~D[2026-07-20], ~T[09:00:00]))

      assert Chores.routine_day_contribution(kid, "morning", ~D[2026-07-10]) == Routines.bonus()
      assert Chores.earnings_by_kid(~D[2026-07-20]) == %{kid.id => Routines.bonus()}
    end

    test "an archived chore vanishes from list_chores/2" do
      kid = kid_fixture()
      chore = chore_fixture(kid)
      {:ok, _} = Chores.archive_chore(chore, la(~D[2026-07-10], ~T[08:00:00]))

      assert Chores.list_chores(kid, "morning") == []
    end

    test "an archived extra vanishes from list_extras/2" do
      kid = kid_fixture()
      extra = chore_fixture(kid, %{name: "Wash Car", icon: "🚗", routine: nil})
      {:ok, _} = Chores.archive_chore(extra, la(~D[2026-07-10], ~T[08:00:00]))

      assert Chores.list_extras(kid, ~D[2026-07-10]) == []
    end

    test "move_chore/2 steps past an archived neighbor to the nearest live chore" do
      kid = kid_fixture()
      first = chore_fixture(kid)
      middle = chore_fixture(kid, %{name: "Make Bed", icon: "🛏️"})
      last = chore_fixture(kid, %{name: "Get Dressed", icon: "👕"})
      {:ok, _} = Chores.archive_chore(middle, la(~D[2026-07-10], ~T[08:00:00]))

      assert {:ok, moved} = Chores.move_chore(first, :down)
      assert moved.position == 2

      assert Enum.map(Chores.list_chores(kid, "morning"), & &1.id) == [last.id, first.id]
    end

    test "move_chore/2 :up also steps past an archived neighbor to the nearest live chore" do
      kid = kid_fixture()
      first = chore_fixture(kid)
      middle = chore_fixture(kid, %{name: "Make Bed", icon: "🛏️"})
      last = chore_fixture(kid, %{name: "Get Dressed", icon: "👕"})
      {:ok, _} = Chores.archive_chore(middle, la(~D[2026-07-10], ~T[08:00:00]))

      assert {:ok, moved} = Chores.move_chore(last, :up)
      assert moved.position == 0

      assert Enum.map(Chores.list_chores(kid, "morning"), & &1.id) == [last.id, first.id]
    end

    test "move_chore/2 steps past an archived neighbor within the extras bucket, both directions" do
      kid = kid_fixture()

      first = chore_fixture(kid, %{name: "Wash Car", icon: "🚗", routine: nil})
      middle = chore_fixture(kid, %{name: "Water Plants", icon: "🪴", routine: nil})
      last = chore_fixture(kid, %{name: "Sweep Porch", icon: "🧹", routine: nil})
      {:ok, _} = Chores.archive_chore(middle, la(~D[2026-07-10], ~T[08:00:00]))

      assert {:ok, moved_down} = Chores.move_chore(first, :down)
      assert moved_down.position == last.position

      assert {:ok, moved_up} = Chores.move_chore(moved_down, :up)
      assert moved_up.position == first.position
    end

    test "next_position/2 reuses the position an archived chore freed" do
      kid = kid_fixture()
      _first = chore_fixture(kid)
      second = chore_fixture(kid, %{name: "Make Bed", icon: "🛏️"})
      {:ok, _} = Chores.archive_chore(second, la(~D[2026-07-10], ~T[08:00:00]))

      third =
        chore_fixture(kid, %{name: "Get Dressed", icon: "👕"}, la(~D[2026-07-11], ~T[08:00:00]))

      assert third.position == 1
    end

    test "delete_chore/1 no longer exists" do
      refute function_exported?(Chores, :delete_chore, 1)
    end

    test "archiving a chore does not retroactively grant a past incomplete routine-day (D78, D81)" do
      kid = kid_fixture()
      a = chore_fixture(kid, %{name: "A", routine: "morning"}, la(~D[2026-07-01], ~T[08:00:00]))
      b = chore_fixture(kid, %{name: "B", routine: "morning"}, la(~D[2026-07-01], ~T[08:01:00]))

      {:ok, _} = Chores.complete_chore(a, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")
      assert Chores.routine_day_contribution(kid, "morning", ~D[2026-07-10]) == 0

      {:ok, _} = Chores.archive_chore(b, la(~D[2026-07-20], ~T[09:00:00]))

      assert Chores.routine_day_contribution(kid, "morning", ~D[2026-07-10]) == 0
      assert Chores.earnings_by_kid(~D[2026-07-20]) == %{kid.id => 0}
    end

    test "archiving a chore today drops it from today's requirement, scoring against what remains (D78, D81)" do
      kid = kid_fixture()
      a = chore_fixture(kid, %{name: "A", routine: "morning"})
      b = chore_fixture(kid, %{name: "B", routine: "morning"})
      {:ok, _} = Chores.complete_chore(a, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")

      assert Chores.routine_day_contribution(kid, "morning", ~D[2026-07-10]) == 0

      {:ok, _} = Chores.archive_chore(b, la(~D[2026-07-10], ~T[09:00:00]))

      assert Chores.routine_day_contribution(kid, "morning", ~D[2026-07-10]) == Routines.bonus()
    end
  end

  describe "extras" do
    import BearCub.ChoresFixtures

    defp extra_fixture(kid, attrs \\ %{}) do
      chore_fixture(kid, Enum.into(attrs, %{name: "Wash Car", icon: "🚗", routine: nil}))
    end

    test "list_extras/2 returns outstanding and done-today extras, ordered by position" do
      kid = kid_fixture()
      outstanding = extra_fixture(kid)
      done_today = extra_fixture(kid, %{name: "Water Plants", icon: "🪴"})
      _morning = chore_fixture(kid)

      {:ok, _} = Chores.complete_chore(done_today, la(~D[2026-07-10], ~T[08:00:00]), "kiosk")

      assert Chores.list_extras(kid, ~D[2026-07-10]) == [outstanding, done_today]
    end

    test "list_extras/2 excludes a retired extra — completed before today never returns" do
      kid = kid_fixture()
      retired = extra_fixture(kid)
      {:ok, _} = Chores.complete_chore(retired, la(~D[2026-07-09], ~T[08:00:00]), "kiosk")

      assert Chores.list_extras(kid, ~D[2026-07-10]) == []
    end

    test "undoing a done-today extra returns it to outstanding in list_extras/2" do
      kid = kid_fixture()
      extra = extra_fixture(kid)
      {:ok, _} = Chores.complete_chore(extra, la(~D[2026-07-10], ~T[08:00:00]), "kiosk")

      # done-today still lingers in the list
      assert Chores.list_extras(kid, ~D[2026-07-10]) == [extra]
      assert Map.has_key?(Chores.current_completions(~D[2026-07-10]), extra.id)

      {:ok, _} = Chores.undo_chore(extra, la(~D[2026-07-10], ~T[08:05:00]))

      # back to outstanding: still in the list, no longer done
      assert Chores.list_extras(kid, ~D[2026-07-10]) == [extra]
      refute Map.has_key?(Chores.current_completions(~D[2026-07-10]), extra.id)
    end

    test "current_completions/1 reflects an extra's done-today state exactly like a chore" do
      kid = kid_fixture()
      extra = extra_fixture(kid)
      {:ok, completion} = Chores.complete_chore(extra, la(~D[2026-07-10], ~T[08:00:00]), "kiosk")

      extra_id = extra.id
      assert %{^extra_id => found} = Chores.current_completions(~D[2026-07-10])
      assert found.id == completion.id
    end

    test "move_chore/2 swaps positions within the extra (nil-routine) bucket" do
      kid = kid_fixture()
      first = extra_fixture(kid)
      second = extra_fixture(kid, %{name: "Water Plants", icon: "🪴"})

      assert {:ok, moved} = Chores.move_chore(first, :down)
      assert moved.position == second.position

      assert Enum.map(Chores.list_extras(kid, ~D[2026-07-10]), & &1.id) ==
               [second.id, first.id]
    end
  end

  describe "completions" do
    import BearCub.ChoresFixtures

    @tz "America/Los_Angeles"

    defp la(date, time), do: DateTime.new!(date, time, @tz)

    test "complete_chore/3 records the local date and the UTC instant" do
      chore = chore_fixture()

      assert {:ok, completion} =
               Chores.complete_chore(chore, la(~D[2026-07-10], ~T[23:59:00]), "kiosk")

      # 23:59 PDT (UTC-7) is 06:59 the next day in UTC — local_date still the 10th
      assert completion.local_date == ~D[2026-07-10]
      assert completion.completed_at == ~U[2026-07-11 06:59:00Z]
      assert completion.source == "kiosk"
      assert completion.undone_at == nil
    end

    test "complete_chore/3 honors DST — winter is UTC-8" do
      chore = chore_fixture()

      assert {:ok, completion} =
               Chores.complete_chore(chore, la(~D[2026-01-10], ~T[22:00:00]), "kiosk")

      assert completion.completed_at == ~U[2026-01-11 06:00:00Z]
    end

    test "a second complete on the same local day is rejected by the partial index" do
      chore = chore_fixture()
      {:ok, _} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")

      assert {:error, changeset} =
               Chores.complete_chore(chore, la(~D[2026-07-10], ~T[07:00:01]), "kiosk")

      assert %{chore_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "undo_chore/2 stamps undone_at and keeps the row (FR-17)" do
      chore = chore_fixture()
      {:ok, completion} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")

      assert {:ok, undone} = Chores.undo_chore(chore, la(~D[2026-07-10], ~T[07:05:00]))
      assert undone.id == completion.id
      assert undone.undone_at == ~U[2026-07-10 14:05:00Z]
    end

    test "undo_chore/2 without a current completion is a no-op error" do
      chore = chore_fixture()

      assert {:error, :not_completed} = Chores.undo_chore(chore, la(~D[2026-07-10], ~T[07:00:00]))
    end

    test "undo_chore/2 never reaches back across midnight — yesterday is history" do
      chore = chore_fixture()
      {:ok, _} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[22:00:00]), "kiosk")

      assert {:error, :not_completed} = Chores.undo_chore(chore, la(~D[2026-07-11], ~T[00:10:00]))
    end

    test "complete → undo → complete leaves one current row and full history (FR-8 AC)" do
      chore = chore_fixture()

      {:ok, _} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")
      {:ok, _} = Chores.undo_chore(chore, la(~D[2026-07-10], ~T[07:01:00]))
      {:ok, _} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[07:02:00]), "kiosk")

      completions = Repo.all(BearCub.Chores.Completion)
      assert length(completions) == 2
      assert Enum.count(completions, &is_nil(&1.undone_at)) == 1
    end

    test "current_completions/1 derives day state — the date change is the reset (D10)" do
      chore = chore_fixture()
      other = chore_fixture(kid_fixture(%{position: 1}))

      {:ok, completion} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[23:59:00]), "kiosk")
      {:ok, _undone} = Chores.complete_chore(other, la(~D[2026-07-10], ~T[08:00:00]), "kiosk")
      {:ok, _} = Chores.undo_chore(other, la(~D[2026-07-10], ~T[08:01:00]))

      chore_id = chore.id
      assert %{^chore_id => found} = Chores.current_completions(~D[2026-07-10])
      assert found.id == completion.id
      refute Map.has_key?(Chores.current_completions(~D[2026-07-10]), other.id)

      # midnight: nothing runs, the query just returns empty for the new date
      assert Chores.current_completions(~D[2026-07-11]) == %{}
    end
  end

  describe "extra_contribution/2 (Story 02, D40)" do
    import BearCub.ChoresFixtures

    defp fail_completion(%Completion{} = completion, at) do
      completion
      |> Ecto.Changeset.change(undone_at: at, failed_at: at)
      |> Repo.update!()
    end

    test "a live completion earns its chore's own points value" do
      chore = chore_fixture(kid_fixture(), %{routine: nil, points: 7})
      {:ok, completion} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[08:00:00]), "kiosk")

      assert Chores.extra_contribution(completion, chore) == 7
    end

    test "an ordinary undo contributes zero" do
      chore = chore_fixture(kid_fixture(), %{routine: nil, points: 7})
      {:ok, _} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[08:00:00]), "kiosk")
      {:ok, undone} = Chores.undo_chore(chore, la(~D[2026-07-10], ~T[08:05:00]))

      assert Chores.extra_contribution(undone, chore) == 0
    end

    test "a failed completion costs its chore's own points value (checks failed_at first)" do
      chore = chore_fixture(kid_fixture(), %{routine: nil, points: 7})
      {:ok, completion} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[08:00:00]), "kiosk")
      failed = fail_completion(completion, ~U[2026-07-10 15:00:00Z])

      assert Chores.extra_contribution(failed, chore) == -7
    end
  end

  describe "routine_day_contribution/3 (Story 02, D40)" do
    import BearCub.ChoresFixtures

    test "a fully-complete 2-chore routine earns exactly R, chore count doesn't scale it (SC-2)" do
      kid = kid_fixture()
      a = chore_fixture(kid, %{name: "A", routine: "morning"})
      b = chore_fixture(kid, %{name: "B", routine: "morning"})
      {:ok, _} = Chores.complete_chore(a, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")
      {:ok, _} = Chores.complete_chore(b, la(~D[2026-07-10], ~T[07:01:00]), "kiosk")

      assert Chores.routine_day_contribution(kid, "morning", ~D[2026-07-10]) == Routines.bonus()
    end

    test "a fully-complete 4-chore routine still earns exactly R (SC-2)" do
      kid = kid_fixture()
      chores = for n <- 1..4, do: chore_fixture(kid, %{name: "Chore #{n}", routine: "morning"})

      for chore <- chores do
        {:ok, _} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")
      end

      assert Chores.routine_day_contribution(kid, "morning", ~D[2026-07-10]) == Routines.bonus()
    end

    test "an incomplete routine (not every chore live) contributes zero with no fails" do
      kid = kid_fixture()
      a = chore_fixture(kid, %{name: "A", routine: "morning"})
      _b = chore_fixture(kid, %{name: "B", routine: "morning"})
      {:ok, _} = Chores.complete_chore(a, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")

      assert Chores.routine_day_contribution(kid, "morning", ~D[2026-07-10]) == 0
    end

    test "one failed routine chore that day contributes a single -R" do
      kid = kid_fixture()
      a = chore_fixture(kid, %{name: "A", routine: "morning"})
      b = chore_fixture(kid, %{name: "B", routine: "morning"})
      {:ok, ca} = Chores.complete_chore(a, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")
      {:ok, _cb} = Chores.complete_chore(b, la(~D[2026-07-10], ~T[07:01:00]), "kiosk")

      fail_completion(ca, ~U[2026-07-10 15:00:00Z])

      assert Chores.routine_day_contribution(kid, "morning", ~D[2026-07-10]) == -Routines.bonus()
    end

    test "two failed routine chores in the same routine-day still cost a single -R (capped, SC-3)" do
      kid = kid_fixture()
      a = chore_fixture(kid, %{name: "A", routine: "morning"})
      b = chore_fixture(kid, %{name: "B", routine: "morning"})
      {:ok, ca} = Chores.complete_chore(a, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")
      {:ok, cb} = Chores.complete_chore(b, la(~D[2026-07-10], ~T[07:01:00]), "kiosk")

      fail_completion(ca, ~U[2026-07-10 15:00:00Z])
      fail_completion(cb, ~U[2026-07-10 15:01:00Z])

      assert Chores.routine_day_contribution(kid, "morning", ~D[2026-07-10]) == -Routines.bonus()
    end

    test "failing then redoing the failed chore restores +R while -R persists, netting zero (SC-3)" do
      kid = kid_fixture()
      a = chore_fixture(kid, %{name: "A", routine: "morning"})
      b = chore_fixture(kid, %{name: "B", routine: "morning"})
      {:ok, ca} = Chores.complete_chore(a, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")
      {:ok, _cb} = Chores.complete_chore(b, la(~D[2026-07-10], ~T[07:01:00]), "kiosk")

      assert Chores.routine_day_contribution(kid, "morning", ~D[2026-07-10]) == Routines.bonus()

      fail_completion(ca, ~U[2026-07-10 15:00:00Z])
      assert Chores.routine_day_contribution(kid, "morning", ~D[2026-07-10]) == -Routines.bonus()

      {:ok, _redo} = Chores.complete_chore(a, la(~D[2026-07-10], ~T[16:00:00]), "kiosk")
      assert Chores.routine_day_contribution(kid, "morning", ~D[2026-07-10]) == 0
    end
  end

  describe "the date-bounded routine roster (Story 02, D81)" do
    import BearCub.ChoresFixtures

    # Story 03 lands `archive_chore/2`; until then the `archived_on` half of
    # the liveness predicate is exercised by stamping the column directly.
    defp stamp(chore, attrs), do: chore |> Ecto.Changeset.change(attrs) |> Repo.update!()

    test "a routine chore added today leaves a past completed routine-day at +R" do
      kid = kid_fixture()
      a = chore_fixture(kid, %{name: "A", routine: "morning"}, la(~D[2026-07-01], ~T[08:00:00]))
      b = chore_fixture(kid, %{name: "B", routine: "morning"}, la(~D[2026-07-01], ~T[08:01:00]))

      {:ok, _} = Chores.complete_chore(a, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")
      {:ok, _} = Chores.complete_chore(b, la(~D[2026-07-10], ~T[07:01:00]), "kiosk")

      assert Chores.routine_day_contribution(kid, "morning", ~D[2026-07-10]) == Routines.bonus()

      _c = chore_fixture(kid, %{name: "C", routine: "morning"}, la(~D[2026-07-20], ~T[09:00:00]))

      assert Chores.routine_day_contribution(kid, "morning", ~D[2026-07-10]) == Routines.bonus()
      assert Chores.earnings_by_kid(~D[2026-07-20]) == %{kid.id => Routines.bonus()}
    end

    test "a chore added today is required today, so today's routine-day is incomplete" do
      kid = kid_fixture()
      a = chore_fixture(kid, %{name: "A", routine: "morning"}, la(~D[2026-07-01], ~T[08:00:00]))
      {:ok, _} = Chores.complete_chore(a, la(~D[2026-07-20], ~T[07:00:00]), "kiosk")

      assert Chores.routine_day_contribution(kid, "morning", ~D[2026-07-20]) == Routines.bonus()

      _b = chore_fixture(kid, %{name: "B", routine: "morning"}, la(~D[2026-07-20], ~T[09:00:00]))

      assert Chores.routine_day_contribution(kid, "morning", ~D[2026-07-20]) == 0
    end

    test "archiving a chore never retroactively grants a past day's bonus" do
      kid = kid_fixture()
      a = chore_fixture(kid, %{name: "A", routine: "morning"}, la(~D[2026-07-01], ~T[08:00:00]))
      b = chore_fixture(kid, %{name: "B", routine: "morning"}, la(~D[2026-07-01], ~T[08:01:00]))

      # 2026-07-09 was never fully complete: b was live and left undone
      {:ok, _} = Chores.complete_chore(a, la(~D[2026-07-09], ~T[07:00:00]), "kiosk")
      assert Chores.routine_day_contribution(kid, "morning", ~D[2026-07-09]) == 0

      stamp(b, archived_on: ~D[2026-07-10])

      assert Chores.routine_day_contribution(kid, "morning", ~D[2026-07-09]) == 0
      assert Chores.earnings_by_kid(~D[2026-07-20]) == %{kid.id => 0}
    end

    test "a chore counts for every day before its archive date and not for the date itself" do
      kid = kid_fixture()
      a = chore_fixture(kid, %{name: "A", routine: "morning"}, la(~D[2026-07-01], ~T[08:00:00]))
      b = chore_fixture(kid, %{name: "B", routine: "morning"}, la(~D[2026-07-01], ~T[08:01:00]))

      {:ok, _} = Chores.complete_chore(a, la(~D[2026-07-09], ~T[07:00:00]), "kiosk")
      {:ok, _} = Chores.complete_chore(b, la(~D[2026-07-09], ~T[07:01:00]), "kiosk")
      {:ok, _} = Chores.complete_chore(a, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")

      stamp(b, archived_on: ~D[2026-07-10])

      # the day before the archive still requires b — it was live then
      assert Chores.routine_day_contribution(kid, "morning", ~D[2026-07-09]) == Routines.bonus()
      # the archive date itself does not: the card is gone from the kiosk
      assert Chores.routine_day_contribution(kid, "morning", ~D[2026-07-10]) == Routines.bonus()
      assert Chores.earnings_by_kid(~D[2026-07-10]) == %{kid.id => 2 * Routines.bonus()}
    end

    test "a chore completed on the day it is archived stops counting toward that day's roster" do
      kid = kid_fixture()
      a = chore_fixture(kid, %{name: "A", routine: "morning"}, la(~D[2026-07-01], ~T[08:00:00]))
      b = chore_fixture(kid, %{name: "B", routine: "morning"}, la(~D[2026-07-01], ~T[08:01:00]))
      c = chore_fixture(kid, %{name: "C", routine: "morning"}, la(~D[2026-07-01], ~T[08:02:00]))

      # the kid finished everything this morning; b is archived this afternoon
      for chore <- [a, b, c] do
        {:ok, _} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")
      end

      stamp(b, archived_on: ~D[2026-07-10])

      assert Chores.routine_day_contribution(kid, "morning", ~D[2026-07-10]) == Routines.bonus()
      assert Chores.earnings_by_kid(~D[2026-07-10]) == %{kid.id => Routines.bonus()}
    end

    # This is the tripwire for the ruling in D90, not a trivia assertion.
    # D80/D81 wrote the bound null-tolerant (`is_nil(active_from) or
    # active_from <= day`) so a stray null would fail toward a larger roster
    # rather than a fabricated bonus; D90 removed that tolerance because the
    # NOT NULL column makes the null impossible, leaving the constraint as
    # the single protection. So: if this test ever fails, someone has
    # relaxed the column, and the three date bounds in `BearCub.Chores` must
    # regain their `is_nil(active_from) or` half before that ships — without
    # it a null reads as "not yet live", shrinking a historical roster and
    # handing out a bonus nobody earned.
    test "the database rejects an update setting active_from to null" do
      kid = kid_fixture()

      chore =
        chore_fixture(kid, %{name: "A", routine: "morning"}, la(~D[2026-07-01], ~T[08:00:00]))

      assert_raise Exqlite.Error, ~r/NOT NULL constraint failed: chores.active_from/, fn ->
        stamp(chore, active_from: nil)
      end
    end

    test "a chore live since before recorded history is required on every scored day" do
      kid = kid_fixture()
      # the epoch floor the migration hands pre-lifecycle rows: live forever
      a = chore_fixture(kid, %{name: "A", routine: "morning"})
      b = chore_fixture(kid, %{name: "B", routine: "morning"})

      {:ok, _} = Chores.complete_chore(a, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")

      assert Chores.routine_day_contribution(kid, "morning", ~D[2026-07-10]) == 0
      assert Chores.earnings_by_kid(~D[2026-07-10]) == %{kid.id => 0}

      {:ok, _} = Chores.complete_chore(b, la(~D[2026-07-10], ~T[07:01:00]), "kiosk")

      assert Chores.routine_day_contribution(kid, "morning", ~D[2026-07-10]) == Routines.bonus()
      assert Chores.earnings_by_kid(~D[2026-07-10]) == %{kid.id => Routines.bonus()}
    end

    test "extras are never bounded: an archived extra's completions still sum (D81)" do
      kid = kid_fixture()

      extra =
        chore_fixture(
          kid,
          %{name: "Extra", routine: nil, points: 7},
          la(~D[2026-07-01], ~T[08:00:00])
        )

      {:ok, _} = Chores.complete_chore(extra, la(~D[2026-07-10], ~T[08:00:00]), "kiosk")
      stamp(extra, active_from: ~D[2026-08-01], archived_on: ~D[2026-07-01])

      assert Chores.earnings(kid, ~D[2026-07-10]) == 7
      assert Chores.earnings_by_kid(~D[2026-07-10]) == %{kid.id => 7}
    end

    test "a day on which the kid completed nothing produces no row and contributes 0" do
      kid = kid_fixture()
      a = chore_fixture(kid, %{name: "A", routine: "morning"}, la(~D[2026-07-01], ~T[08:00:00]))
      {:ok, _} = Chores.complete_chore(a, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")

      assert Chores.earnings(kid, ~D[2026-07-09]) == 0
      assert Chores.earnings_by_kid(~D[2026-07-09]) == %{}
    end

    test "the grouped and per-kid totals agree across an addition and an archive" do
      kid_a = kid_fixture(%{name: "Kid A", position: 0})
      kid_b = kid_fixture(%{name: "Kid B", position: 1})

      # Kid A: a morning chore from the start, a second added mid-history,
      # and an evening chore archived mid-history.
      a1 =
        chore_fixture(kid_a, %{name: "A1", routine: "morning"}, la(~D[2026-07-01], ~T[08:00:00]))

      a2 =
        chore_fixture(kid_a, %{name: "A2", routine: "morning"}, la(~D[2026-07-05], ~T[08:00:00]))

      a3 =
        chore_fixture(kid_a, %{name: "A3", routine: "evening"}, la(~D[2026-07-01], ~T[08:00:00]))

      a4 =
        chore_fixture(kid_a, %{name: "A4", routine: "evening"}, la(~D[2026-07-01], ~T[08:01:00]))

      stamp(a3, archived_on: ~D[2026-07-06])

      # Kid B: one morning chore, plus an extra outside the bound entirely.
      b1 =
        chore_fixture(kid_b, %{name: "B1", routine: "morning"}, la(~D[2026-07-01], ~T[08:00:00]))

      b2 =
        chore_fixture(
          kid_b,
          %{name: "B2", routine: nil, points: 3},
          la(~D[2026-07-03], ~T[08:00:00])
        )

      for {day, chores} <- [
            {~D[2026-07-02], [a1, a3, a4, b1]},
            {~D[2026-07-04], [a1, b1, b2]},
            {~D[2026-07-05], [a1, a2, a3]},
            # a3 is completed on the very day it is archived, alongside the
            # evening chore that outlives it — the case that separates the
            # grouped query from the per-kid one if either leg goes unbounded
            {~D[2026-07-06], [a1, a2, a3, a4, b1]},
            {~D[2026-07-07], [a1, a4, b1]}
          ],
          chore <- chores do
        {:ok, _} = Chores.complete_chore(chore, la(day, ~T[07:00:00]), "kiosk")
      end

      {:ok, failed} = Chores.complete_chore(a2, la(~D[2026-07-08], ~T[07:00:00]), "kiosk")
      fail_completion(failed, ~U[2026-07-08 15:00:00Z])

      for day <- Date.range(~D[2026-07-01], ~D[2026-07-10]) do
        by_kid = Chores.earnings_by_kid(day)

        for kid <- [kid_a, kid_b] do
          assert Map.get(by_kid, kid.id, 0) == Chores.earnings(kid, day),
                 "grouped and per-kid earnings disagree for kid #{kid.name} on #{day}"
        end
      end
    end

    # The criterion is per-`(kid, routine, day)`, but `earnings_by_kid/1` is
    # the only public way into the grouped derivation (`routine_days_by_kid/1`
    # is private; `BearCub.Points.balances/1` is its one caller) and it returns
    # a total per kid. Differencing it across consecutive cutoff dates isolates
    # one kid-day; giving each kid a single routine makes that kid-day exactly
    # one `(kid, routine, day)` cell, so the difference compares directly
    # against `routine_day_contribution/3`.
    #
    # Residual, stated rather than hidden: any perturbation of the grouped
    # per-cell values whose per-kid sum is zero at every cutoff date is
    # invisible through a total — equal and opposite between a kid's two
    # routines inside one day, or between two days of one cell. Single-routine
    # kids are also what costs this test the routine axis: the totals test
    # above is the only thing in the suite that catches a `(kid, routine)`
    # confusion in the grouped joins. Neither test replaces the other.
    test "each (kid, routine, day) cell agrees across an addition and an archive" do
      morning_kid = kid_fixture(%{name: "Morning Kid", position: 0})
      evening_kid = kid_fixture(%{name: "Evening Kid", position: 1})

      m1 =
        chore_fixture(
          morning_kid,
          %{name: "M1", routine: "morning"},
          la(~D[2026-07-01], ~T[08:00:00])
        )

      # added mid-history: 07-05 onward the morning roster is two chores
      m2 =
        chore_fixture(
          morning_kid,
          %{name: "M2", routine: "morning"},
          la(~D[2026-07-05], ~T[08:00:00])
        )

      e1 =
        chore_fixture(
          evening_kid,
          %{name: "E1", routine: "evening"},
          la(~D[2026-07-01], ~T[08:00:00])
        )

      e2 =
        chore_fixture(
          evening_kid,
          %{name: "E2", routine: "evening"},
          la(~D[2026-07-01], ~T[08:01:00])
        )

      # archived mid-history, after being completed on the archive day itself
      stamp(e2, archived_on: ~D[2026-07-06])

      for {day, chores} <- [
            {~D[2026-07-02], [m1, e1, e2]},
            {~D[2026-07-04], [m1, e1]},
            {~D[2026-07-05], [m1, m2, e1, e2]},
            {~D[2026-07-06], [m1, e1, e2]},
            {~D[2026-07-07], [m1, m2, e1]}
          ],
          chore <- chores do
        {:ok, _} = Chores.complete_chore(chore, la(day, ~T[07:00:00]), "kiosk")
      end

      {:ok, failed} = Chores.complete_chore(m2, la(~D[2026-07-08], ~T[07:00:00]), "kiosk")
      fail_completion(failed, ~U[2026-07-08 15:00:00Z])

      for day <- Date.range(~D[2026-07-02], ~D[2026-07-10]),
          {kid, routine} <- [{morning_kid, "morning"}, {evening_kid, "evening"}] do
        grouped_cell =
          Map.get(Chores.earnings_by_kid(day), kid.id, 0) -
            Map.get(Chores.earnings_by_kid(Date.add(day, -1)), kid.id, 0)

        assert grouped_cell == Chores.routine_day_contribution(kid, routine, day),
               "derivations disagree for #{kid.name}/#{routine} on #{day}"
      end
    end
  end

  describe "earnings_by_kid/1 (Story 02, D72)" do
    import BearCub.ChoresFixtures

    defp count_queries(fun) do
      test_pid = self()
      handler_id = make_ref()

      :telemetry.attach(
        handler_id,
        [:bear_cub, :repo, :query],
        fn _event, _measurements, _metadata, _config -> send(test_pid, :query_executed) end,
        nil
      )

      fun.()

      :telemetry.detach(handler_id)
      count_received_queries(0)
    end

    defp count_received_queries(count) do
      receive do
        :query_executed -> count_received_queries(count + 1)
      after
        0 -> count
      end
    end

    test "matches earnings/2 for each kid, across the extras and routine-days legs" do
      kid_a = kid_fixture(%{name: "Kid A", position: 0})
      kid_b = kid_fixture(%{name: "Kid B", position: 1})

      extra = chore_fixture(kid_a, %{name: "Extra", routine: nil, points: 6})
      {:ok, _} = Chores.complete_chore(extra, la(~D[2026-07-10], ~T[08:00:00]), "kiosk")

      a = chore_fixture(kid_b, %{name: "A", routine: "morning"})
      b = chore_fixture(kid_b, %{name: "B", routine: "morning"})
      {:ok, _} = Chores.complete_chore(a, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")
      {:ok, _} = Chores.complete_chore(b, la(~D[2026-07-10], ~T[07:01:00]), "kiosk")

      earnings = Chores.earnings_by_kid(~D[2026-07-10])

      assert earnings[kid_a.id] == Chores.earnings(kid_a, ~D[2026-07-10])
      assert earnings[kid_b.id] == Chores.earnings(kid_b, ~D[2026-07-10])
    end

    test "a kid with no completions is absent from the map" do
      kid = kid_fixture()
      _chore = chore_fixture(kid, %{name: "Extra", routine: nil, points: 5})

      assert Chores.earnings_by_kid(~D[2026-07-10]) == %{}
    end

    test "the query count for a whole-render read does not grow with days of history (SC-9, D72)" do
      kid = kid_fixture()
      chore = chore_fixture(kid, %{name: "A", routine: "morning"})

      {:ok, _} = Chores.complete_chore(chore, la(~D[2026-07-01], ~T[07:00:00]), "kiosk")

      few_days_query_count = count_queries(fn -> Chores.earnings_by_kid(~D[2026-07-01]) end)

      for n <- 2..60 do
        date = Date.add(~D[2026-07-01], n)
        {:ok, _} = Chores.complete_chore(chore, la(date, ~T[07:00:00]), "kiosk")
      end

      many_days_query_count =
        count_queries(fn -> Chores.earnings_by_kid(Date.add(~D[2026-07-01], 60)) end)

      assert few_days_query_count == many_days_query_count
    end

    test "a whole-render read is two queries: one extras leg, one routine leg" do
      kid = kid_fixture()
      chore = chore_fixture(kid, %{name: "A", routine: "morning"})
      {:ok, _} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")

      # The date-bounded roster count is nested inside the routine leg as a
      # subquery (D81), not fetched per routine-day — asserting only that the
      # count is *constant* would not notice it splitting into two statements.
      assert count_queries(fn -> Chores.earnings_by_kid(~D[2026-07-10]) end) == 2
    end

    test "the query count does not grow with the number of kids (SC-5, D81)" do
      one_kid = kid_fixture(%{name: "Kid 1", position: 0})
      chore = chore_fixture(one_kid, %{name: "A", routine: "morning"})
      {:ok, _} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")

      one_kid_query_count = count_queries(fn -> Chores.earnings_by_kid(~D[2026-07-10]) end)

      for n <- 2..8 do
        kid = kid_fixture(%{name: "Kid #{n}", position: n})
        kid_chore = chore_fixture(kid, %{name: "A", routine: "morning"})
        {:ok, _} = Chores.complete_chore(kid_chore, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")
      end

      many_kids_query_count = count_queries(fn -> Chores.earnings_by_kid(~D[2026-07-10]) end)

      assert one_kid_query_count == many_kids_query_count
    end
  end

  describe "on-behalf toggling" do
    import BearCub.ChoresFixtures

    test "toggle_completion/3 completes an undone chore with the given source" do
      chore = chore_fixture()

      assert {:ok, completion} =
               Chores.toggle_completion(chore, la(~D[2026-07-10], ~T[09:00:00]), "admin")

      assert completion.source == "admin"
      assert completion.undone_at == nil
    end

    test "toggle_completion/3 undoes a done chore" do
      chore = chore_fixture()
      {:ok, _} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[09:00:00]), "kiosk")

      assert {:ok, undone} =
               Chores.toggle_completion(chore, la(~D[2026-07-10], ~T[09:05:00]), "admin")

      assert undone.undone_at == ~U[2026-07-10 16:05:00Z]
    end

    test "toggle → toggle → toggle keeps full history (FR-17)" do
      chore = chore_fixture()

      {:ok, _} = Chores.toggle_completion(chore, la(~D[2026-07-10], ~T[09:00:00]), "admin")
      {:ok, _} = Chores.toggle_completion(chore, la(~D[2026-07-10], ~T[09:01:00]), "admin")
      {:ok, _} = Chores.toggle_completion(chore, la(~D[2026-07-10], ~T[09:02:00]), "admin")

      completions = Repo.all(BearCub.Chores.Completion)
      assert length(completions) == 2
      assert Enum.count(completions, &is_nil(&1.undone_at)) == 1
    end
  end

  describe "fail_chore/2 (Story 05, D40)" do
    import BearCub.ChoresFixtures

    test "stamps both undone_at and failed_at on the current live completion, reverting it" do
      chore = chore_fixture()
      {:ok, completion} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")

      assert {:ok, failed} = Chores.fail_chore(chore, la(~D[2026-07-10], ~T[07:05:00]))
      assert failed.id == completion.id
      assert failed.undone_at == ~U[2026-07-10 14:05:00Z]
      assert failed.failed_at == ~U[2026-07-10 14:05:00Z]
    end

    test "is distinct from an ordinary undo: only fail stamps failed_at" do
      chore = chore_fixture()
      {:ok, _} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")

      {:ok, undone} = Chores.undo_chore(chore, la(~D[2026-07-10], ~T[07:05:00]))
      assert undone.failed_at == nil
    end

    test "returns an error when there is no live completion to fail" do
      chore = chore_fixture()

      assert {:error, :not_completed} =
               Chores.fail_chore(chore, la(~D[2026-07-10], ~T[07:00:00]))
    end

    test "the failed row is never deleted — it persists after the fail" do
      chore = chore_fixture()
      {:ok, completion} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")
      {:ok, _} = Chores.fail_chore(chore, la(~D[2026-07-10], ~T[07:05:00]))

      assert Repo.get!(Completion, completion.id)
    end

    test "broadcasts :chores_changed" do
      chore = chore_fixture()
      {:ok, _} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")

      :ok = Chores.subscribe()
      {:ok, _} = Chores.fail_chore(chore, la(~D[2026-07-10], ~T[07:05:00]))

      assert_receive :chores_changed
    end

    test "fail then redo nets to zero end-to-end through the write path (SC-3 worked example)" do
      kid = kid_fixture()
      # a baseline already-earned extra keeps the floored total away from
      # zero, so the fail's -value dip is actually observable (20 -> 25 -> 15 -> 20)
      base = chore_fixture(kid, %{name: "Base", routine: nil, points: 20})
      chore = chore_fixture(kid, %{name: "Extra", routine: nil, points: 5})

      {:ok, _} = Chores.complete_chore(base, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")
      {:ok, _} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[08:00:00]), "kiosk")
      assert Chores.earnings(kid, ~D[2026-07-10]) == 25

      {:ok, _} = Chores.fail_chore(chore, la(~D[2026-07-10], ~T[08:05:00]))
      assert Chores.earnings(kid, ~D[2026-07-10]) == 15

      {:ok, _} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[08:10:00]), "kiosk")
      assert Chores.earnings(kid, ~D[2026-07-10]) == 20
    end
  end

  describe "failed_chore_ids/1 (Story 06, D45, D46)" do
    import BearCub.ChoresFixtures

    test "returns the ids of chores with a failed completion on the given date" do
      chore = chore_fixture()
      {:ok, _} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")
      {:ok, _} = Chores.fail_chore(chore, la(~D[2026-07-10], ~T[07:05:00]))

      assert Chores.failed_chore_ids(~D[2026-07-10]) == MapSet.new([chore.id])
    end

    test "excludes chores with only an ordinary (non-failed) completion" do
      chore = chore_fixture()
      {:ok, _} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")
      {:ok, _} = Chores.undo_chore(chore, la(~D[2026-07-10], ~T[07:05:00]))

      assert Chores.failed_chore_ids(~D[2026-07-10]) == MapSet.new()
    end

    test "still includes a chore id after it has been redone — row-local, not gated on done-state" do
      chore = chore_fixture()
      {:ok, _} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")
      {:ok, _} = Chores.fail_chore(chore, la(~D[2026-07-10], ~T[07:05:00]))
      {:ok, _} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[07:10:00]), "kiosk")

      assert Chores.failed_chore_ids(~D[2026-07-10]) == MapSet.new([chore.id])
    end

    test "is scoped to the given local date" do
      chore = chore_fixture()
      {:ok, _} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")
      {:ok, _} = Chores.fail_chore(chore, la(~D[2026-07-10], ~T[07:05:00]))

      assert Chores.failed_chore_ids(~D[2026-07-11]) == MapSet.new()
    end
  end

  describe "PubSub" do
    import BearCub.ChoresFixtures

    defp noon, do: DateTime.new!(~D[2026-07-10], ~T[12:00:00], "America/Los_Angeles")

    test "every successful write broadcasts :chores_changed (FR-9)" do
      :ok = Chores.subscribe()

      {:ok, kid} = Chores.create_kid(%{name: "Kid A", color: "#f59e0b", position: 0})
      assert_receive :chores_changed

      {:ok, kid} = Chores.update_kid(kid, %{name: "Renamed"})
      assert_receive :chores_changed

      {:ok, chore} =
        Chores.create_chore(
          kid,
          %{name: "Brush Teeth", icon: "🪥", routine: "morning", position: 0},
          noon()
        )

      assert_receive :chores_changed

      {:ok, chore} = Chores.update_chore(chore, %{name: "Floss"})
      assert_receive :chores_changed

      {:ok, _} = Chores.complete_chore(chore, noon(), "kiosk")
      assert_receive :chores_changed

      {:ok, _} = Chores.undo_chore(chore, noon())
      assert_receive :chores_changed

      {:ok, _} = Chores.archive_chore(chore, noon())
      assert_receive :chores_changed
    end

    test "failed writes broadcast nothing" do
      kid = kid_fixture()
      :ok = Chores.subscribe()

      {:error, _} = Chores.create_chore(kid, %{}, la(~D[2026-07-10], ~T[08:00:00]))
      refute_receive :chores_changed, 50
    end
  end
end
