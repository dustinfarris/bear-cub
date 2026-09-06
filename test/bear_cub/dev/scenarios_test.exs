defmodule BearCub.Dev.ScenariosTest do
  use BearCub.DataCase, async: false

  alias BearCub.Chores
  alias BearCub.Dev.Scenarios

  alias BearCub.LocalTime

  @tz "America/Los_Angeles"
  defp la(date, time), do: DateTime.new!(date, time, @tz)

  # The scenarios wrap `priv/repo/seeds.exs`, which stamps demo chores live
  # from the real local day (D86), so a staged day must be today: these
  # tests read the clock the way the LiveView tests do, not the unit layer.
  defp now, do: LocalTime.now()
  defp today, do: DateTime.to_date(now())

  setup do
    original = Application.fetch_env!(:bear_cub, :routine_windows)
    on_exit(fn -> Application.put_env(:bear_cub, :routine_windows, original) end)
    :ok
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

  test "open/1 forces a routine window open all day in the running VM" do
    Scenarios.open(:morning)
    assert {:active, :morning} = BearCub.Routines.current(la(~D[2026-07-10], ~T[22:00:00]))

    Scenarios.open(:evening)
    assert {:active, :evening} = BearCub.Routines.current(la(~D[2026-07-10], ~T[06:00:00]))
  end
end
