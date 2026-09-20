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
      }),
      chore
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

  test "the on_delete: :delete_all FK safety net still cascades completions, though nothing in the app triggers it (Story 03, D78)" do
    chore = chore_fixture()
    {:ok, completion} = insert_completion(chore)

    Repo.delete!(chore)

    assert Repo.get(Completion, completion.id) == nil
  end

  test "failed_at is not cast from external params (D39, D40)" do
    chore = chore_fixture()

    {:ok, completion} = insert_completion(chore, %{failed_at: ~U[2026-07-10 14:31:00Z]})

    assert completion.failed_at == nil
  end

  test "effort_count is required on a counted chore (Story 01, SC-2)" do
    chore = chore_fixture(nil, %{routine: nil, unit_rate: 2, unit_max: 10})

    assert {:error, changeset} = insert_completion(chore)
    assert %{effort_count: [_]} = errors_on(changeset)
  end

  test "effort_count of 0 is refused on a counted chore (Story 01, SC-2)" do
    chore = chore_fixture(nil, %{routine: nil, unit_rate: 2, unit_max: 10})

    assert {:error, changeset} = insert_completion(chore, %{effort_count: 0})
    assert %{effort_count: [_]} = errors_on(changeset)
  end

  test "effort_count above the chore's unit_max is refused (Story 01, SC-2)" do
    chore = chore_fixture(nil, %{routine: nil, unit_rate: 2, unit_max: 10})

    assert {:error, changeset} = insert_completion(chore, %{effort_count: 11})
    assert %{effort_count: [_]} = errors_on(changeset)
  end

  test "effort_count within range is accepted on a counted chore (Story 01, SC-2)" do
    chore = chore_fixture(nil, %{routine: nil, unit_rate: 2, unit_max: 10})

    assert {:ok, completion} = insert_completion(chore, %{effort_count: 10})
    assert completion.effort_count == 10
  end

  test "effort_count is refused on a flat chore (Story 01, SC-2)" do
    chore = chore_fixture()

    assert {:error, changeset} = insert_completion(chore, %{effort_count: 3})
    assert %{effort_count: [_]} = errors_on(changeset)
  end

  test "a flat chore's completion carries no effort_count (Story 01, SC-2)" do
    chore = chore_fixture()

    assert {:ok, completion} = insert_completion(chore)
    assert completion.effort_count == nil
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
