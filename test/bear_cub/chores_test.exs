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

    test "list_chores/2 returns the kid's chores for a routine, ordered by position" do
      kid = kid_fixture()
      other_kid = kid_fixture(%{position: 1})
      second = chore_fixture(kid, %{name: "Make Bed", icon: "🛏️", position: 1})
      first = chore_fixture(kid, %{position: 0})
      _evening = chore_fixture(kid, %{routine: "evening", position: 0})
      _other_kids = chore_fixture(other_kid, %{position: 0})

      assert Chores.list_chores(kid, "morning") == [first, second]
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

    test "update_chore/2 updates name, icon, and position" do
      chore = chore_fixture()

      assert {:ok, chore} = Chores.update_chore(chore, %{name: "Floss", icon: "🦷", position: 3})
      assert chore.name == "Floss"
      assert chore.icon == "🦷"
      assert chore.position == 3
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
