defmodule BearCub.Calendars do
  @moduledoc """
  Calendar CRUD (D9) — admin-managed ICS URLs, one or more per kid plus
  family calendars (`kid_id: nil`). This context must never depend on
  `BearCub.Chores` (design §1): calendar trouble structurally cannot
  touch the chore path.
  """

  import Ecto.Query, warn: false

  alias BearCub.Repo
  alias BearCub.Calendars.Calendar

  @topic "calendars"

  @doc """
  Subscribes the caller to calendar-domain changes (design §4).
  Every successful write in this context sends `:calendars_changed`;
  subscribers re-fetch rather than patching state from a payload.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(BearCub.PubSub, @topic)
  end

  defp broadcast_change({:ok, _} = result) do
    Phoenix.PubSub.broadcast(BearCub.PubSub, @topic, :calendars_changed)
    result
  end

  defp broadcast_change(result), do: result

  @doc "All calendars, family calendars (kid_id: nil) sorted first."
  def list_calendars do
    Repo.all(from c in Calendar, order_by: [asc: c.kid_id, asc: c.label])
  end

  @doc "Gets a single calendar. Raises `Ecto.NoResultsError` if absent."
  def get_calendar!(id), do: Repo.get!(Calendar, id)

  @doc "Creates a calendar, family-owned unless `kid_id` is given."
  def create_calendar(attrs) do
    %Calendar{}
    |> Calendar.changeset(attrs)
    |> Repo.insert()
    |> broadcast_change()
  end

  @doc "Updates a calendar's label, ICS URL, or kid assignment."
  def update_calendar(%Calendar{} = calendar, attrs) do
    calendar
    |> Calendar.changeset(attrs)
    |> Repo.update()
    |> broadcast_change()
  end

  @doc "Deletes a calendar."
  def delete_calendar(%Calendar{} = calendar) do
    calendar
    |> Repo.delete()
    |> broadcast_change()
  end

  def change_calendar(%Calendar{} = calendar, attrs \\ %{}) do
    Calendar.changeset(calendar, attrs)
  end
end
