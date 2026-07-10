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
end
