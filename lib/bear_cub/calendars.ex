defmodule BearCub.Calendars do
  @moduledoc """
  Calendar CRUD (D9) — admin-managed ICS URLs, one or more per kid plus
  family calendars (`kid_id: nil`). This context must never depend on
  `BearCub.Chores` (design §1): calendar trouble structurally cannot
  touch the chore path.
  """

  import Ecto.Query, warn: false
  require Logger

  alias BearCub.Repo
  alias BearCub.Calendars.Calendar
  alias BearCub.Calendars.ICS
  alias BearCub.LocalTime

  @topic "calendars"
  @instances_table :bear_cub_calendar_instances

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

  @doc "Writes the Refresher's fetch cache fields (never the admin-facing changeset)."
  def update_calendar_cache(%Calendar{} = calendar, attrs) do
    calendar
    |> Calendar.cache_changeset(attrs)
    |> Repo.update()
  end

  @doc "Fetch interval (design §6, config, default 10 minutes)."
  def refresh_interval_ms do
    Application.get_env(:bear_cub, :calendar_refresh_interval_ms, :timer.minutes(10))
  end

  @doc "Staleness threshold (FR-20, config, default 2 hours)."
  def staleness_threshold_ms do
    Application.get_env(:bear_cub, :calendar_staleness_threshold_ms, :timer.hours(2))
  end

  @doc """
  Whether `calendar` has gone stale — never successfully fetched, or its
  last successful fetch is older than `staleness_threshold_ms/0` as of
  `local_now`. A pure determination (FR-20); rendering the glyph is a
  consumer's job (kiosk, Story 04).
  """
  def stale?(%Calendar{last_fetched_at: nil}, %DateTime{}), do: true

  def stale?(%Calendar{last_fetched_at: last_fetched_at}, %DateTime{} = local_now) do
    DateTime.diff(local_now, last_fetched_at, :millisecond) > staleness_threshold_ms()
  end

  @doc """
  Parses every calendar's cached `last_payload` (if any) into the events
  store, without touching the network — boot-time hydration (FR-20's
  WAN-unplugged-reboot AC) so cached events are available immediately,
  before the first fetch of this boot completes.
  """
  def hydrate_cache(%DateTime{} = local_now) do
    list_calendars()
    |> Enum.each(fn calendar ->
      case calendar.last_payload && parse_and_expand(calendar.last_payload, local_now) do
        {:ok, instances} -> put_instances(calendar.id, instances)
        _ -> :ok
      end
    end)
  end

  @doc """
  Fetches, parses, and stores `calendar`'s events. On success, updates its
  cache fields and broadcasts on `"calendars"` only if the events changed.
  On any failure (transport, non-2xx, or a parse error), the previously
  stored events and `last_payload` are left untouched and `last_error` is
  recorded — a calendar is a degradable overlay (FR-20), never a crash.
  """
  def refresh_calendar(%Calendar{} = calendar, %DateTime{} = local_now) do
    calendar.ics_url
    |> Req.get(req_options())
    |> handle_fetch(calendar, local_now)
  rescue
    _ -> handle_failure(calendar, "fetch_error")
  end

  @doc "Refreshes every calendar; one calendar's failure never stops the rest."
  def refresh_all(%DateTime{} = local_now) do
    list_calendars() |> Enum.each(&refresh_calendar(&1, local_now))
  end

  @doc """
  Today's events for `kid_id` (design §6, FR-19, FR-22): that kid's own
  calendars blended with family calendars (`kid_id: nil`), each tagged
  `family?` for the kiosk's dot-vs-chip rendering, clipped to the local
  day window (`clipped_start?`/`clipped_end?` mark a midnight-spanning
  event so the kiosk can render "until 2:00 PM" instead of the full
  span), all-day events pinned ahead of timed events. `today` is the
  local date already decided by the caller.
  """
  def today_events(kid_id, %Date{} = today) do
    tz = LocalTime.timezone()
    day_start = local_datetime(today, ~T[00:00:00], tz) |> DateTime.shift_zone!("Etc/UTC")
    day_end = local_datetime(today, ~T[23:59:59], tz) |> DateTime.shift_zone!("Etc/UTC")

    list_calendars()
    |> Enum.filter(&(&1.kid_id == kid_id or is_nil(&1.kid_id)))
    |> Enum.flat_map(fn calendar ->
      calendar.id
      |> get_instances()
      |> Enum.map(&Map.put(Map.from_struct(&1), :family?, is_nil(calendar.kid_id)))
    end)
    |> Enum.filter(&overlaps?(&1, day_start, day_end))
    |> Enum.map(&clip_to_window(&1, day_start, day_end))
    |> sort_events()
  end

  @doc """
  Whether any calendar has gone stale as of `local_now` — the kiosk's
  staleness glyph is global (D4), not per-calendar.
  """
  def any_stale?(%DateTime{} = local_now) do
    Enum.any?(list_calendars(), &stale?(&1, local_now))
  end

  defp handle_fetch({:ok, %Req.Response{status: 200, body: body}}, calendar, local_now) do
    case parse_and_expand(body, local_now) do
      {:ok, instances} -> handle_success(calendar, body, instances, local_now)
      :error -> handle_failure(calendar, "parse_error")
    end
  end

  defp handle_fetch({:ok, %Req.Response{status: status}}, calendar, _local_now) do
    handle_failure(calendar, "http_#{status}")
  end

  defp handle_fetch({:error, _reason}, calendar, _local_now) do
    handle_failure(calendar, "fetch_error")
  end

  defp handle_success(calendar, body, instances, local_now) do
    previous = get_instances(calendar.id)
    put_instances(calendar.id, instances)

    {:ok, updated} =
      update_calendar_cache(calendar, %{
        last_payload: body,
        last_fetched_at:
          local_now |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second),
        last_error: nil
      })

    if instances != previous do
      Phoenix.PubSub.broadcast(BearCub.PubSub, @topic, :calendars_changed)
    end

    {:ok, updated}
  end

  defp handle_failure(calendar, reason) do
    Logger.warning("calendar refresh failed label=#{calendar.label} reason=#{reason}")
    update_calendar_cache(calendar, %{last_error: reason})
  end

  defp parse_and_expand(payload, local_now) do
    {window_start, window_end} = parse_window(local_now)
    ICS.parse(payload, window_start, window_end)
  rescue
    _ -> :error
  end

  defp parse_window(local_now) do
    tz = LocalTime.timezone()
    today = DateTime.to_date(local_now)

    window_start =
      today |> Date.add(-1) |> local_datetime(~T[00:00:00], tz) |> DateTime.shift_zone!("Etc/UTC")

    window_end =
      today |> Date.add(1) |> local_datetime(~T[23:59:59], tz) |> DateTime.shift_zone!("Etc/UTC")

    {window_start, window_end}
  end

  # A wall-clock edge falling in a DST gap or fold resolves to a real
  # nearby instant, matching BearCub.Routines' handling of the same case.
  defp local_datetime(date, time, tz) do
    case DateTime.new(date, time, tz) do
      {:ok, dt} -> dt
      {:gap, _just_before, just_after} -> just_after
      {:ambiguous, first, _second} -> first
    end
  end

  defp overlaps?(%{starts_at: starts_at, ends_at: ends_at}, window_start, window_end) do
    DateTime.compare(starts_at, window_end) != :gt and
      DateTime.compare(ends_at, window_start) != :lt
  end

  defp clip_to_window(event, day_start, day_end) do
    clipped_start? = DateTime.compare(event.starts_at, day_start) == :lt
    clipped_end? = DateTime.compare(event.ends_at, day_end) == :gt

    event
    |> Map.put(:starts_at, if(clipped_start?, do: day_start, else: event.starts_at))
    |> Map.put(:ends_at, if(clipped_end?, do: day_end, else: event.ends_at))
    |> Map.put(:clipped_start?, clipped_start?)
    |> Map.put(:clipped_end?, clipped_end?)
  end

  defp sort_events(events) do
    {all_day, timed} = Enum.split_with(events, & &1.all_day)

    Enum.sort_by(all_day, & &1.starts_at, DateTime) ++
      Enum.sort_by(timed, & &1.starts_at, DateTime)
  end

  defp req_options do
    # No built-in retry: the 10-minute refresh loop (design §6) is already
    # the retry mechanism, and a fetch failure must surface immediately so
    # the previous cache keeps serving without a multi-second stall.
    Keyword.merge(
      [receive_timeout: 10_000, retry: false],
      Application.get_env(:bear_cub, :calendars_req_options, [])
    )
  end

  defp ensure_instances_table do
    if :ets.whereis(@instances_table) == :undefined do
      :ets.new(@instances_table, [:named_table, :public, :set, read_concurrency: true])
    end
  end

  defp put_instances(calendar_id, instances) do
    ensure_instances_table()
    :ets.insert(@instances_table, {calendar_id, instances})
  end

  defp get_instances(calendar_id) do
    ensure_instances_table()

    case :ets.lookup(@instances_table, calendar_id) do
      [{^calendar_id, instances}] -> instances
      [] -> []
    end
  end
end
