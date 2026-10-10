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
      BearCub.Dev.Scenarios.weather_chore()  # flag each kid's first morning chore
      BearCub.Dev.Scenarios.weather({:cold, :snow})   # any of nine readings; nil for none
      BearCub.Dev.Scenarios.record(:a)       # record screen: :a normal, :b reset, :c two months, :d big, :e empty
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
  alias BearCub.Chores.{Chore, Completion, Kid}
  alias BearCub.LocalTime
  alias BearCub.Repo
  alias BearCub.Schedules
  alias BearCub.Schedules.ScheduleVersion
  alias BearCub.Weather
  alias BearCub.Weather.Reading

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

  # Per state, per kid (first two by id): the streak runs newest first, as
  # `{current, longest, span_days}`; each run is followed by one missed
  # morning. Filler runs, never longer than `longest`, stretch the history
  # to `span_days`. `:b` additionally leaves kid 1's last evening undone.
  @record_states %{
    a: [{12, 19, 250}, {3, 3, 250}],
    b: [{12, 19, 250}, {6, 9, 250}],
    c: [{12, 19, 250}, {4, 4, 0}],
    d: [{112, 118, 250}, {104, 104, 250}],
    e: [{12, 19, 250}, nil]
  }

  @doc """
  Stages the kiosk's record screen (streaks, longest, lifetime points and
  the monthly chart) in one of five states by replacing the first two
  kids' completions dated before today with seeded history; today's
  completions are left alone. With `open(:morning)` and no completion
  today (`reset/1`) the two kids show:

    * `:a` — 12 / 19 and 3 / 3 (current / longest): normal, kid 2 on a
      best-ever streak
    * `:b` — 0 / 19 (last night's evening undone, so today is failed) and
      6 / 9: the reset state
    * `:c` — 12 / 19 and 4 / 4 whose first completion falls in the
      previous calendar month: the two-month chart
    * `:d` — 112 / 118 and 104 / 104: three-digit streaks, four-digit totals
    * `:e` — 12 / 19 and a brand-new kid with no completions: the empty state

  Runs are separated by single missed mornings, and history spans over
  eight months except in `:c` (kid 2) and `:e` (kid 2). Seeded days are
  judged against the roster in force: the kids' live routine chores are
  backdated to the oldest seeded day and each day gets a completion for
  every routine chore live on it. Destroys the dev database's real past
  completions for those two kids. Returns the kids in id order.
  """
  def record(state, %DateTime{} = local_now \\ LocalTime.now())
      when state in [:a, :b, :c, :d, :e] do
    seed_if_empty()
    today = DateTime.to_date(local_now)
    kids = Repo.all(from k in Kid, order_by: k.id, limit: 2)

    for {kid, spec} <- Enum.zip(kids, Map.fetch!(@record_states, state)) do
      Repo.delete_all(
        from c in Completion,
          where:
            c.local_date < ^today and
              c.chore_id in subquery(from ch in Chore, where: ch.kid_id == ^kid.id, select: ch.id)
      )

      if spec, do: seed_history(kid, spec, state == :b and kid == hd(kids), today, local_now)
    end

    broadcast()
    kids
  end

  defp seed_history(kid, {current, longest, span}, evening_undone?, today, local_now) do
    {mornings, oldest} = standing_days(current, longest, span, today)
    # kid 2 of `:c` has no span: one lone morning chore last month, unless
    # the short run already reaches back that far
    lone = if span == 0, do: lone_date(today, oldest)
    first = Enum.min([oldest | List.wrap(lone)], Date) |> Date.add(-1)

    # the evening before a standing day is done on every day from `first`
    # to yesterday, the missed days included
    evenings =
      Date.range(first, Date.add(today, -1))
      |> Enum.reject(&(evening_undone? and &1 == Date.add(today, -1)))

    chores = backdate_roster(kid, first)

    rows =
      for {routine, days} <- [{"morning", mornings}, {"evening", evenings}],
          day <- days,
          chore <- chores,
          chore.routine == routine,
          live_on?(chore, day),
          do: completion_row(chore, day, routine, local_now)

    lone_rows =
      for day <- List.wrap(lone),
          chore <- Enum.take(Enum.filter(chores, &(&1.routine == "morning" and live_on?(&1, day))), 1),
          do: completion_row(chore, day, "morning", local_now)

    now = DateTime.truncate(DateTime.utc_now(), :second)

    for chunk <- Enum.chunk_every(rows ++ lone_rows, 500) do
      Repo.insert_all(Completion, Enum.map(chunk, &Map.merge(&1, %{inserted_at: now, updated_at: now})))
    end
  end

  # Standing days newest first by run, with one missed day between runs:
  # `current` ending yesterday, then `longest` (when different), then
  # filler runs up to `span` days back. Returns the days and the oldest.
  defp standing_days(current, longest, span, today) do
    base = if current == longest, do: [current], else: [current, longest]
    filler = Stream.cycle([longest - 4, longest - 9, longest - 1, longest - 6])
    lengths = take_runs(base, Stream.map(filler, &max(&1, 1)), span, 0, [])

    {days, _edge} =
      Enum.reduce(lengths, {[], Date.add(today, -1)}, fn len, {days, edge} ->
        run = Date.range(edge, Date.add(edge, -(len - 1)), -1)
        {Enum.to_list(run) ++ days, Date.add(edge, -len - 1)}
      end)

    {days, Enum.min(days, Date)}
  end

  # Runs (newest first): `base`, then filler until the history reaches
  # `span` days, each run costing its length plus the missed day after it.
  defp take_runs([len | base], filler, span, total, acc),
    do: take_runs(base, filler, span, total + len + 1, [len | acc])

  defp take_runs([], filler, span, total, acc) do
    if total >= span do
      Enum.reverse(acc)
    else
      [len] = Enum.take(filler, 1)
      take_runs([], Stream.drop(filler, 1), span, total + len + 1, [len | acc])
    end
  end

  defp lone_date(today, oldest) do
    date = today |> Date.beginning_of_month() |> Date.add(-1)
    if Date.compare(date, Date.add(oldest, -1)) == :lt, do: date
  end

  # The kid's routine chores, live ones backdated so history before the
  # seed date is judged against a roster that had them.
  defp backdate_roster(kid, first) do
    chores =
      Repo.all(from c in Chore, where: c.kid_id == ^kid.id and not is_nil(c.routine))

    for chore <- chores do
      if is_nil(chore.archived_on) and Date.compare(chore.active_from, first) == :gt do
        Repo.update_all(from(c in Chore, where: c.id == ^chore.id), set: [active_from: first])
        %{chore | active_from: first}
      else
        chore
      end
    end
  end

  defp live_on?(chore, day) do
    Date.compare(chore.active_from, day) != :gt and
      (is_nil(chore.archived_on) or Date.compare(chore.archived_on, day) == :gt)
  end

  defp completion_row(chore, day, routine, local_now) do
    time = if routine == "morning", do: ~T[07:30:00], else: ~T[19:30:00]
    at = day |> DateTime.new!(time, local_now.time_zone) |> DateTime.shift_zone!("Etc/UTC")

    %{chore_id: chore.id, local_date: day, completed_at: at, source: "kiosk"}
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
  Stages a bonus cutoff `minutes` from now, for reviewing the countdown.
  Writes a version in force now; pair it with `open/1`, which is what keeps
  a near cutoff inside its routine's window. `restore/0` undoes it.

    * `countdown(:morning, minutes)` moves the shared early bird cutoff.
    * `countdown(:evening, minutes)` gives every kid a Sleepy Bear cutoff
      for today's weekday, including a kid who had none.
    * `countdown(:evening, [{kid_id, minutes}, ...])` is the whole evening
      picture: each listed kid gets their own cutoff and an unlisted kid's
      cutoff for today is removed, so a kid with no evening bonus is staged
      in the same call.

  The evening forms set the Night Owl bonus like `night_owl/1` does (the
  current N, or 3 when that is 0). The cutoff is `now + minutes` truncated
  to the second, capped at 23:59:59, so it can land up to a second early.
  """
  def countdown(:morning, minutes) when is_integer(minutes) do
    cutoff(cutoff_in(minutes))
  end

  def countdown(:evening, minutes) when is_integer(minutes) do
    countdown(:evening, for(kid <- Chores.list_kids(), do: {kid.id, minutes}))
  end

  def countdown(:evening, per_kid) when is_list(per_kid) do
    weekday = Date.day_of_week(DateTime.to_date(LocalTime.now()))
    current = Schedules.current()
    n = if current.night_owl_bonus > 0, do: current.night_owl_bonus, else: 3

    entries =
      for {kid_id, minutes} <- per_kid,
          do: %BearCub.Schedules.NightOwlCutoff{kid_id: kid_id, cutoff: cutoff_in(minutes)}

    write_version(
      fn
        %{weekday: ^weekday} = day -> %{day | night_owl_cutoffs: entries}
        day -> day
      end,
      night_owl_bonus: n
    )
  end

  # `minutes` after the real now as a `Time`, held at 23:59:59 when that
  # would cross midnight.
  defp cutoff_in(minutes) do
    now = LocalTime.now()
    later = DateTime.add(now, minutes * 60, :second)

    if DateTime.to_date(later) == DateTime.to_date(now),
      do: later |> DateTime.to_time() |> Time.truncate(:second),
      else: ~T[23:59:59]
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
  Puts today's weather reading `{temp, precip}` straight into the store and
  broadcasts `:weather_changed`, so an open kiosk shows it with no network:
  temp is `:hot | :normal | :cold`, precip `:none | :rain | :snow`. `nil`
  clears the reading (the absent state). The Refresher overwrites a staged
  reading on its next tick when coordinates are configured; re-run this.
  Pair it with `open(:morning)` and `weather_chore/0`.
  """
  def weather(nil) do
    Weather.reset()
    Phoenix.PubSub.broadcast(BearCub.PubSub, "weather", :weather_changed)
  end

  def weather({temp, precip})
      when temp in [:hot, :normal, :cold] and precip in [:none, :rain, :snow] do
    Weather.put(%Reading{date: DateTime.to_date(LocalTime.now()), temp: temp, precip: precip})
  end

  @doc """
  Flags morning chores `shows_weather`: with no argument each kid's first
  by position, or every morning chore called `name`. Returns the flagged
  chores. Goes through `Chores.update_chore/2`, so it broadcasts.
  """
  def weather_chore(name \\ nil) do
    seed_if_empty()

    chores =
      if name do
        for kid <- Chores.list_kids(),
            chore <- Chores.list_chores(kid, "morning"),
            chore.name == name,
            do: chore
      else
        for kid <- Chores.list_kids(),
            [first | _] <- [Chores.list_chores(kid, "morning")],
            do: first
      end

    for chore <- chores do
      {:ok, chore} = Chores.update_chore(chore, %{shows_weather: true})
      chore
    end
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
