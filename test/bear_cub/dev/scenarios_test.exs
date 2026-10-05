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
end
