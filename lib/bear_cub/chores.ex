defmodule BearCub.Chores do
  @moduledoc """
  Kids, chores, and completions — pure local CRUD, no network.

  This context must never depend on `BearCub.Calendars` (design §1):
  calendar trouble structurally cannot touch the chore path.
  """

  import Ecto.Query, warn: false

  alias BearCub.Repo
  alias BearCub.Chores.Completion
  alias BearCub.Chores.Kid
  alias BearCub.Routines

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

  @doc """
  The kid's outstanding and done-today extras (nil-routine chores),
  ordered by position — a retired extra (current completion dated
  before `local_date`) never returns (design: extras visibility).
  """
  def list_extras(%Kid{} = kid, %Date{} = local_date) do
    retired_ids =
      from c in Completion,
        where: is_nil(c.undone_at) and c.local_date < ^local_date,
        select: c.chore_id

    Repo.all(
      from c in Chore,
        where: c.kid_id == ^kid.id and is_nil(c.routine) and c.id not in subquery(retired_ids),
        order_by: [asc: c.position, asc: c.id]
    )
  end

  def get_chore!(id), do: Repo.get!(Chore, id)

  @doc """
  Gets a single chore, or nil when it's gone — a stale tap racing an
  admin delete must no-op, never crash the view.
  """
  def get_chore(id), do: Repo.get(Chore, id)

  @doc """
  Creates a chore owned by `kid`, appended at the end of its routine's
  list (D22). `kid_id` and `position` are never cast from attrs — the
  ▲/▼ swap in `move_chore/2` is the only ordering control.
  """
  def create_chore(%Kid{} = kid, attrs) do
    changeset = Chore.changeset(%Chore{kid_id: kid.id}, attrs)
    routine = Ecto.Changeset.get_field(changeset, :routine)

    changeset
    |> Ecto.Changeset.put_change(:position, next_position(kid, routine))
    |> Repo.insert()
    |> broadcast_change()
  end

  @doc """
  Updates a chore. On a detected `routine` change, `position` is set to
  the next slot in the target bucket (`max+1`), never carrying the old
  value over (D35, reclassify re-appends). `position` is never cast
  from `attrs`.
  """
  def update_chore(%Chore{} = chore, attrs) do
    changeset = Chore.changeset(chore, attrs)

    changeset =
      case Ecto.Changeset.fetch_change(changeset, :routine) do
        {:ok, new_routine} ->
          Ecto.Changeset.put_change(
            changeset,
            :position,
            next_position(%Kid{id: chore.kid_id}, new_routine)
          )

        :error ->
          changeset
      end

    changeset
    |> Repo.update()
    |> broadcast_change()
  end

  def delete_chore(%Chore{} = chore) do
    chore
    |> Repo.delete()
    |> broadcast_change()
  end

  @doc """
  Swaps `chore`'s position with its neighbor in the same kid+routine
  list (D22) — `:up` toward position 0. At the list edge this is a
  silent no-op: `{:ok, chore}` unchanged, no broadcast.
  """
  def move_chore(%Chore{} = chore, direction) when direction in [:up, :down] do
    case neighbor(chore, direction) do
      nil ->
        {:ok, chore}

      other ->
        {:ok, moved} =
          Repo.transaction(fn ->
            {:ok, _} = other |> Ecto.Changeset.change(position: chore.position) |> Repo.update()

            {:ok, moved} =
              chore |> Ecto.Changeset.change(position: other.position) |> Repo.update()

            moved
          end)

        broadcast_change({:ok, moved})
    end
  end

  # The adjacent chore within the same kid+routine — position-gap tolerant
  # (deletes leave gaps; the nearest position wins, ties broken by id).
  # A pinned nil routine can't use `==` (Ecto forbids the unsafe NULL
  # comparison) — the extra bucket needs `is_nil/1` instead.
  defp neighbor(%Chore{routine: nil} = chore, :up) do
    Repo.one(
      from c in Chore,
        where:
          c.kid_id == ^chore.kid_id and is_nil(c.routine) and
            c.position < ^chore.position,
        order_by: [desc: c.position, desc: c.id],
        limit: 1
    )
  end

  defp neighbor(%Chore{} = chore, :up) do
    Repo.one(
      from c in Chore,
        where:
          c.kid_id == ^chore.kid_id and c.routine == ^chore.routine and
            c.position < ^chore.position,
        order_by: [desc: c.position, desc: c.id],
        limit: 1
    )
  end

  defp neighbor(%Chore{routine: nil} = chore, :down) do
    Repo.one(
      from c in Chore,
        where:
          c.kid_id == ^chore.kid_id and is_nil(c.routine) and
            c.position > ^chore.position,
        order_by: [asc: c.position, asc: c.id],
        limit: 1
    )
  end

  defp neighbor(%Chore{} = chore, :down) do
    Repo.one(
      from c in Chore,
        where:
          c.kid_id == ^chore.kid_id and c.routine == ^chore.routine and
            c.position > ^chore.position,
        order_by: [asc: c.position, asc: c.id],
        limit: 1
    )
  end

  defp next_position(%Kid{} = kid, nil) do
    max_position =
      Repo.one(
        from c in Chore,
          where: c.kid_id == ^kid.id and is_nil(c.routine),
          select: max(c.position)
      )

    (max_position || -1) + 1
  end

  defp next_position(%Kid{} = kid, routine) do
    max_position =
      Repo.one(
        from c in Chore,
          where: c.kid_id == ^kid.id and c.routine == ^routine,
          select: max(c.position)
      )

    (max_position || -1) + 1
  end

  def change_chore(%Chore{} = chore, attrs \\ %{}) do
    Chore.changeset(chore, attrs)
  end

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
  Fails `chore` for the local day of `local_now` (fail-on-inspection,
  D40): stamps both `undone_at` (reverting the chore to incomplete, so
  the child can redo) and `failed_at` (the persistent −points penalty,
  never cleared) on the current live completion. Distinct from
  `undo_chore/2`, which stamps only `undone_at`. `{:error, :not_completed}`
  when there is no live completion to fail.
  """
  def fail_chore(%Chore{} = chore, %DateTime{} = local_now) do
    case current_completion(chore, DateTime.to_date(local_now)) do
      nil ->
        {:error, :not_completed}

      completion ->
        at = to_utc(local_now)

        completion
        |> Ecto.Changeset.change(undone_at: at, failed_at: at)
        |> Repo.update()
        |> broadcast_change()
    end
  end

  @doc """
  Completes `chore` if it isn't done for the local day of `local_now`,
  undoes it if it is — the admin's on-behalf tap (FR-24). Returns the
  same shapes as `complete_chore/3`/`undo_chore/2`; a racing duplicate
  complete surfaces as `{:error, changeset}` — callers treat it as
  already-done.
  """
  def toggle_completion(%Chore{} = chore, %DateTime{} = local_now, source) do
    case undo_chore(chore, local_now) do
      {:error, :not_completed} -> complete_chore(chore, local_now, source)
      result -> result
    end
  end

  defp current_of_day(%Date{} = local_date) do
    from c in Completion, where: c.local_date == ^local_date and is_nil(c.undone_at)
  end

  @doc """
  All *current* completions for `local_date`, keyed by chore id — the
  kiosk's one done-today query (design §2). Yesterday needs no reset:
  the date argument changes and this returns empty.
  """
  def current_completions(%Date{} = local_date) do
    Repo.all(current_of_day(local_date))
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

  @doc """
  A single completion row's points contribution (D39, D40, design §6):
  checks `failed_at` first (the persistent penalty), then `undone_at`
  (an ordinary undo contributes nothing), otherwise the row is
  live/earned. Row-local — no clock, no date needed.
  """
  def extra_contribution(%Completion{} = completion, %Chore{} = chore) do
    cond do
      completion.failed_at -> -chore.points
      completion.undone_at -> 0
      true -> chore.points
    end
  end

  @doc """
  The capped per-`(kid, routine, local_date)` contribution (D40, D41):
  `+R` when every one of the kid's `routine` chores has a live
  completion on `local_date`, `-R` when one or more has a failed
  completion that day. `failed?` is a boolean per routine-day, never a
  per-row sum, so two or more fails still cost a single `-R` and routine
  points never scale with chore count (SC-2).
  """
  def routine_day_contribution(%Kid{} = kid, routine, %Date{} = local_date)
      when routine in ~w(morning evening) do
    chore_ids =
      Repo.all(
        from c in Chore,
          where: c.kid_id == ^kid.id and c.routine == ^routine,
          select: c.id
      )

    completions =
      Repo.all(
        from c in Completion,
          where: c.chore_id in ^chore_ids and c.local_date == ^local_date
      )

    complete? =
      chore_ids != [] and
        Enum.all?(chore_ids, fn chore_id ->
          Enum.any?(completions, &(&1.chore_id == chore_id and is_nil(&1.undone_at)))
        end)

    failed? = Enum.any?(completions, & &1.failed_at)

    r = Routines.bonus()
    if(complete?, do: r, else: 0) + if failed?, do: -r, else: 0
  end

  @doc """
  The floored, cumulative all-time points total for `kid` as of
  `local_date` (D41): `max(0, Σ routine-day contributions + Σ extra
  contributions + Σ other_signed_inputs)`, purely derived from
  `completions` — nothing stored, no reset job. Individual signed
  contributions are never clamped; see `extra_contribution/2` and
  `routine_day_contribution/3` to recover the raw signed sum (SC-4).

  `other_signed_inputs` is the D42 redemption seam: empty today (no
  redemption spends exist yet), kept in the summation shape so a future
  signed spend slots in without reshaping earnings.
  """
  def points_total(%Kid{} = kid, %Date{} = local_date) do
    extra_sum =
      Repo.all(
        from c in Completion,
          join: ch in Chore,
          on: ch.id == c.chore_id,
          where: ch.kid_id == ^kid.id and is_nil(ch.routine) and c.local_date <= ^local_date,
          select: {c, ch}
      )
      |> Enum.reduce(0, fn {completion, chore}, acc ->
        acc + extra_contribution(completion, chore)
      end)

    routine_sum =
      Repo.all(
        from c in Completion,
          join: ch in Chore,
          on: ch.id == c.chore_id,
          where: ch.kid_id == ^kid.id and not is_nil(ch.routine) and c.local_date <= ^local_date,
          distinct: true,
          select: {ch.routine, c.local_date}
      )
      |> Enum.reduce(0, fn {routine, date}, acc ->
        acc + routine_day_contribution(kid, routine, date)
      end)

    # D42 seam: no redemption spends exist yet, so this is always 0 today.
    other_signed_inputs = 0

    max(0, extra_sum + routine_sum + other_signed_inputs)
  end
end
