defmodule BearCub.RoutinesTest do
  use ExUnit.Case, async: true

  alias BearCub.Routines

  @tz "America/Los_Angeles"
  @windows [
    morning: {~T[05:00:00], ~T[17:00:00]},
    evening: {~T[17:00:00], ~T[23:00:00]}
  ]

  defp la(time), do: DateTime.new!(~D[2026-07-10], time, @tz)

  describe "windows/0" do
    test "reads the configured windows (D1 defaults in test env)" do
      assert Routines.windows() == @windows
    end
  end

  describe "current/2" do
    test "the morning window opens at exactly 05:00" do
      assert Routines.current(la(~T[04:59:59]), @windows) == {:upcoming, :morning}
      assert Routines.current(la(~T[05:00:00]), @windows) == {:active, :morning}
    end

    test "edge-to-edge handoff at 17:00 — no gap, no overlap" do
      assert Routines.current(la(~T[16:59:59]), @windows) == {:active, :morning}
      assert Routines.current(la(~T[17:00:00]), @windows) == {:active, :evening}
    end

    test "evening closes at 23:00; overnight shows the next morning, upcoming" do
      assert Routines.current(la(~T[22:59:59]), @windows) == {:active, :evening}
      assert Routines.current(la(~T[23:00:00]), @windows) == {:upcoming, :morning}
      assert Routines.current(la(~T[23:59:59]), @windows) == {:upcoming, :morning}
      assert Routines.current(la(~T[00:00:00]), @windows) == {:upcoming, :morning}
      assert Routines.current(la(~T[00:01:00]), @windows) == {:upcoming, :morning}
    end

    test "honors non-default windows, including a midday gap" do
      windows = [morning: {~T[06:00:00], ~T[12:00:00]}, evening: {~T[18:00:00], ~T[21:00:00]}]

      assert Routines.current(la(~T[13:00:00]), windows) == {:upcoming, :evening}
      assert Routines.current(la(~T[22:00:00]), windows) == {:upcoming, :morning}
    end
  end

  describe "next_boundary/2" do
    test "mid-morning → the 17:00 handoff" do
      assert Routines.next_boundary(la(~T[10:00:00]), @windows) == la(~T[17:00:00])
    end

    test "evening → the 23:00 window close" do
      assert Routines.next_boundary(la(~T[18:00:00]), @windows) == la(~T[23:00:00])
    end

    test "after 23:00 → midnight, the derived daily reset (design §2)" do
      assert Routines.next_boundary(la(~T[23:30:00]), @windows) ==
               DateTime.new!(~D[2026-07-11], ~T[00:00:00], @tz)
    end

    test "small hours → the 05:00 morning opening" do
      assert Routines.next_boundary(la(~T[00:01:00]), @windows) == la(~T[05:00:00])
    end

    test "exactly on an edge → the next edge, never itself" do
      assert Routines.next_boundary(la(~T[17:00:00]), @windows) == la(~T[23:00:00])

      assert Routines.next_boundary(la(~T[23:00:00]), @windows) ==
               DateTime.new!(~D[2026-07-11], ~T[00:00:00], @tz)
    end
  end

  describe "next_boundary/2 across DST transitions" do
    test "a window edge in the spring-forward gap resolves just after it" do
      # 2026-03-08 02:00–03:00 does not exist in America/Los_Angeles; an
      # 02:30 edge must still resolve to a real instant (03:00 PDT) so the
      # boundary timer always fires.
      windows = [morning: {~T[02:30:00], ~T[12:00:00]}, evening: {~T[17:00:00], ~T[23:00:00]}]
      now = DateTime.new!(~D[2026-03-08], ~T[01:00:00], @tz)

      assert Routines.next_boundary(now, windows) ==
               DateTime.new!(~D[2026-03-08], ~T[03:00:00], @tz)
    end

    test "a window edge in the fall-back fold resolves to the first occurrence" do
      # 2026-11-01 01:30 happens twice; the boundary picks the earlier
      # (-07:00) instant so the timer never silently waits an extra hour.
      windows = [morning: {~T[01:30:00], ~T[12:00:00]}, evening: {~T[17:00:00], ~T[23:00:00]}]
      now = DateTime.new!(~D[2026-11-01], ~T[00:30:00], @tz)

      {:ambiguous, first, _second} = DateTime.new(~D[2026-11-01], ~T[01:30:00], @tz)
      assert Routines.next_boundary(now, windows) == first
    end
  end

  describe "other/1" do
    test "flips between the two routines" do
      assert Routines.other(:morning) == :evening
      assert Routines.other(:evening) == :morning
    end
  end

  describe "bonus/0" do
    test "reads the configured routine bonus R (D1 default in test env, D39, D40)" do
      assert Routines.bonus() == 5
    end
  end
end
