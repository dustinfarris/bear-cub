defmodule BearCub.RoutinesTest do
  use ExUnit.Case, async: true

  alias BearCub.Routines
  alias BearCub.Schedules.DayEntry

  @tz "America/Los_Angeles"
  @windows [
    morning: {~T[05:00:00], ~T[17:00:00]},
    evening: {~T[17:00:00], ~T[23:00:00]}
  ]

  @entry %DayEntry{
    weekday: 5,
    morning_start: ~T[05:00:00],
    morning_end: ~T[17:00:00],
    evening_start: ~T[17:00:00],
    evening_end: ~T[23:00:00],
    early_bird_cutoff: ~T[07:45:00]
  }

  defp entry(overrides), do: struct!(@entry, overrides)

  defp la(time), do: DateTime.new!(~D[2026-07-10], time, @tz)

  describe "in_force/2 (schedule versions)" do
    alias BearCub.Schedules.ScheduleVersion

    @v0 %ScheduleVersion{id: 1, effective_at: ~U[1970-01-01 00:00:00Z]}
    @v1 %ScheduleVersion{id: 2, effective_at: ~U[2026-10-04 12:00:00Z]}
    @v2 %ScheduleVersion{id: 3, effective_at: ~U[2026-10-10 12:00:00Z]}

    test "a version applies from exactly its effective instant" do
      assert Routines.in_force([@v0, @v1], ~U[2026-10-04 12:00:00Z]) == @v1
    end

    test "one second before, the previous version still applies" do
      assert Routines.in_force([@v0, @v1], ~U[2026-10-04 11:59:59Z]) == @v0
    end

    test "picks the latest effective_at at or before the instant, whatever the list order" do
      assert Routines.in_force([@v2, @v0, @v1], ~U[2026-10-11 00:00:00Z]) == @v2
      assert Routines.in_force([@v2, @v0, @v1], ~U[2026-10-05 00:00:00Z]) == @v1
    end

    test "resolves a local datetime by the instant it denotes" do
      # 2026-10-04 05:00 PDT is 12:00Z — exactly @v1's instant
      assert Routines.in_force([@v0, @v1], DateTime.new!(~D[2026-10-04], ~T[05:00:00], @tz)) ==
               @v1
    end

    test "raises with no versions rather than defaulting" do
      assert_raise ArgumentError, fn -> Routines.in_force([], ~U[2026-10-04 12:00:00Z]) end
    end

    test "raises when every version is later than the instant" do
      assert_raise ArgumentError, fn -> Routines.in_force([@v1], ~U[2026-10-04 11:59:59Z]) end
    end
  end

  describe "day/2" do
    alias BearCub.Schedules.{DayEntry, ScheduleVersion}

    test "returns the entry for the date's ISO weekday" do
      days = for w <- 1..7, do: %DayEntry{weekday: w, early_bird_cutoff: Time.new!(w, 0, 0)}
      version = %ScheduleVersion{days: Enum.shuffle(days)}

      # 2026-10-09 is a Friday (5), 2026-10-10 a Saturday (6), 2026-10-11 a Sunday (7)
      assert Routines.day(version, ~D[2026-10-09]).weekday == 5
      assert Routines.day(version, ~D[2026-10-10]).weekday == 6
      assert Routines.day(version, ~D[2026-10-11]).weekday == 7
      assert Routines.day(version, ~D[2026-10-05]).weekday == 1
    end
  end

  describe "windows/0" do
    test "reads the configured windows (D1 defaults in test env)" do
      assert Routines.windows() == @windows
    end
  end

  describe "early bird (backlog 2026-09-06)" do
    test "early_bird_cutoff/0 reads the configured local wall-clock cutoff (07:45 default)" do
      assert Routines.early_bird_cutoff() == ~T[07:45:00]
    end

    test "early_bird_bonus/0 reads the configured bonus E (2 default)" do
      assert Routines.early_bird_bonus() == 2
    end
  end

  describe "current/2" do
    test "the morning window opens at exactly 05:00" do
      assert Routines.current(la(~T[04:59:59]), @entry) == {:upcoming, :morning}
      assert Routines.current(la(~T[05:00:00]), @entry) == {:active, :morning}
    end

    test "edge-to-edge handoff at 17:00 — no gap, no overlap" do
      assert Routines.current(la(~T[16:59:59]), @entry) == {:active, :morning}
      assert Routines.current(la(~T[17:00:00]), @entry) == {:active, :evening}
    end

    test "evening closes at 23:00; overnight shows the next morning, upcoming" do
      assert Routines.current(la(~T[22:59:59]), @entry) == {:active, :evening}
      assert Routines.current(la(~T[23:00:00]), @entry) == {:upcoming, :morning}
      assert Routines.current(la(~T[23:59:59]), @entry) == {:upcoming, :morning}
      assert Routines.current(la(~T[00:00:00]), @entry) == {:upcoming, :morning}
      assert Routines.current(la(~T[00:01:00]), @entry) == {:upcoming, :morning}
    end

    test "honors non-default windows, including a midday gap" do
      entry =
        entry(
          morning_start: ~T[06:00:00],
          morning_end: ~T[12:00:00],
          evening_start: ~T[18:00:00],
          evening_end: ~T[21:00:00],
          early_bird_cutoff: ~T[07:00:00]
        )

      assert Routines.current(la(~T[13:00:00]), entry) == {:upcoming, :evening}
      assert Routines.current(la(~T[22:00:00]), entry) == {:upcoming, :morning}
    end
  end

  describe "next_boundary/2" do
    test "mid-morning → the 17:00 handoff" do
      assert Routines.next_boundary(la(~T[10:00:00]), @entry) == la(~T[17:00:00])
    end

    test "evening → the 23:00 window close" do
      assert Routines.next_boundary(la(~T[18:00:00]), @entry) == la(~T[23:00:00])
    end

    test "after 23:00 → midnight, the derived daily reset (design §2)" do
      assert Routines.next_boundary(la(~T[23:30:00]), @entry) ==
               DateTime.new!(~D[2026-07-11], ~T[00:00:00], @tz)
    end

    test "small hours → the 05:00 morning opening" do
      assert Routines.next_boundary(la(~T[00:01:00]), @entry) == la(~T[05:00:00])
    end

    test "Friday's last edge → midnight, from which Saturday's own entry governs" do
      friday = entry(%{})
      saturday = entry(weekday: 6, morning_start: ~T[08:00:00], morning_end: ~T[17:00:00])

      assert Routines.next_boundary(la(~T[23:30:00]), friday) ==
               DateTime.new!(~D[2026-07-11], ~T[00:00:00], @tz)

      # the re-resolve at midnight hands the Saturday entry in
      saturday_midnight = DateTime.new!(~D[2026-07-11], ~T[00:00:00], @tz)
      assert Routines.current(saturday_midnight, saturday) == {:upcoming, :morning}

      assert Routines.next_boundary(saturday_midnight, saturday) ==
               DateTime.new!(~D[2026-07-11], ~T[08:00:00], @tz)
    end

    test "exactly on an edge → the next edge, never itself" do
      assert Routines.next_boundary(la(~T[17:00:00]), @entry) == la(~T[23:00:00])

      assert Routines.next_boundary(la(~T[23:00:00]), @entry) ==
               DateTime.new!(~D[2026-07-11], ~T[00:00:00], @tz)
    end
  end

  describe "next_boundary/2 across DST transitions" do
    test "a window edge in the spring-forward gap resolves just after it" do
      # 2026-03-08 02:00–03:00 does not exist in America/Los_Angeles; an
      # 02:30 edge must still resolve to a real instant (03:00 PDT) so the
      # boundary timer always fires.
      entry = entry(morning_start: ~T[02:30:00], morning_end: ~T[12:00:00])
      now = DateTime.new!(~D[2026-03-08], ~T[01:00:00], @tz)

      assert Routines.next_boundary(now, entry) ==
               DateTime.new!(~D[2026-03-08], ~T[03:00:00], @tz)
    end

    test "a window edge in the fall-back fold resolves to the first occurrence" do
      # 2026-11-01 01:30 happens twice; the boundary picks the earlier
      # (-07:00) instant so the timer never silently waits an extra hour.
      entry = entry(morning_start: ~T[01:30:00], morning_end: ~T[12:00:00])
      now = DateTime.new!(~D[2026-11-01], ~T[00:30:00], @tz)

      {:ambiguous, first, _second} = DateTime.new(~D[2026-11-01], ~T[01:30:00], @tz)
      assert Routines.next_boundary(now, entry) == first
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
