defmodule BearCub.ScheduleHelpers do
  @moduledoc """
  Test helpers that stage the routine schedule as version inserts (D126).
  Tests still run on the real clock (D119); a helper writes a version
  already in force, so the kiosk and Today screen resolve it like any
  saved schedule.

  `pin_default_schedule/0` runs in the LiveView test case's setup: morning
  open all day, evening never, identical on all seven weekdays, so a result
  never depends on the hour or the weekday the suite runs. A test that
  needs the migration's real windows opts out with `@tag :real_schedule`.

  Versions are unique to the second on `effective_at`, so each helper
  stamps its insert one second after the latest existing version, and the
  default pin sits an hour back to leave room for them.
  """

  alias BearCub.LocalTime
  alias BearCub.Repo
  alias BearCub.Routines
  alias BearCub.Schedules
  alias BearCub.Schedules.{DayEntry, ScheduleVersion}

  @all_day {~T[00:00:00], ~T[23:59:59]}
  @never {~T[23:59:59], ~T[23:59:59]}

  @doc """
  Morning open all day, evening never, on every weekday, an hour back.
  Its insert is the test transaction's first statement, with R and E taken
  from version 0 as constants rather than read: SQLite refuses at once,
  without waiting, a transaction that reads and then tries to write while
  another connection holds the write lock.
  """
  def pin_default_schedule do
    insert_version(@all_day, @never, DateTime.add(DateTime.utc_now(), -1, :hour), 5, 2)
  end

  @doc """
  Inserts a version in force now with the given `{start, end}` windows on
  every weekday, copied from the current version otherwise (Night Owl
  bonus and cutoffs included). Goes through
  `Repo.insert!/1` on the struct, so a zero-length window the changeset
  would refuse is allowed. Does not broadcast.
  """
  def put_windows({_, _} = morning, {_, _} = evening) do
    current = Schedules.current()

    insert_version(
      morning,
      evening,
      next_instant(current),
      current.routine_bonus,
      current.early_bird_bonus,
      hd(current.days).early_bird_cutoff,
      current
    )
  end

  @doc """
  Inserts a version in force now with the early bird cutoff on every
  weekday, windows and bonuses copied from the current version. The
  cutoff may fall outside the morning window; a midnight cutoff makes
  nothing early, whatever the clock says.
  """
  def put_cutoff(%Time{} = cutoff) do
    current = Schedules.current()
    day = hd(current.days)

    insert_version(
      {day.morning_start, day.morning_end},
      {day.evening_start, day.evening_end},
      next_instant(current),
      current.routine_bonus,
      current.early_bird_bonus,
      cutoff,
      current
    )
  end

  @doc """
  Inserts a version in force now with new `R` and `E`, windows and cutoff
  copied from the current version, effective `at` (default: a second after
  the latest version, which is an hour back under the default pin) — a
  test staging an earned or failed routine-day *before* the raise passes
  an `at` after those instants. Does not broadcast.
  """
  def put_bonuses(r, e, at \\ nil) do
    current = Schedules.current()
    day = hd(current.days)

    insert_version(
      {day.morning_start, day.morning_end},
      {day.evening_start, day.evening_end},
      if(at, do: DateTime.shift_zone!(at, "Etc/UTC"), else: next_instant(current)),
      r,
      e,
      day.early_bird_cutoff,
      current
    )
  end

  defp next_instant(current), do: DateTime.add(current.effective_at, 1, :second)

  defp insert_version(
         {morning_start, morning_end},
         {evening_start, evening_end},
         at,
         r,
         e,
         cutoff \\ ~T[07:45:00],
         carry \\ nil
       ) do
    days =
      for weekday <- 1..7 do
        %DayEntry{
          weekday: weekday,
          morning_start: morning_start,
          morning_end: morning_end,
          evening_start: evening_start,
          evening_end: evening_end,
          early_bird_cutoff: cutoff,
          night_owl_cutoffs: carried_cutoffs(carry, weekday)
        }
      end

    Repo.insert!(%ScheduleVersion{
      effective_at: DateTime.truncate(at, :second),
      routine_bonus: r,
      early_bird_bonus: e,
      night_owl_bonus: if(carry, do: carry.night_owl_bonus, else: 0),
      days: days
    })
  end

  # Night Owl cutoffs and N ride along from the version being replaced, so
  # restaging windows or bonuses never quietly resets them.
  defp carried_cutoffs(nil, _weekday), do: []

  defp carried_cutoffs(carry, weekday) do
    case Enum.find(carry.days, &(&1.weekday == weekday)) do
      nil -> []
      day -> day.night_owl_cutoffs
    end
  end

  def morning_active, do: put_windows(@all_day, @never)
  def evening_active, do: put_windows(@never, @all_day)

  @doc "The `{state, routine}` the kiosk resolves at the real current time."
  def current_routine do
    now = LocalTime.now()
    Routines.current(now, Schedules.day_entry(now))
  end
end
