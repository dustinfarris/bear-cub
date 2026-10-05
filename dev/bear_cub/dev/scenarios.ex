defmodule BearCub.Dev.Scenarios do
  @moduledoc """
  Named kiosk states for local review — the gate mechanism (CLAUDE.md,
  Workflow): a batch is judged in Chrome against the dev server at the
  tablet's CSS viewport, staged here, before anything is deployed. The
  deployed Fully Kiosk WebView is verified afterwards against the
  Android-only checklist, never used as the first look.

  Compiled in dev and test only (`elixirc_paths/1` in `mix.exs`) — this
  module does not exist in the release, which is what makes `reset/1`'s
  row deletion acceptable: it is a sandbox wipe, not domain behavior
  (completion rows are never deleted in the domain, D10).

  Every scenario runs inside the server's own VM so its broadcasts
  re-render open kiosks. `open/1` and `cutoff/1` stage by writing a real
  schedule version in force now (D126) and broadcasting `:schedule_changed`,
  so they reach an open kiosk like a parent's save; `restore/0` puts the
  schedule from before the first scenario write back. Use it from
  `iex -S mix phx.server`, or from Tidewave's `project_eval`:

      BearCub.Dev.Scenarios.early_bird()
      BearCub.Dev.Scenarios.midway()         # stake bar half filled, done rows sunk
      BearCub.Dev.Scenarios.effort()         # a counted extra ready to tap, another done at x8
      BearCub.Dev.Scenarios.open(:morning)   # review a morning state at night
      BearCub.Dev.Scenarios.cutoff(~T[23:00:00])   # taps made now count as early
      BearCub.Dev.Scenarios.slow_weekend()   # /admin/schedule with a "custom" weekend
      BearCub.Dev.Scenarios.restore()        # the schedule from before open/cutoff/slow_weekend
      BearCub.Dev.Scenarios.reset()

  Placeholder kids and demo chores are seeded first if the database is
  empty, exactly as `priv/repo/seeds.exs` does; existing rows are never
  modified. Every scenario takes a local datetime and defaults to now —
  the one place outside the web layer that reads the clock, and it is a
  dev edge (D86).
  """

  import Ecto.Query

  alias BearCub.Chores
  alias BearCub.Chores.Completion
  alias BearCub.LocalTime
  alias BearCub.Repo
  alias BearCub.Schedules
  alias BearCub.Schedules.ScheduleVersion

  @stash {__MODULE__, :displaced}

  @doc """
  One kid finished the whole morning early (07:10), the other late
  (08:30): the sun with a `+R` badge on the late kid, the sun with a
  combined `+R+E` badge and the EARLY pill on the early kid (D100, D104).
  Returns `%{early: kid, late: kid}`.
  """
  def early_bird(%DateTime{} = local_now \\ LocalTime.now()) do
    [early, late | _] = reset(local_now)
    today = DateTime.to_date(local_now)
    tz = local_now.time_zone

    for {kid, time} <- [{early, ~T[07:10:00]}, {late, ~T[08:30:00]}],
        chore <- Chores.list_chores(kid, "morning") do
      {:ok, _} = Chores.complete_chore(chore, DateTime.new!(today, time, tz), "kiosk")
    end

    %{early: early, late: late}
  end

  @doc """
  The stake bar mid-fill (D105): one kid has finished the first two chores
  of `routine`, the other the first one, each tapped a minute apart so the
  sunk done rows stack newest-first beneath the dashed slots. Pair it with
  `open(routine)` when reviewing outside the window. Returns the kids in
  display order.
  """
  def midway(routine \\ :morning, %DateTime{} = local_now \\ LocalTime.now())
      when routine in [:morning, :evening] do
    kids = reset(local_now)

    for {kid, count} <- Enum.zip(kids, Stream.cycle([2, 1])),
        {chore, offset} <-
          kid
          |> Chores.list_chores(Atom.to_string(routine))
          |> Enum.take(count)
          |> Enum.with_index() do
      at = DateTime.add(local_now, offset - count, :minute)
      {:ok, _} = Chores.complete_chore(chore, at, "kiosk")
    end

    kids
  end

  @doc """
  Both kids' mornings are otherwise done (band showing, extras revealed),
  each holding one counted extra: `pending`'s is untouched, ready to tap
  open in the browser — the panel itself is ephemeral kiosk state (Story
  04, `counting`) and cannot be staged server-side, only its data can;
  `done`'s is already completed at `x8`. Returns `%{pending: kid, done:
  kid}`.
  """
  def effort(%DateTime{} = local_now \\ LocalTime.now()) do
    [pending, done | _] = reset(local_now)

    for kid <- [pending, done],
        chore <- Chores.list_chores(kid, "morning") do
      {:ok, _} = Chores.complete_chore(chore, local_now, "kiosk")
    end

    counted_attrs = %{
      name: "Chess Puzzle",
      icon: "♟️",
      routine: nil,
      points: 2,
      unit_rate: 1,
      unit_max: 20
    }

    {:ok, _} = Chores.create_chore(pending, counted_attrs, local_now)
    {:ok, done_chore} = Chores.create_chore(done, counted_attrs, local_now)
    {:ok, _} = Chores.complete_chore(done_chore, local_now, "kiosk", 8)

    %{pending: pending, done: done}
  end

  @doc """
  Wipes the local day's completions for every kid, seeding placeholders
  first when the database is empty. Kids, chores, rewards and past days
  are untouched. Returns the kids in display order.
  """
  def reset(%DateTime{} = local_now \\ LocalTime.now()) do
    seed_if_empty()
    today = DateTime.to_date(local_now)
    Repo.delete_all(from c in Completion, where: c.local_date == ^today)
    broadcast()
    Chores.list_kids()
  end

  @doc """
  Forces `routine` active all day, so a morning state can be reviewed in
  the evening and vice versa. Writes a version in force now, copied from
  the current one with only the windows changed; the other routine gets a
  zero-length window, which the changeset refuses, hence `Repo.insert!/1`
  on the struct. `restore/0` undoes it.
  """
  def open(routine) when routine in [:morning, :evening] do
    all_day = {~T[00:00:00], ~T[23:59:59]}
    never = {~T[23:59:59], ~T[23:59:59]}

    write_version(fn day ->
      {morning, evening} = if routine == :morning, do: {all_day, never}, else: {never, all_day}
      {morning_start, morning_end} = morning
      {evening_start, evening_end} = evening

      %{
        day
        | morning_start: morning_start,
          morning_end: morning_end,
          evening_start: evening_start,
          evening_end: evening_end
      }
    end)
  end

  @doc """
  Moves the early bird cutoff, so a chore tapped *now* can count as early
  (`cutoff(~T[23:00:00])`) or late (`cutoff(~T[00:01:00])`) in a live
  tap-through. Writes a version like `open/1`, with no window check — pair
  it with `open(:morning)`. `restore/0` brings the real cutoff back.
  """
  def cutoff(%Time{} = time) do
    write_version(&%{&1 | early_bird_cutoff: time})
  end

  @doc """
  The evening mirror of `cutoff/1`: writes a version in force now with the
  Night Owl bonus `n` (default: the current N, or 3 when that is 0) and
  every kid's cutoff for today's weekday two hours after now, capped at
  23:59:59, so a live evening tap counts as a Night Owl. Pair it with
  `open(:evening)`; `restore/0` brings the real schedule back.
  """
  def night_owl(n \\ nil) do
    now = LocalTime.now()
    weekday = Date.day_of_week(DateTime.to_date(now))
    current = Schedules.current()
    n = n || if(current.night_owl_bonus > 0, do: current.night_owl_bonus, else: 3)

    cutoff =
      if DateTime.to_date(DateTime.add(now, 2, :hour)) == DateTime.to_date(now),
        do: now |> DateTime.add(2, :hour) |> DateTime.to_time() |> Time.truncate(:second),
        else: ~T[23:59:59]

    entries =
      for kid <- Chores.list_kids(),
          do: %BearCub.Schedules.NightOwlCutoff{kid_id: kid.id, cutoff: cutoff}

    write_version(
      fn
        %{weekday: ^weekday} = day -> %{day | night_owl_cutoffs: entries}
        day -> day
      end,
      night_owl_bonus: n
    )
  end

  @doc """
  A valid schedule in force now whose Saturday and Sunday start the
  morning at 08:00 with a 09:30 early bird cutoff, the weekdays untouched
  — so `/admin/schedule` loads with the quiet "custom" marker on the two
  weekend cards. Unlike `open/1` it passes the changeset, so the page
  can save it as is. `restore/0` undoes it.
  """
  def slow_weekend do
    write_version(fn
      %{weekday: weekday} = day when weekday in [6, 7] ->
        %{day | morning_start: ~T[08:00:00], early_bird_cutoff: ~T[09:30:00]}

      day ->
        day
    end)
  end

  @doc """
  Inserts a copy of the schedule that the first scenario write displaced,
  in force now, and forgets it. A no-op without a stash.
  """
  def restore do
    case :persistent_term.get(@stash, nil) do
      nil ->
        :ok

      id ->
        :persistent_term.erase(@stash)
        write_copy(Repo.get!(ScheduleVersion, id), & &1)
    end
  end

  # A copy of the version in force with `fun` applied to each day entry,
  # effective now. The first write of a VM stashes the id of the version it
  # displaced; later scenario writes leave the stash alone, so `restore/0`
  # always reaches back to the real schedule. No column marks scenario rows.
  defp write_version(fun, overrides \\ []) do
    current = Schedules.current()
    if :persistent_term.get(@stash, nil) == nil, do: :persistent_term.put(@stash, current.id)
    write_copy(current, fun, overrides)
  end

  defp write_copy(%ScheduleVersion{} = source, fun, overrides \\ []) do
    at = wait_for_free_second()

    Repo.insert!(%ScheduleVersion{
      effective_at: at,
      routine_bonus: source.routine_bonus,
      early_bird_bonus: source.early_bird_bonus,
      night_owl_bonus: Keyword.get(overrides, :night_owl_bonus, source.night_owl_bonus),
      days: Enum.map(source.days, fun)
    })

    # Repo.insert! bypasses Schedules.change/1, which would broadcast
    Phoenix.PubSub.broadcast(BearCub.PubSub, "schedules", :schedule_changed)
    :ok
  end

  # `effective_at` is unique to the second: a scenario written in the same
  # second as the newest version waits out the rest of it, so the new
  # version is in force the moment it lands. A dev edge, like the clock.
  defp wait_for_free_second do
    latest = Schedules.current().effective_at
    now = DateTime.truncate(DateTime.utc_now(), :second)

    if DateTime.compare(now, latest) == :gt do
      now
    else
      Process.sleep(1_000)
      wait_for_free_second()
    end
  end

  # The same `:chores_changed` message `Chores` broadcasts after a write,
  # on the same topic, so every open kiosk and admin view re-renders. A
  # direct broadcast rather than a new public `Chores` function: the
  # domain gains nothing it needs for a dev-only consumer.
  defp broadcast, do: Phoenix.PubSub.broadcast(BearCub.PubSub, "chores", :chores_changed)

  defp seed_if_empty do
    if Chores.list_kids() == [] do
      Code.eval_file(Path.join(:code.priv_dir(:bear_cub), "repo/seeds.exs"))
    end
  end
end
