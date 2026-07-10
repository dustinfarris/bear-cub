defmodule BearCub.Chores do
  @moduledoc """
  Kids, chores, and completions — pure local CRUD, no network.

  This context must never depend on `BearCub.Calendars` (design §1):
  calendar trouble structurally cannot touch the chore path.
  """

  import Ecto.Query, warn: false

  alias BearCub.Repo
  alias BearCub.Chores.Kid

  @topic "chores"

  @doc """
  Subscribes the caller to chore-domain changes (FR-9, design §4).
  Every successful write in this context sends `:chores_changed`;
  subscribers re-fetch rather than patching state from a payload.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(BearCub.PubSub, @topic)
  end

  defp broadcast_change({:ok, _} = result) do
    Phoenix.PubSub.broadcast(BearCub.PubSub, @topic, :chores_changed)
    result
  end

  defp broadcast_change(result), do: result

  @doc "All kids ordered for display: position 0 is the left column."
  def list_kids do
    Repo.all(from k in Kid, order_by: [asc: k.position, asc: k.id])
  end

  @doc "Gets a single kid. Raises `Ecto.NoResultsError` if absent."
  def get_kid!(id), do: Repo.get!(Kid, id)

  @doc "Creates a kid."
  def create_kid(attrs) do
    %Kid{}
    |> Kid.changeset(attrs)
    |> Repo.insert()
    |> broadcast_change()
  end

  @doc "Updates a kid (rename/recolor — kids are edit-only in v1, design §1)."
  def update_kid(%Kid{} = kid, attrs) do
    kid
    |> Kid.changeset(attrs)
    |> Repo.update()
    |> broadcast_change()
  end

  def change_kid(%Kid{} = kid, attrs \\ %{}) do
    Kid.changeset(kid, attrs)
  end

  alias BearCub.Chores.Chore

  @doc "The kid's chores for one routine, in parent-controlled order."
  def list_chores(%Kid{} = kid, routine) when routine in ~w(morning evening) do
    Repo.all(
      from c in Chore,
        where: c.kid_id == ^kid.id and c.routine == ^routine,
        order_by: [asc: c.position, asc: c.id]
    )
  end

  def get_chore!(id), do: Repo.get!(Chore, id)

  @doc "Creates a chore owned by `kid`. `kid_id` is never cast from attrs."
  def create_chore(%Kid{} = kid, attrs) do
    %Chore{kid_id: kid.id}
    |> Chore.changeset(attrs)
    |> Repo.insert()
    |> broadcast_change()
  end

  def update_chore(%Chore{} = chore, attrs) do
    chore
    |> Chore.changeset(attrs)
    |> Repo.update()
    |> broadcast_change()
  end

  def delete_chore(%Chore{} = chore) do
    Repo.delete(chore)
    |> broadcast_change()
  end

  def change_chore(%Chore{} = chore, attrs \\ %{}) do
    Chore.changeset(chore, attrs)
  end

  alias BearCub.Chores.Completion

  @doc """
  Marks `chore` done for the local day of `local_now` (design §2: inserts
  a dated fact — there is no completed flag anywhere). A racing duplicate
  hits the partial unique index and returns `{:error, changeset}` —
  callers treat that as already-done.
  """
  def complete_chore(%Chore{} = chore, %DateTime{} = local_now, source) do
    %Completion{chore_id: chore.id}
    |> Completion.changeset(%{
      local_date: DateTime.to_date(local_now),
      completed_at: to_utc(local_now),
      source: source
    })
    |> Repo.insert()
    |> broadcast_change()
  end

  @doc """
  Undoes the current completion of `chore` for the local day of
  `local_now` by stamping `undone_at` — the row is retained, never
  deleted (FR-17). `{:error, :not_completed}` when the chore isn't done.
  """
  def undo_chore(%Chore{} = chore, %DateTime{} = local_now) do
    case current_completion(chore, DateTime.to_date(local_now)) do
      nil ->
        {:error, :not_completed}

      completion ->
        completion
        |> Ecto.Changeset.change(undone_at: to_utc(local_now))
        |> Repo.update()
        |> broadcast_change()
    end
  end

  @doc """
  All *current* completions for `local_date`, keyed by chore id — the
  kiosk's one done-today query (design §2). Yesterday needs no reset:
  the date argument changes and this returns empty.
  """
  def current_completions(%Date{} = local_date) do
    Repo.all(from c in Completion, where: c.local_date == ^local_date and is_nil(c.undone_at))
    |> Map.new(&{&1.chore_id, &1})
  end

  defp current_completion(%Chore{} = chore, %Date{} = local_date) do
    Repo.one(
      from c in Completion,
        where: c.chore_id == ^chore.id and c.local_date == ^local_date and is_nil(c.undone_at)
    )
  end

  defp to_utc(%DateTime{} = local) do
    local |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)
  end
end
