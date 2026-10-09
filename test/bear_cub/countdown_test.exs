defmodule BearCub.CountdownTest do
  use ExUnit.Case, async: true

  alias BearCub.Countdown

  @lead :timer.minutes(30)
  @switch :timer.minutes(5)
  @cutoff DateTime.new!(~D[2026-10-08], ~T[07:30:00], "America/Los_Angeles")

  # A local_now `ms` before the cutoff.
  defp before_cutoff(ms), do: DateTime.add(@cutoff, -ms, :millisecond)

  defp state(ms, eligible? \\ true),
    do: Countdown.state(@cutoff, eligible?, before_cutoff(ms), @lead, @switch)

  defp edge(ms), do: Countdown.next_edge(@cutoff, before_cutoff(ms), @lead, @switch)

  # Milliseconds before the cutoff that an edge instant sits at.
  defp edge_ms(nil), do: nil
  defp edge_ms(at), do: DateTime.diff(@cutoff, at, :millisecond)

  describe "state/5 — no countdown" do
    test "nil when the kid is not eligible" do
      assert state(:timer.minutes(10), false) == nil
    end

    test "nil when there is no cutoff" do
      assert Countdown.state(nil, true, @cutoff, @lead, @switch) == nil
    end

    test "nil when more than the lead remains" do
      assert state(@lead + 1) == nil
    end

    test "nil exactly at the cutoff and after it" do
      assert state(0) == nil
      assert state(-1) == nil
      assert state(-:timer.hours(1)) == nil
    end
  end

  describe "state/5 — mode" do
    test "minutes at exactly the lead and at the switch plus one second" do
      assert %{mode: :minutes, remaining_ms: @lead} = state(@lead)
      assert %{mode: :minutes} = state(@switch + 1000)
      assert %{mode: :minutes} = state(@switch + 1)
    end

    test "seconds at exactly the switch and at one millisecond" do
      assert %{mode: :seconds, remaining_ms: @switch} = state(@switch)
      assert %{mode: :seconds, remaining_ms: 1} = state(1)
    end
  end

  describe "state/5 — fraction" do
    test "minutes mode drains over the lead" do
      assert state(@lead).fraction == 1.0
      assert state(div(@lead, 2)).fraction == 0.5
      assert state(@switch + 1).fraction == (@switch + 1) / @lead
    end

    test "seconds mode refills at the switch and drains over the switch" do
      assert state(@switch).fraction == 1.0
      assert state(div(@switch, 2)).fraction == 0.5
      assert state(1).fraction == 1 / @switch
    end
  end

  describe "display/1" do
    test "minutes mode is whole minutes from the lead down to the switch" do
      assert Countdown.display(state(@lead)) == "30"
      assert Countdown.display(state(@lead - 1)) == "29"
      assert Countdown.display(state(:timer.minutes(6))) == "6"
      assert Countdown.display(state(@switch + 1000)) == "5"
      assert Countdown.display(state(@switch + 1)) == "5"
    end

    test "minutes mode is never 0" do
      for ms <- [@switch + 1, @switch + 999, @switch + 60_000] do
        refute Countdown.display(state(ms)) == "0"
      end
    end

    test "seconds mode is m:ss from 5:00 down to 0:01" do
      assert Countdown.display(state(@switch)) == "5:00"
      assert Countdown.display(state(@switch - 1)) == "5:00"
      assert Countdown.display(state(@switch - 1000)) == "4:59"
      assert Countdown.display(state(61_000)) == "1:01"
      assert Countdown.display(state(60_000)) == "1:00"
      assert Countdown.display(state(1001)) == "0:02"
      assert Countdown.display(state(1000)) == "0:01"
      assert Countdown.display(state(1)) == "0:01"
    end

    test "there is no state to show as 0:00 — it is nil" do
      assert state(0) == nil
    end
  end

  describe "next_edge/4" do
    test "nil with no cutoff, at the cutoff, and after it" do
      assert Countdown.next_edge(nil, @cutoff, @lead, @switch) == nil
      assert edge(0) == nil
      assert edge(-1) == nil
    end

    test "before the lead, the next edge is the appearance" do
      assert edge_ms(edge(@lead + 1)) == @lead
      assert edge_ms(edge(:timer.hours(2))) == @lead
    end

    test "at the lead, the next edge is the next whole minute" do
      assert edge_ms(edge(@lead)) == @lead - 60_000
    end

    test "in minutes mode, the edge is the next whole minute back from the cutoff" do
      assert edge_ms(edge(:timer.minutes(20) - 1)) == :timer.minutes(19)
      assert edge_ms(edge(:timer.minutes(20))) == :timer.minutes(19)
      assert edge_ms(edge(:timer.minutes(20) + 1)) == :timer.minutes(20)
    end

    test "just above the switch, the edge is the switch and never skips it" do
      assert edge_ms(edge(@switch + 1)) == @switch
      assert edge_ms(edge(@switch + 1000)) == @switch
      assert edge_ms(edge(@switch + 59_999)) == @switch
    end

    test "at the switch, the next edge is the next whole second" do
      assert edge_ms(edge(@switch)) == @switch - 1000
      assert edge_ms(edge(@switch - 1)) == @switch - 1000
    end

    test "in seconds mode, the edge is the next whole second back from the cutoff" do
      assert edge_ms(edge(61_500)) == 61_000
      assert edge_ms(edge(61_000)) == 60_000
      assert edge_ms(edge(2000)) == 1000
      assert edge_ms(edge(1001)) == 1000
    end

    test "the last edge is the cutoff itself, then nil" do
      assert DateTime.compare(edge(1000), @cutoff) == :eq
      assert DateTime.compare(edge(1), @cutoff) == :eq
      assert edge(0) == nil
    end

    test "a non-minute switch is still hit exactly" do
      switch = 90_000
      now = before_cutoff(150_000)
      assert Countdown.next_edge(@cutoff, now, @lead, switch) |> edge_ms() == 120_000
      now = before_cutoff(100_000)
      assert Countdown.next_edge(@cutoff, now, @lead, switch) |> edge_ms() == 90_000
    end
  end

  describe "validate_config!/1 and config_from_env/1" do
    test "defaults are 30 and 5" do
      assert Countdown.config_from_env(%{}) == [lead_minutes: 30, seconds_minutes: 5]
    end

    test "good values pass" do
      env = %{
        "BEAR_CUB_COUNTDOWN_LEAD_MINUTES" => "45",
        "BEAR_CUB_COUNTDOWN_SECONDS_MINUTES" => "10"
      }

      assert Countdown.config_from_env(env) == [lead_minutes: 45, seconds_minutes: 10]
      assert Countdown.validate_config!(lead_minutes: 2, seconds_minutes: 1)
    end

    test "zero, negative and non-integer values refuse" do
      for bad <- [0, -1, 1.5, "5", nil] do
        assert_raise ArgumentError, fn ->
          Countdown.validate_config!(lead_minutes: 30, seconds_minutes: bad)
        end

        assert_raise ArgumentError, fn ->
          Countdown.validate_config!(lead_minutes: bad, seconds_minutes: 1)
        end
      end
    end

    test "seconds at or above lead refuses" do
      for switch <- [30, 31] do
        assert_raise ArgumentError, fn ->
          Countdown.validate_config!(lead_minutes: 30, seconds_minutes: switch)
        end
      end
    end

    test "non-numeric env values refuse instead of falling back" do
      for raw <- ["abc", "5.5", "", "0", "-3"] do
        assert_raise ArgumentError, fn ->
          Countdown.config_from_env(%{"BEAR_CUB_COUNTDOWN_SECONDS_MINUTES" => raw})
        end
      end
    end
  end
end
