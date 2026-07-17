defmodule BearCub.Routines do
  @moduledoc """
  Morning and Evening are application constants (D8) — this is a pure,
  DB-free helper over the `:routine_windows` config (design §3). No
  routines table, no CRUD; display names derive from the slug in the view.

  Nothing here reads the clock: every function takes the current *local*
  datetime as an argument. Windows are wall-clock `{start, end}` pairs
  within a single day (they must not span midnight), active when
  `start <= t < end`.
  """

  @doc "Active windows keyed by routine slug, from app config."
  def windows do
    Application.fetch_env!(:bear_cub, :routine_windows)
  end

  @doc """
  The routine the kiosk should show at `local_now`: `{:active, slug}`
  inside a window, or `{:upcoming, slug}` in a gap (overnight, 23:00-05:00,
  is Good Night mode — D32) — the routine whose window opens next.
  """
  def current(%DateTime{} = local_now, windows \\ windows()) do
    time = DateTime.to_time(local_now)

    case Enum.find(windows, fn {_slug, {starts, ends}} ->
           Time.compare(time, starts) != :lt and Time.compare(time, ends) == :lt
         end) do
      {slug, _window} -> {:active, slug}
      nil -> {:upcoming, next_opening(time, windows)}
    end
  end

  @doc """
  The next moment the kiosk must re-render: the nearest upcoming window
  edge today or next midnight, whichever is sooner (design §4). Midnight
  is always a boundary — the local date change *is* the daily reset (§2).
  """
  def next_boundary(%DateTime{} = local_now, windows \\ windows()) do
    time = DateTime.to_time(local_now)
    today = DateTime.to_date(local_now)

    edges_today =
      windows
      |> Enum.flat_map(fn {_slug, {starts, ends}} -> [starts, ends] end)
      |> Enum.filter(&(Time.compare(&1, time) == :gt))
      |> Enum.map(&local_datetime(today, &1, local_now.time_zone))

    midnight = local_datetime(Date.add(today, 1), ~T[00:00:00], local_now.time_zone)

    Enum.min([midnight | edges_today], DateTime)
  end

  @doc "The other routine — used by the admin Today view to render both routine sections."
  def other(:morning), do: :evening
  def other(:evening), do: :morning

  @doc "The fixed per-routine-day point bonus `R` (D39, D40), from app config."
  def bonus do
    Application.fetch_env!(:bear_cub, :routine_bonus)
  end

  defp next_opening(time, windows) do
    {slug, _window} =
      Enum.min_by(windows, fn {_slug, {starts, _ends}} ->
        # minutes until this window opens, wrapping past midnight
        Integer.mod(Time.diff(starts, time, :minute), 24 * 60)
      end)

    slug
  end

  # Window edges are wall-clock times; one falling in a DST gap or fold
  # resolves to a real nearby instant so the boundary timer always fires.
  defp local_datetime(date, time, tz) do
    case DateTime.new(date, time, tz) do
      {:ok, dt} -> dt
      {:gap, _just_before, just_after} -> just_after
      {:ambiguous, first, _second} -> first
    end
  end
end
