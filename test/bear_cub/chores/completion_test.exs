defmodule BearCub.Chores.CompletionTest do
  use BearCub.DataCase

  import BearCub.ChoresFixtures

  alias BearCub.Chores.Completion

  defp insert_completion(chore, attrs \\ %{}) do
    %Completion{chore_id: chore.id}
    |> Completion.changeset(
      Enum.into(attrs, %{
        local_date: ~D[2026-07-10],
        completed_at: ~U[2026-07-10 14:30:00Z],
        source: "kiosk"
      })
    )
    |> Repo.insert()
  end

  test "at most one current completion per chore per day" do
    chore = chore_fixture()

    assert {:ok, _} = insert_completion(chore)
    assert {:error, changeset} = insert_completion(chore)
    assert %{chore_id: ["has already been taken"]} = errors_on(changeset)
  end

  test "an undone completion does not block a fresh one" do
    chore = chore_fixture()
    {:ok, first} = insert_completion(chore)

    {:ok, _undone} =
      first
      |> Ecto.Changeset.change(undone_at: ~U[2026-07-10 14:31:00Z])
      |> Repo.update()

    assert {:ok, _} = insert_completion(chore)
  end

  test "the same chore can be completed on different days" do
    chore = chore_fixture()

    assert {:ok, _} = insert_completion(chore)
    assert {:ok, _} = insert_completion(chore, %{local_date: ~D[2026-07-11]})
  end

  test "source must be kiosk or admin" do
    chore = chore_fixture()

    assert {:error, changeset} = insert_completion(chore, %{source: "alexa"})
    assert %{source: ["is invalid"]} = errors_on(changeset)
  end

  test "deleting a chore cascades its completions" do
    chore = chore_fixture()
    {:ok, completion} = insert_completion(chore)

    {:ok, _} = BearCub.Chores.delete_chore(chore)

    assert Repo.get(Completion, completion.id) == nil
  end

  test "failed_at is not cast from external params (D39, D40)" do
    chore = chore_fixture()

    {:ok, completion} = insert_completion(chore, %{failed_at: ~U[2026-07-10 14:31:00Z]})

    assert completion.failed_at == nil
  end

  test "failed_at can be stamped programmatically and the redo path stays open" do
    chore = chore_fixture()
    {:ok, first} = insert_completion(chore)

    {:ok, _failed} =
      first
      |> Ecto.Changeset.change(
        undone_at: ~U[2026-07-10 14:31:00Z],
        failed_at: ~U[2026-07-10 14:31:00Z]
      )
      |> Repo.update()

    assert {:ok, _} = insert_completion(chore)
  end
end
