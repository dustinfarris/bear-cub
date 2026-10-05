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
end
