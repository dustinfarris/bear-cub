defmodule BearCub.Calendars.ICS do
  @moduledoc """
  Parses ICS payloads and expands recurring events into concrete instances
  within a bounded window.

  Hand-rolled per D16/story-01: the `icalendar` hex package silently drops
  RECURRENCE-ID (no struct field, no parser clause), so a moved/edited
  instance of a recurring event is indistinguishable from an unrelated
  one-off event sharing the same UID — a hard fail against the correctness
  bar. See story-01's Technical Notes for the evidence.
  """

  alias BearCub.Calendars.ICS.Instance

  # Safety net so a malformed/indefinite RRULE (no COUNT or UNTIL) cannot
  # loop forever: expansion always stops at window_end regardless, this is
  # just a hard backstop independent of that bound.
  @max_occurrences 1000

  @doc """
  Parses `ics` and returns concrete event instances overlapping
  `[window_start, window_end]` (both UTC `DateTime`s), with RRULE expanded,
  EXDATE instances excluded, and RECURRENCE-ID overrides applied.
  """
  @spec parse(binary(), DateTime.t(), DateTime.t()) :: {:ok, [Instance.t()]}
  def parse(ics, window_start, window_end) do
    events =
      ics
      |> unfold()
      |> extract_vevent_blocks()
      |> Enum.map(&parse_vevent/1)

    {masters, overrides} = Enum.split_with(events, &is_nil(&1.recurrence_id))
    overrides_by_uid = Enum.group_by(overrides, & &1.uid)

    {instances, consumed_overrides} =
      Enum.flat_map_reduce(masters, MapSet.new(), fn master, consumed ->
        candidate_overrides = Map.get(overrides_by_uid, master.uid, [])
        {occurrences, newly_consumed} = expand(master, candidate_overrides, window_end)
        {occurrences, MapSet.union(consumed, newly_consumed)}
      end)

    leftover_overrides =
      overrides
      |> Enum.reject(&MapSet.member?(consumed_overrides, &1))
      |> Enum.map(&to_instance/1)

    all_instances =
      (instances ++ leftover_overrides)
      |> Enum.filter(&overlaps?(&1, window_start, window_end))
      |> Enum.sort_by(& &1.starts_at, DateTime)

    {:ok, all_instances}
  end

  defp overlaps?(%Instance{starts_at: starts_at, ends_at: ends_at}, window_start, window_end) do
    DateTime.compare(starts_at, window_end) != :gt and
      DateTime.compare(ends_at, window_start) != :lt
  end

  # Expands a master event's RRULE (or the bare event, if no RRULE) into
  # instances, applying EXDATE exclusions and RECURRENCE-ID overrides.
  # Returns {instances, consumed_overrides}, the latter being the subset of
  # `candidate_overrides` that matched an occurrence (so callers can still
  # surface an override whose original occurrence fell outside the window).
  defp expand(master, candidate_overrides, window_end) do
    overrides_by_recurrence_id = Map.new(candidate_overrides, &{&1.recurrence_id, &1})

    occurrences =
      case master.rrule do
        nil -> [master]
        rrule -> expand_rrule(master, rrule, window_end)
      end

    occurrences
    |> Enum.reject(&excluded?(&1, master.exdates))
    |> Enum.map_reduce(MapSet.new(), fn occurrence, consumed ->
      case Map.get(overrides_by_recurrence_id, occurrence.dtstart_utc) do
        nil -> {to_instance(occurrence), consumed}
        override -> {to_instance(override), MapSet.put(consumed, override)}
      end
    end)
  end

  defp excluded?(%{dtstart_utc: dtstart_utc}, exdates), do: dtstart_utc in exdates

  defp expand_rrule(master, rrule, window_end) do
    interval = Map.get(rrule, :interval, 1)
    until = Map.get(rrule, :until)
    bound = earliest(until, window_end)

    case {rrule.freq, Map.get(rrule, :byday)} do
      {"DAILY", _} ->
        expand_by_step(master, interval, bound)

      {"WEEKLY", nil} ->
        expand_by_step(master, interval * 7, bound)

      {"WEEKLY", byday} ->
        expand_weekly_byday(master, byday, interval, bound)

      {"MONTHLY", byday} when not is_nil(byday) ->
        expand_monthly_byday(master, byday, interval, bound)

      {_unsupported_freq, _byday} ->
        []
    end
  end

  defp earliest(nil, b), do: b
  defp earliest(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)

  defp expand_by_step(master, step_days, bound) do
    Stream.iterate(0, &(&1 + 1))
    |> Stream.take(@max_occurrences)
    |> Stream.map(&shift_occurrence(master, &1 * step_days))
    |> Enum.reduce_while([], fn occurrence, acc ->
      if DateTime.compare(occurrence.dtstart_utc, bound) == :gt do
        {:halt, acc}
      else
        {:cont, [occurrence | acc]}
      end
    end)
    |> Enum.reverse()
  end

  @weekday_offsets %{"MO" => 0, "TU" => 1, "WE" => 2, "TH" => 3, "FR" => 4, "SA" => 5, "SU" => 6}

  defp expand_weekly_byday(master, bydays, interval, bound) do
    start_date = NaiveDateTime.to_date(master.dtstart_naive)
    offsets = bydays |> Enum.map(&Map.fetch!(@weekday_offsets, &1)) |> Enum.sort()

    Stream.iterate(0, &(&1 + 1))
    |> Stream.take(@max_occurrences)
    |> Stream.flat_map(fn week_index ->
      week_offset_days = week_index * interval * 7

      Enum.map(offsets, fn weekday_offset ->
        day_delta = week_offset_days + weekday_offset - (Date.day_of_week(start_date) - 1)
        shift_occurrence(master, day_delta)
      end)
    end)
    |> Enum.reduce_while({[], false}, fn occurrence, {acc, _any_in_week} ->
      cond do
        Date.compare(NaiveDateTime.to_date(occurrence.dtstart_naive), start_date) == :lt ->
          {:cont, {acc, false}}

        DateTime.compare(occurrence.dtstart_utc, bound) == :gt ->
          {:halt, {acc, false}}

        true ->
          {:cont, {[occurrence | acc], true}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp expand_monthly_byday(master, bydays, interval, bound) do
    start_date = NaiveDateTime.to_date(master.dtstart_naive)
    ordinal_weekdays = Enum.map(bydays, &parse_ordinal_weekday/1)

    Stream.iterate(0, &(&1 + 1))
    |> Stream.take(@max_occurrences)
    |> Stream.flat_map(fn month_index ->
      %{year: year, month: month} = shift_months(start_date, month_index * interval)

      Enum.map(ordinal_weekdays, fn {ordinal, weekday_offset} ->
        year
        |> nth_weekday_of_month(month, ordinal, weekday_offset)
        |> then(&shift_occurrence_to_date(master, &1))
      end)
    end)
    |> Enum.reduce_while([], fn occurrence, acc ->
      cond do
        Date.compare(NaiveDateTime.to_date(occurrence.dtstart_naive), start_date) == :lt ->
          {:cont, acc}

        DateTime.compare(occurrence.dtstart_utc, bound) == :gt ->
          {:halt, acc}

        true ->
          {:cont, [occurrence | acc]}
      end
    end)
    |> Enum.reverse()
  end

  defp parse_ordinal_weekday(value) do
    {ordinal, weekday_code} = String.split_at(value, byte_size(value) - 2)
    {String.to_integer(ordinal), Map.fetch!(@weekday_offsets, weekday_code)}
  end

  defp shift_months(date, month_delta) do
    total_months = date.month - 1 + month_delta
    Date.new!(date.year + div(total_months, 12), rem(total_months, 12) + 1, 1)
  end

  defp nth_weekday_of_month(year, month, ordinal, weekday_offset) do
    first_of_month = Date.new!(year, month, 1)
    first_weekday_offset = Date.day_of_week(first_of_month) - 1
    days_until_first_match = Integer.mod(weekday_offset - first_weekday_offset, 7)
    first_match = Date.add(first_of_month, days_until_first_match)
    Date.add(first_match, (ordinal - 1) * 7)
  end

  defp shift_occurrence_to_date(master, date) do
    time = NaiveDateTime.to_time(master.dtstart_naive)
    duration = NaiveDateTime.diff(master.dtend_naive, master.dtstart_naive)

    dtstart_naive = NaiveDateTime.new!(date, time)
    dtend_naive = NaiveDateTime.add(dtstart_naive, duration, :second)

    %{
      master
      | dtstart_naive: dtstart_naive,
        dtend_naive: dtend_naive,
        dtstart_utc: localize(dtstart_naive, master.tzid),
        dtend_utc: localize(dtend_naive, master.tzid)
    }
  end

  defp shift_occurrence(master, day_delta) do
    dtstart_naive = NaiveDateTime.add(master.dtstart_naive, day_delta, :day)
    dtend_naive = NaiveDateTime.add(master.dtend_naive, day_delta, :day)

    %{
      master
      | dtstart_naive: dtstart_naive,
        dtend_naive: dtend_naive,
        dtstart_utc: localize(dtstart_naive, master.tzid),
        dtend_utc: localize(dtend_naive, master.tzid)
    }
  end

  defp localize(naive, tzid) do
    {:ok, datetime} =
      DateTime.new(NaiveDateTime.to_date(naive), NaiveDateTime.to_time(naive), tzid)

    DateTime.shift_zone!(datetime, "Etc/UTC")
  end

  defp unfold(ics) do
    ics
    |> String.split(["\r\n", "\n"])
    |> Enum.reduce([], fn
      <<" ", rest::binary>>, [prev | acc] -> [prev <> rest | acc]
      <<"\t", rest::binary>>, [prev | acc] -> [prev <> rest | acc]
      line, acc -> [line | acc]
    end)
    |> Enum.reverse()
  end

  defp extract_vevent_blocks(lines) do
    lines
    |> Enum.chunk_while(
      nil,
      fn
        "BEGIN:VEVENT", nil -> {:cont, []}
        "END:VEVENT", block when is_list(block) -> {:cont, Enum.reverse(block), nil}
        _line, nil -> {:cont, nil}
        line, block -> {:cont, [line | block]}
      end,
      fn
        nil -> {:cont, nil}
        block -> {:cont, Enum.reverse(block), nil}
      end
    )
    |> Enum.reject(&is_nil/1)
  end

  defp parse_vevent(lines) do
    properties =
      Enum.reduce(lines, %{}, fn line, acc ->
        case String.split(line, ":", parts: 2) do
          [key_and_params, value] ->
            {key, params} = split_params(key_and_params)
            Map.update(acc, key, [{params, value}], &(&1 ++ [{params, value}]))

          _ ->
            acc
        end
      end)

    {dtstart_utc, all_day} = parse_datetime(properties, "DTSTART")
    {dtend_utc, _} = parse_datetime(properties, "DTEND")
    dtstart_naive = naive_value(properties, "DTSTART")
    dtend_naive = naive_value(properties, "DTEND")
    tzid = tzid_of(properties, "DTSTART")

    %{
      uid: single_value(properties, "UID"),
      summary: single_value(properties, "SUMMARY"),
      location: single_value(properties, "LOCATION"),
      dtstart_utc: dtstart_utc,
      dtend_utc: dtend_utc,
      dtstart_naive: dtstart_naive,
      dtend_naive: dtend_naive,
      tzid: tzid,
      all_day: all_day,
      rrule: parse_rrule(properties),
      exdates: parse_exdates(properties),
      recurrence_id: parse_recurrence_id(properties)
    }
  end

  defp split_params(key_and_params) do
    case String.split(key_and_params, ";") do
      [key | params] ->
        params =
          Map.new(params, fn param ->
            case String.split(param, "=", parts: 2) do
              [k, v] -> {k, v}
              [k] -> {k, nil}
            end
          end)

        {key, params}
    end
  end

  defp to_instance(event) do
    %Instance{
      uid: event.uid,
      summary: event.summary,
      location: event.location,
      starts_at: event.dtstart_utc,
      ends_at: event.dtend_utc,
      all_day: event.all_day
    }
  end

  defp single_value(properties, key) do
    case Map.get(properties, key) do
      [{_params, value} | _] -> value
      _ -> nil
    end
  end

  defp parse_datetime(properties, key) do
    case Map.get(properties, key) do
      [{params, value} | _] -> parse_ics_datetime(value, params)
      _ -> {nil, false}
    end
  end

  defp naive_value(properties, key) do
    case Map.get(properties, key) do
      [{%{"VALUE" => "DATE"}, value} | _] -> naive_datetime(value <> "T000000")
      [{_params, value} | _] -> naive_datetime(String.trim_trailing(value, "Z"))
      _ -> nil
    end
  end

  defp tzid_of(properties, key) do
    case Map.get(properties, key) do
      [{%{"TZID" => tzid}, _value} | _] -> tzid
      _ -> "Etc/UTC"
    end
  end

  defp parse_rrule(properties) do
    case Map.get(properties, "RRULE") do
      [{_params, value} | _] -> do_parse_rrule(value)
      _ -> nil
    end
  end

  defp do_parse_rrule(value) do
    value
    |> String.split(";")
    |> Map.new(fn part ->
      [key, val] = String.split(part, "=", parts: 2)
      {key, val}
    end)
    |> Enum.reduce(%{}, fn
      {"FREQ", v}, acc -> Map.put(acc, :freq, v)
      {"INTERVAL", v}, acc -> Map.put(acc, :interval, String.to_integer(v))
      {"BYDAY", v}, acc -> Map.put(acc, :byday, String.split(v, ","))
      {"UNTIL", v}, acc -> Map.put(acc, :until, elem(parse_ics_datetime(v, %{}), 0))
      _, acc -> acc
    end)
  end

  defp parse_exdates(properties) do
    properties
    |> Map.get("EXDATE", [])
    |> Enum.map(fn {params, value} -> elem(parse_ics_datetime(value, params), 0) end)
  end

  defp parse_recurrence_id(properties) do
    case Map.get(properties, "RECURRENCE-ID") do
      [{params, value} | _] -> elem(parse_ics_datetime(value, params), 0)
      _ -> nil
    end
  end

  defp parse_ics_datetime(value, %{"VALUE" => "DATE"}) do
    date = Date.from_iso8601!(date_iso8601(value))
    {:ok, datetime} = DateTime.new(date, ~T[00:00:00], "Etc/UTC")
    {datetime, true}
  end

  defp parse_ics_datetime(<<_::binary-size(8), "T", _rest::binary>> = value, %{"TZID" => tzid}) do
    naive = naive_datetime(value)

    {:ok, datetime} =
      DateTime.new(NaiveDateTime.to_date(naive), NaiveDateTime.to_time(naive), tzid)

    {DateTime.shift_zone!(datetime, "Etc/UTC"), false}
  end

  defp parse_ics_datetime(value, _params) do
    naive = naive_datetime(String.trim_trailing(value, "Z"))

    datetime =
      DateTime.new!(NaiveDateTime.to_date(naive), NaiveDateTime.to_time(naive), "Etc/UTC")

    {datetime, false}
  end

  defp date_iso8601(<<y::binary-size(4), m::binary-size(2), d::binary-size(2)>>) do
    "#{y}-#{m}-#{d}"
  end

  defp naive_datetime(
         <<y::binary-size(4), mo::binary-size(2), d::binary-size(2), "T", h::binary-size(2),
           mi::binary-size(2), s::binary-size(2)>>
       ) do
    NaiveDateTime.from_iso8601!("#{y}-#{mo}-#{d}T#{h}:#{mi}:#{s}")
  end
end
