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
end
