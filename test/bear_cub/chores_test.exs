defmodule BearCub.ChoresTest do
  use BearCub.DataCase

  alias BearCub.Chores
  alias BearCub.Chores.Kid

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

    test "create_chore/2 creates a chore owned by the kid" do
      kid = kid_fixture()
      attrs = %{name: "Brush Teeth", icon: "🪥", routine: "morning", position: 0}

      assert {:ok, chore} = Chores.create_chore(kid, attrs)
      assert chore.kid_id == kid.id
      assert chore.icon == "🪥"
    end

    test "create_chore/2 requires an icon" do
      kid = kid_fixture()
      attrs = %{name: "Brush Teeth", routine: "morning", position: 0}

      assert {:error, changeset} = Chores.create_chore(kid, attrs)
      assert %{icon: ["can't be blank"]} = errors_on(changeset)
    end

    test "create_chore/2 rejects an unknown routine" do
      kid = kid_fixture()
      attrs = %{name: "Nap", icon: "😴", routine: "afternoon", position: 0}

      assert {:error, changeset} = Chores.create_chore(kid, attrs)
      assert %{routine: ["is invalid"]} = errors_on(changeset)
    end

    test "create_chore/2 with a nil routine creates an extra" do
      kid = kid_fixture()
      attrs = %{name: "Wash Car", icon: "🚗", routine: nil, position: 0}

      assert {:ok, chore} = Chores.create_chore(kid, attrs)
      assert chore.routine == nil
    end

    test "create_chore/2 with routine omitted creates an extra" do
      kid = kid_fixture()
      attrs = %{name: "Wash Car", icon: "🚗", position: 0}

      assert {:ok, chore} = Chores.create_chore(kid, attrs)
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

    test "delete_chore/1 deletes the chore" do
      chore = chore_fixture()

      assert {:ok, _} = Chores.delete_chore(chore)
      assert_raise Ecto.NoResultsError, fn -> Chores.get_chore!(chore.id) end
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

    test "create_chore/2 appends to the end of the kid's routine (D22)" do
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
        Chores.create_chore(kid, %{
          name: "Brush Teeth",
          icon: "🪥",
          routine: "morning",
          position: 7
        })

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

    test "create_chore/2 appends extras (nil routine) to the end of their own bucket (D22)" do
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

    test "move_chore/2 swaps across position gaps left by deletes" do
      kid = kid_fixture()
      first = chore_fixture(kid)
      middle = chore_fixture(kid, %{name: "Make Bed", icon: "🛏️"})
      last = chore_fixture(kid, %{name: "Get Dressed", icon: "👕"})
      {:ok, _} = Chores.delete_chore(middle)

      assert {:ok, moved} = Chores.move_chore(first, :down)
      assert moved.position == 2

      assert Enum.map(Chores.list_chores(kid, "morning"), & &1.id) == [last.id, first.id]
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

  describe "on-behalf toggling and day resets" do
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

    test "reset_kid_day/2 bulk-undoes only that kid's current completions (D21)" do
      kid_a = kid_fixture()
      kid_b = kid_fixture(%{position: 1})
      a_morning = chore_fixture(kid_a)
      a_evening = chore_fixture(kid_a, %{name: "Pajamas On", icon: "🌙", routine: "evening"})
      b_chore = chore_fixture(kid_b)

      {:ok, _} = Chores.complete_chore(a_morning, la(~D[2026-07-10], ~T[08:00:00]), "kiosk")
      {:ok, _} = Chores.complete_chore(a_evening, la(~D[2026-07-10], ~T[08:01:00]), "kiosk")
      {:ok, _} = Chores.complete_chore(b_chore, la(~D[2026-07-10], ~T[08:02:00]), "kiosk")

      assert {:ok, 2} = Chores.reset_kid_day(kid_a, la(~D[2026-07-10], ~T[13:00:00]))

      current = Chores.current_completions(~D[2026-07-10])
      refute Map.has_key?(current, a_morning.id)
      refute Map.has_key?(current, a_evening.id)
      assert Map.has_key?(current, b_chore.id)

      # bulk undo, not delete: all three rows survive with history intact (FR-17)
      assert Repo.aggregate(BearCub.Chores.Completion, :count) == 3
    end

    test "reset_day/1 bulk-undoes every kid's current completions, today only" do
      kid_a = kid_fixture()
      kid_b = kid_fixture(%{position: 1})
      a_chore = chore_fixture(kid_a)
      b_chore = chore_fixture(kid_b)

      {:ok, _} = Chores.complete_chore(a_chore, la(~D[2026-07-09], ~T[08:00:00]), "kiosk")
      {:ok, _} = Chores.complete_chore(a_chore, la(~D[2026-07-10], ~T[08:00:00]), "kiosk")
      {:ok, _} = Chores.complete_chore(b_chore, la(~D[2026-07-10], ~T[08:01:00]), "kiosk")

      assert {:ok, 2} = Chores.reset_day(la(~D[2026-07-10], ~T[13:00:00]))

      assert Chores.current_completions(~D[2026-07-10]) == %{}
      # yesterday's history is untouched
      assert Map.has_key?(Chores.current_completions(~D[2026-07-09]), a_chore.id)
    end

    test "a reset broadcasts :chores_changed exactly once" do
      chore = chore_fixture()
      {:ok, _} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[08:00:00]), "kiosk")
      :ok = Chores.subscribe()

      assert {:ok, 1} = Chores.reset_day(la(~D[2026-07-10], ~T[09:00:00]))

      assert_receive :chores_changed
      refute_receive :chores_changed, 50
    end

    test "resetting an already-clean day is {:ok, 0}" do
      assert {:ok, 0} = Chores.reset_day(la(~D[2026-07-10], ~T[09:00:00]))
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
        Chores.create_chore(kid, %{
          name: "Brush Teeth",
          icon: "🪥",
          routine: "morning",
          position: 0
        })

      assert_receive :chores_changed

      {:ok, chore} = Chores.update_chore(chore, %{name: "Floss"})
      assert_receive :chores_changed

      {:ok, _} = Chores.complete_chore(chore, noon(), "kiosk")
      assert_receive :chores_changed

      {:ok, _} = Chores.undo_chore(chore, noon())
      assert_receive :chores_changed

      {:ok, _} = Chores.delete_chore(chore)
      assert_receive :chores_changed
    end

    test "failed writes broadcast nothing" do
      kid = kid_fixture()
      :ok = Chores.subscribe()

      {:error, _} = Chores.create_chore(kid, %{})
      refute_receive :chores_changed, 50
    end
  end
end
