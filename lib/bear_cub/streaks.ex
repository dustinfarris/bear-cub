defmodule BearCub.Streaks do
  @moduledoc """
  Each kid's current and longest good-standing streak (D154, D155, D156),
  computed from everything recorded and never stored.

  A streak day is a good-standing day, exactly (D91): the evening of the
  day before and that day's morning are both complete and unfailed, under
  the date-bounded rosters of D81/D90 and the empty-roster pass of D92.
  The routine-day facts come from `Chores.routine_day_facts/1`, the same
  rows earnings read, so the two cannot disagree; the parity test against
  `Chores.standing/2` guards that.

  The scan starts at the kid's first completion ever, since otherwise the
  empty-roster pass would make every day before the kid had chores a
  standing day. From there every day is judged, weekends included.

  Today is three-valued (D156): before its standing is decided the streak
  shows the run ending yesterday, and it resets to 0 only once today can no
  longer be met.

  Pure over its inputs apart from a fixed number of reads; no clock reads
  (the caller passes the local datetime and today's `DayEntry`), and no
  schedule history: only today's `morning_end` is consulted.
  """

  import Ecto.Query

  alias BearCub.Chores
  alias BearCub.Chores.{Chore, Completion, Kid}
  alias BearCub.Repo
  alias BearCub.Schedules.DayEntry

  @doc """
  `%{kid_id => %{current: n, longest: n, today: :standing | :pending | :failed}}`
  for every kid, in four queries regardless of history length.
  """
  def by_kid(%DateTime{} = local_now, %DayEntry{} = entry) do
    today = DateTime.to_date(local_now)

    facts = Chores.routine_day_facts(today)
    firsts = first_completions()
    chores = Enum.group_by(routine_chores(), & &1.kid_id)
    facts = Enum.group_by(facts, & &1.kid_id)

    for kid_id <- Repo.all(from k in Kid, select: k.id), into: %{} do
      {kid_id,
       compute(
         Map.get(firsts, kid_id),
         Map.get(chores, kid_id, []),
         Map.get(facts, kid_id, []),
         local_now,
         entry
       )}
    end
  end

  defp compute(nil, _chores, _facts, _local_now, _entry),
    do: %{current: 0, longest: 0, today: :pending}

  defp compute(first, chores, facts, local_now, entry) do
    today = DateTime.to_date(local_now)
    status = status_fun(chores, facts)

    # Standing flag for each day from the first completion through today.
    {past_runs, run} =
      first
      |> Date.range(Date.add(today, -1), 1)
      |> Enum.reduce({[], 0}, fn day, {runs, run} ->
        if standing?(status, day), do: {runs, run + 1}, else: {[run | runs], 0}
      end)

    today_state = today_state(status, today, local_now, entry)
    longest = Enum.max([run | past_runs])

    case today_state do
      :standing -> %{current: run + 1, longest: max(longest, run + 1), today: :standing}
      :pending -> %{current: run, longest: longest, today: :pending}
      :failed -> %{current: 0, longest: longest, today: :failed}
    end
  end

  # D156. Evening of last night bad, or a failed morning, loses the day
  # outright; an unfailed complete morning is standing; an incomplete one is
  # pending until the morning window closes.
  defp today_state(status, today, local_now, entry) do
    evening = status.(Date.add(today, -1), "evening")
    morning = status.(today, "morning")

    cond do
      not evening.complete? or evening.failed? -> :failed
      morning.failed? -> :failed
      morning.complete? -> :standing
      Time.compare(DateTime.to_time(local_now), entry.morning_end) != :lt -> :failed
      true -> :pending
    end
  end

  defp standing?(status, day) do
    morning = status.(day, "morning")
    evening = status.(Date.add(day, -1), "evening")
    morning.complete? and not morning.failed? and evening.complete? and not evening.failed?
  end

  # `status.(day, routine)` -> %{complete?, failed?}. A day with a facts row
  # is judged by its counts; one without is incomplete when the roster that
  # day is non-empty and vacuously complete when it is empty (D92).
  defp status_fun(chores, facts) do
    rows = Map.new(facts, &{{&1.routine, &1.local_date}, &1})

    fn day, routine ->
      case Map.get(rows, {routine, day}) do
        nil ->
          %{complete?: not Enum.any?(chores, &live?(&1, routine, day)), failed?: false}

        row ->
          %{
            complete?: row.chore_count > 0 and row.live_count == row.chore_count,
            failed?: row.any_failed == 1
          }
      end
    end
  end

  defp live?(chore, routine, day) do
    chore.routine == routine and Date.compare(chore.active_from, day) != :gt and
      (is_nil(chore.archived_on) or Date.compare(chore.archived_on, day) == :gt)
  end

  defp routine_chores do
    Repo.all(
      from c in Chore,
        where: not is_nil(c.routine),
        select: %{
          kid_id: c.kid_id,
          routine: c.routine,
          active_from: c.active_from,
          archived_on: c.archived_on
        }
    )
  end

  defp first_completions do
    from(c in Completion,
      join: ch in Chore,
      on: ch.id == c.chore_id,
      group_by: ch.kid_id,
      select: {ch.kid_id, min(c.local_date)}
    )
    |> Repo.all()
    |> Map.new()
  end
end
