defmodule BearCub.Schedules do
  @moduledoc """
  The routine schedule as an append-only history (D120): each save inserts
  a full `ScheduleVersion` in force from the moment of the save, and no
  version is ever updated or deleted, so a later change can never re-price
  what was already earned. Depends on nothing else in the app; resolving
  which version applies at an instant is the pure `BearCub.Routines`.

  The "now" a save is stamped with is taken here, at the context boundary,
  like every other write's timestamp.
  """

  import Ecto.Query, warn: false

  alias BearCub.Repo
  alias BearCub.Schedules.ScheduleVersion

  @topic "schedules"

  @doc "Subscribes the caller to `:schedule_changed`, sent after each recorded save."
  def subscribe do
    Phoenix.PubSub.subscribe(BearCub.PubSub, @topic)
  end

  @doc "The full history, oldest first."
  def versions do
    Repo.all(from v in ScheduleVersion, order_by: [asc: v.effective_at])
  end

  @doc "The latest version. Raises when the table is empty — a broken migration."
  def current do
    Repo.one!(from v in ScheduleVersion, order_by: [desc: v.effective_at], limit: 1)
  end

  @doc """
  A form changeset prefilled from the version in force, with `attrs`
  layered over it. Never persisted by itself; `change/2` records it.
  """
  def change_version(attrs \\ %{}) do
    ScheduleVersion.changeset(prefill(current()), attrs)
  end

  @doc """
  Records `attrs` as a new version effective `now`, then broadcasts
  `:schedule_changed`. A schedule identical to the one in force records
  nothing, broadcasts nothing and returns `{:ok, current}`. A second save
  in the same second fails as an `effective_at` changeset error — one
  household, so "try again" is the whole concurrency story.
  """
  def change(attrs, now \\ DateTime.utc_now()) do
    current = current()
    changeset = ScheduleVersion.changeset(prefill(current), attrs)

    with {:ok, proposed} <- Ecto.Changeset.apply_action(changeset, :validate) do
      if same_schedule?(proposed, current) do
        {:ok, current}
      else
        changeset
        |> ScheduleVersion.effective_at(now)
        |> Repo.insert()
        |> broadcast_change()
      end
    end
  end

  # A new, id-less struct carrying the current schedule's values: the
  # changeset's data. Unsubmitted fields keep their current value.
  defp prefill(%ScheduleVersion{} = current) do
    %ScheduleVersion{
      routine_bonus: current.routine_bonus,
      early_bird_bonus: current.early_bird_bonus,
      days: current.days
    }
  end

  defp same_schedule?(a, b) do
    a.routine_bonus == b.routine_bonus and a.early_bird_bonus == b.early_bird_bonus and
      sorted_days(a) == sorted_days(b)
  end

  defp sorted_days(version), do: Enum.sort_by(version.days, & &1.weekday)

  defp broadcast_change({:ok, _} = result) do
    Phoenix.PubSub.broadcast(BearCub.PubSub, @topic, :schedule_changed)
    result
  end

  defp broadcast_change(result), do: result
end
