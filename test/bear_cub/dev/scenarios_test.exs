defmodule BearCub.Dev.ScenariosTest do
  use BearCub.DataCase, async: false

  alias BearCub.Chores
  alias BearCub.Dev.Scenarios
  alias BearCub.Routines
  alias BearCub.Schedules

  alias BearCub.LocalTime

  # The scenarios wrap `priv/repo/seeds.exs`, which stamps demo chores live
  # from the real local day (D86), so a staged day must be today: these
  # tests read the clock the way the LiveView tests do, not the unit layer.
  defp now, do: LocalTime.now()
  defp today, do: DateTime.to_date(now())

  setup do
    # the displaced-version stash is VM-wide; never carry one across tests
    :persistent_term.erase({Scenarios, :displaced})
    on_exit(fn -> :persistent_term.erase({Scenarios, :displaced}) end)
    Schedules.subscribe()
    :ok
  end

  defp entry_now do
    BearCub.Schedules.day_entry(now())
  end

  test "early_bird/1 seeds placeholders on an empty database and stages one early kid and one late kid" do
    assert Chores.list_kids() == []

    assert %{early: early, late: late} = Scenarios.early_bird(now())

    assert Chores.early_bird?(early, today())
    refute Chores.early_bird?(late, today())
    assert Chores.routine_day_status(late, "morning", today()).complete?
  end

  test "reset/1 clears the day's completions and leaves kids and chores alone" do
    Scenarios.early_bird(now())
    kids = Chores.list_kids()

    Scenarios.reset(now())

    assert Chores.list_kids() == kids
    assert Chores.current_completions(today()) == %{}
    assert Chores.list_chores(hd(kids), "morning") != []
  end

  test "open/1 forces a routine window open all day by writing a version in force now" do
    Scenarios.open(:morning)
    assert {:active, :morning} = Routines.current(now(), entry_now())
    assert_received :schedule_changed

    # a second call in the same second must still land in force
    Scenarios.open(:evening)
    assert {:active, :evening} = Routines.current(now(), entry_now())
    assert_received :schedule_changed
  end

  test "cutoff/1 writes a version with the early bird cutoff moved, other timings unchanged" do
    before = entry_now()
    Scenarios.cutoff(~T[23:00:00])

    assert entry_now().early_bird_cutoff == ~T[23:00:00]
    assert entry_now().morning_start == before.morning_start
    assert entry_now().evening_end == before.evening_end
    assert_received :schedule_changed
  end

  describe "night_owl/1" do
    setup do
      Scenarios.early_bird(now())
      %{kids: Chores.list_kids()}
    end

    defp cutoffs_today(kids) do
      weekday = Date.day_of_week(today())
      day = Enum.find(Schedules.current().days, &(&1.weekday == weekday))
      for kid <- kids, do: Enum.find(day.night_owl_cutoffs, &(&1.kid_id == kid.id))
    end

    test "sets N and gives every kid a cutoff after now for today's weekday", %{kids: kids} do
      Scenarios.night_owl(4)

      assert Schedules.current().night_owl_bonus == 4
      cutoffs = cutoffs_today(kids)
      assert Enum.all?(cutoffs, & &1)

      assert Enum.all?(
               cutoffs,
               &(Time.compare(&1.cutoff, LocalTime.now() |> DateTime.to_time()) == :gt)
             )

      assert_received :schedule_changed
    end

    test "defaults N to 3 when the current N is 0" do
      Scenarios.night_owl()
      assert Schedules.current().night_owl_bonus == 3
    end

    test "survives open(:evening) written after it, and restore/0 undoes it", %{kids: kids} do
      Scenarios.night_owl(4)
      Scenarios.open(:evening)

      assert Schedules.current().night_owl_bonus == 4
      assert Enum.all?(cutoffs_today(kids), & &1)

      Scenarios.restore()

      assert Schedules.current().night_owl_bonus == 0
      assert Enum.all?(cutoffs_today(kids), &is_nil/1)
    end
  end

  describe "countdown/2" do
    setup do
      Scenarios.early_bird(now())
      %{kids: Chores.list_kids()}
    end

    defp minutes_ahead(time), do: Time.diff(time, DateTime.to_time(now()), :second) / 60

    defp evening_cutoff(kid) do
      Enum.find(entry_now().night_owl_cutoffs, &(&1.kid_id == kid.id))
    end

    test "morning moves the shared early bird cutoff to minutes from now" do
      Scenarios.countdown(:morning, 10)

      assert_in_delta minutes_ahead(entry_now().early_bird_cutoff), 10, 0.1
      assert_received :schedule_changed
    end

    test "evening with minutes gives every kid a cutoff, including one who had none", %{
      kids: [a, b]
    } do
      Scenarios.countdown(:evening, 20)
      assert_in_delta minutes_ahead(evening_cutoff(a).cutoff), 20, 0.1
      assert_in_delta minutes_ahead(evening_cutoff(b).cutoff), 20, 0.1
      assert Schedules.current().night_owl_bonus == 3
      assert_received :schedule_changed
    end

    test "evening with a per-kid list is the complete picture", %{kids: [a, b]} do
      Scenarios.countdown(:evening, 20)
      Scenarios.countdown(:evening, [{a.id, 5}])

      assert_in_delta minutes_ahead(evening_cutoff(a).cutoff), 5, 0.1
      assert evening_cutoff(b) == nil
    end

    test "restore/0 undoes it", %{kids: [a, _]} do
      original = entry_now().early_bird_cutoff
      Scenarios.countdown(:morning, 10)
      Scenarios.countdown(:evening, 20)
      Scenarios.restore()

      assert entry_now().early_bird_cutoff == original
      assert evening_cutoff(a) == nil
      assert Schedules.current().night_owl_bonus == 0
    end
  end

  test "restore/0 brings back the schedule in force before the first scenario write" do
    original = entry_now()

    Scenarios.open(:evening)
    Scenarios.cutoff(~T[23:00:00])
    Scenarios.restore()

    restored = entry_now()
    assert restored.morning_start == original.morning_start
    assert restored.evening_end == original.evening_end
    assert restored.early_bird_cutoff == original.early_bird_cutoff
    assert :persistent_term.get({Scenarios, :displaced}, nil) == nil
    assert_received :schedule_changed
  end

  test "slow_weekend/0 writes a valid version whose Saturday and Sunday differ from the weekdays" do
    Scenarios.slow_weekend()

    versions = Schedules.versions()
    current = List.last(versions)
    day = fn weekday -> Enum.find(current.days, &(&1.weekday == weekday)) end

    assert length(versions) == 2
    assert day.(6).morning_start == ~T[08:00:00]
    assert day.(7).early_bird_cutoff == ~T[09:30:00]
    assert day.(1) == Enum.find(hd(versions).days, &(&1.weekday == 1))

    # valid, so the Schedule page can save it untouched
    assert {:ok, _} =
             current
             |> Map.take([:routine_bonus, :early_bird_bonus])
             |> Map.put(:days, Enum.map(current.days, &Map.from_struct/1))
             |> Schedules.change_version()
             |> Ecto.Changeset.apply_action(:validate)

    assert_received :schedule_changed
  end

  test "restore/0 undoes slow_weekend/0" do
    original = Schedules.current()

    Scenarios.slow_weekend()
    Scenarios.restore()

    assert Enum.sort_by(Schedules.current().days, & &1.weekday) ==
             Enum.sort_by(original.days, & &1.weekday)
  end

  describe "weather" do
    alias BearCub.Weather
    alias BearCub.Weather.Reading

    setup do
      Weather.reset()
      Weather.subscribe()
      on_exit(&Weather.reset/0)
    end

    test "weather/1 holds today's reading and broadcasts" do
      Scenarios.weather({:cold, :snow})

      assert %Reading{temp: :cold, precip: :snow} = Weather.current(today())
      assert_received :weather_changed
    end

    test "weather(nil) clears the reading and broadcasts" do
      Scenarios.weather({:hot, :none})
      flush_mailbox()

      Scenarios.weather(nil)

      assert Weather.current(today()) == nil
      assert_received :weather_changed
    end

    test "weather_chore/0 flags each kid's first morning chore" do
      [kid_a, kid_b | _] = Scenarios.reset(now())

      assert [_ | _] = flagged = Scenarios.weather_chore()

      for kid <- [kid_a, kid_b] do
        [first | rest] = Chores.list_chores(kid, "morning")
        assert first.shows_weather
        refute Enum.any?(rest, & &1.shows_weather)
        assert first.id in Enum.map(flagged, & &1.id)
      end
    end

    test "weather_chore/1 flags the named chore" do
      [kid | _] = Scenarios.reset(now())
      [_first, second | _] = Chores.list_chores(kid, "morning")

      Scenarios.weather_chore(second.name)

      assert Chores.get_chore!(second.id).shows_weather
    end
  end

  describe "record/2" do
    import BearCub.ScheduleHelpers, only: [morning_active: 0]

    alias BearCub.Points
    alias BearCub.Streaks

    setup do
      morning_active()
      :ok
    end

    # {current, longest} of the first two kids after staging `state`
    defp staged(state) do
      [one, two | _] = Scenarios.record(state, now())
      standing = Streaks.by_kid(now(), entry_now())
      {one, two, standing}
    end

    defp pair(standing, kid), do: {standing[kid.id].current, standing[kid.id].longest}

    defp first_completion(kid) do
      import Ecto.Query

      BearCub.Repo.one(
        from c in BearCub.Chores.Completion,
          join: ch in BearCub.Chores.Chore,
          on: ch.id == c.chore_id,
          where: ch.kid_id == ^kid.id,
          select: min(c.local_date)
      )
    end

    defp span_days(kid), do: Date.diff(today(), first_completion(kid))

    test ":a stages 12 / 19 and 3 / 3 with history over eight months" do
      {one, two, standing} = staged(:a)

      assert pair(standing, one) == {12, 19}
      assert pair(standing, two) == {3, 3}
      assert standing[one.id].today == :pending
      assert span_days(one) >= 245
      assert span_days(two) >= 245
    end

    test ":b leaves last night's evening undone: 0 / 19 and 6 / 9" do
      {one, two, standing} = staged(:b)

      assert pair(standing, one) == {0, 19}
      assert standing[one.id].today == :failed
      assert pair(standing, two) == {6, 9}
      assert span_days(one) >= 245
      assert span_days(two) >= 245
    end

    test ":c gives kid 2 a first completion in the previous calendar month" do
      {one, two, standing} = staged(:c)

      assert pair(standing, one) == {12, 19}
      assert pair(standing, two) == {4, 4}

      assert Date.beginning_of_month(first_completion(two)) ==
               Date.beginning_of_month(Date.add(Date.beginning_of_month(today()), -1))

      assert [_, _] = Points.earned_history(today())[two.id].months
    end

    test ":d stages three-digit streaks and four-digit lifetime totals" do
      {one, two, standing} = staged(:d)

      assert pair(standing, one) == {112, 118}
      assert pair(standing, two) == {104, 104}
      assert span_days(one) >= 245
      assert span_days(two) >= 245

      history = Points.earned_history(today())
      assert history[one.id].lifetime >= 1000
      assert history[two.id].lifetime >= 1000
    end

    test ":e stages kid 1 as :a and kid 2 as brand new" do
      {one, two, standing} = staged(:e)

      assert pair(standing, one) == {12, 19}
      assert pair(standing, two) == {0, 0}
      assert first_completion(two) == nil

      assert %{lifetime: 0, months: [{month, 0}]} = Points.earned_history(today())[two.id]
      assert month == Date.beginning_of_month(today())
    end

    test "replaces the two kids' past completions and leaves today's alone" do
      Scenarios.early_bird(now())
      today_before = Chores.current_completions(today())

      [one, _two | _] = Scenarios.record(:a, now())
      Scenarios.record(:d, now())
      Scenarios.record(:a, now())

      assert Chores.current_completions(today()) == today_before
      # early_bird/1 finished kid 1's morning today, so today extends the run
      assert pair(Streaks.by_kid(now(), entry_now()), one) == {13, 19}
    end

    test "touches only the first two kids by id" do
      [_, _ | _] = kids = Scenarios.reset(now())
      {:ok, third} = Chores.create_kid(%{name: "Third", color: "#336699", position: length(kids)})

      {:ok, chore} =
        Chores.create_chore(
          third,
          %{name: "Third chore", icon: "🧹", routine: "morning", points: 1},
          now()
        )

      date = Date.add(today(), -3)
      at = DateTime.new!(date, ~T[07:00:00], now().time_zone)
      {:ok, _} = Chores.complete_chore(chore, at, "kiosk")

      Scenarios.record(:a, now())

      assert first_completion(third) == date
    end
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end
end
