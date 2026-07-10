defmodule BearCub.SeedsTest do
  use BearCub.DataCase

  alias BearCub.Chores
  alias BearCub.Chores.{Chore, Kid}

  defp run_seeds do
    Code.eval_file("priv/repo/seeds.exs")
  end

  test "seeds create two placeholder kids and demo chores on an empty database" do
    run_seeds()

    assert [
             %Kid{name: "Kid A", color: "#f59e0b", position: 0} = kid_a,
             %Kid{name: "Kid B", color: "#0ea5e9", position: 1} = kid_b
           ] = Chores.list_kids()

    assert length(Chores.list_chores(kid_a, "morning")) == 5
    assert length(Chores.list_chores(kid_b, "morning")) == 5
  end

  test "seeds are idempotent" do
    run_seeds()
    run_seeds()

    assert Repo.aggregate(Kid, :count) == 2
    # 2 kids x (5 morning + 2 evening)
    assert Repo.aggregate(Chore, :count) == 14
  end

  test "seeds never modify existing rows" do
    {:ok, kid} = Chores.create_kid(%{name: "Already Renamed", color: "#22c55e", position: 0})

    run_seeds()

    assert Repo.aggregate(Kid, :count) == 1
    assert Chores.get_kid!(kid.id).name == "Already Renamed"
  end
end
