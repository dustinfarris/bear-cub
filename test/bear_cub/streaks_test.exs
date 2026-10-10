defmodule BearCub.StreaksTest do
  # Story 01 — streaks derived from all recorded history (D154, D155, D156).
  use BearCub.DataCase

  import BearCub.ChoresFixtures
  import BearCub.ScheduleHelpers

  alias BearCub.Chores
  alias BearCub.LocalTime
  alias BearCub.Schedules
  alias BearCub.Streaks

  @tz "America/Los_Angeles"
  @today ~D[2026-09-10]

  defp la(date, time), do: DateTime.new!(date, time, @tz)
  defp early, do: la(@today, ~T[06:00:00])

  # Today's entry with the morning window ending at 10:00, pinned through a
  # real version insert rather than a mocked clock.
  defp entry do
    put_windows({~T[05:00:00], ~T[10:00:00]}, {~T[17:00:00], ~T[21:00:00]})
    Schedules.day_entry(LocalTime.now())
  end

  defp done(chore, date, time \\ ~T[07:00:00]) do
    {:ok, completion} = Chores.complete_chore(chore, la(date, time), "kiosk")
    completion
  end

  defp range(from, to), do: Date.range(from, to)

  defp do_all(chore, dates, time), do: Enum.each(dates, &done(chore, &1, time))

  defp streak(kid, local_now \\ early()) do
    Streaks.by_kid(local_now, entry())[kid.id]
  end

  setup do
    kid = kid_fixture()
    morning = chore_fixture(kid, %{name: "Brush", routine: "morning"})
    evening = chore_fixture(kid, %{name: "Bath", routine: "evening"})
    %{kid: kid, morning: morning, evening: evening}
  end

  describe "the run" do
    test "weekends are judged like any other day", c do
      # 2026-09-05/06 are Saturday and Sunday.
      do_all(c.evening, range(~D[2026-09-03], ~D[2026-09-09]), ~T[19:00:00])
      do_all(c.morning, range(~D[2026-09-04], ~D[2026-09-10]), ~T[07:00:00])

      assert %{current: 7, longest: 7, today: :standing} = streak(c.kid)
    end

    test "an incomplete evening breaks the run", c do
      do_all(
        c.evening,
        range(~D[2026-09-05], ~D[2026-09-09]) |> Enum.reject(&(&1.day == 7)),
        ~T[19:00:00]
      )

      do_all(c.morning, range(~D[2026-09-06], ~D[2026-09-09]), ~T[07:00:00])

      # days 06 (ok), 07 (ok), 08 (evening 07 missing), 09 (ok again)
      assert %{current: 1, longest: 2, today: :pending} = streak(c.kid)
    end

    test "a failed-then-redone morning breaks the run", c do
      do_all(c.evening, range(~D[2026-09-05], ~D[2026-09-09]), ~T[19:00:00])
      do_all(c.morning, range(~D[2026-09-06], ~D[2026-09-09]), ~T[07:00:00])

      {:ok, _} = Chores.fail_chore(c.morning, la(~D[2026-09-08], ~T[12:00:00]))
      done(c.morning, ~D[2026-09-08], ~T[13:00:00])

      assert %{current: 1, longest: 2, today: :pending} = streak(c.kid)
    end

    test "a day whose roster is empty passes" do
      kid = kid_fixture(%{name: "Evening Only", position: 1})
      evening = chore_fixture(kid, %{name: "Bath", routine: "evening"})
      do_all(evening, range(~D[2026-09-05], ~D[2026-09-09]), ~T[19:00:00])

      # no morning roster: days 06..10 stand on the evenings alone
      assert %{current: 5, longest: 5, today: :standing} = streak(kid)
    end

    test "a chore archived mid-run leaves later days on the smaller roster", c do
      second = chore_fixture(c.kid, %{name: "Dress", routine: "morning"})
      do_all(c.evening, range(~D[2026-09-05], ~D[2026-09-09]), ~T[19:00:00])
      do_all(c.morning, range(~D[2026-09-06], ~D[2026-09-10]), ~T[07:00:00])
      do_all(second, range(~D[2026-09-06], ~D[2026-09-07]), ~T[07:00:00])
      {:ok, _} = Chores.archive_chore(second, la(~D[2026-09-08], ~T[12:00:00]))

      assert %{current: 5, longest: 5, today: :standing} = streak(c.kid)
    end

    test "the scan starts at the kid's first completion" do
      kid = kid_fixture(%{name: "New", position: 2})
      morning = chore_fixture(kid, %{routine: "morning"}, la(~D[2026-09-09], ~T[08:00:00]))
      evening = chore_fixture(kid, %{routine: "evening"}, la(~D[2026-09-09], ~T[08:00:00]))
      done(evening, ~D[2026-09-09], ~T[19:00:00])
      done(morning, @today)

      # earlier days have empty rosters and would pass without the bound
      assert %{current: 1, longest: 1, today: :standing} = streak(kid)
    end

    test "a first completion today scans no earlier day" do
      kid = kid_fixture(%{name: "Today", position: 5})
      morning = chore_fixture(kid, %{routine: "morning"}, la(@today, ~T[05:00:00]))
      _evening = chore_fixture(kid, %{routine: "evening"}, la(@today, ~T[05:00:00]))
      done(morning, @today)

      # yesterday's evening roster is empty, but the evening chore is live
      # today only; the morning alone does not make a standing day for today
      # unless last night passes vacuously, which makes today day one
      assert %{current: 1, longest: 1, today: :standing} = streak(kid)
    end

    test "a kid with no completions has no streak", c do
      lonely = kid_fixture(%{name: "Lonely", position: 3})

      result = Streaks.by_kid(early(), entry())
      assert %{current: 0, longest: 0} = result[c.kid.id]
      assert %{current: 0, longest: 0} = result[lonely.id]
    end
  end

  describe "today is three-valued (D156)" do
    test "standing counts today in the run", c do
      done(c.evening, ~D[2026-09-09], ~T[19:00:00])
      done(c.morning, @today)

      assert %{current: 1, today: :standing} = streak(c.kid)
    end

    test "pending shows the run ending yesterday", c do
      do_all(c.evening, range(~D[2026-09-05], ~D[2026-09-09]), ~T[19:00:00])
      do_all(c.morning, range(~D[2026-09-06], ~D[2026-09-09]), ~T[07:00:00])

      assert %{current: 4, longest: 4, today: :pending} = streak(c.kid)
    end

    test "a missed evening last night is failed at breakfast; longest survives", c do
      do_all(c.evening, range(~D[2026-09-05], ~D[2026-09-08]), ~T[19:00:00])
      do_all(c.morning, range(~D[2026-09-06], ~D[2026-09-09]), ~T[07:00:00])

      assert %{current: 0, longest: 4, today: :failed} = streak(c.kid)
    end

    test "a failed morning today is failed", c do
      do_all(c.evening, range(~D[2026-09-05], ~D[2026-09-09]), ~T[19:00:00])
      do_all(c.morning, range(~D[2026-09-06], ~D[2026-09-10]), ~T[07:00:00])
      {:ok, _} = Chores.fail_chore(c.morning, la(@today, ~T[08:00:00]))

      assert %{current: 0, longest: 4, today: :failed} = streak(c.kid)
    end

    test "the morning window closed with the morning incomplete is failed", c do
      do_all(c.evening, range(~D[2026-09-05], ~D[2026-09-09]), ~T[19:00:00])
      do_all(c.morning, range(~D[2026-09-06], ~D[2026-09-09]), ~T[07:00:00])

      assert %{current: 0, longest: 4, today: :failed} = streak(c.kid, la(@today, ~T[10:00:00]))
      assert %{current: 4, today: :pending} = streak(c.kid, la(@today, ~T[09:59:00]))
    end

    test "a completed morning stays standing after the window closes", c do
      done(c.evening, ~D[2026-09-09], ~T[19:00:00])
      done(c.morning, @today)

      assert %{current: 1, today: :standing} = streak(c.kid, la(@today, ~T[15:00:00]))
    end

    test "longest counts today's run only when standing, and past runs otherwise", c do
      # a past run of 3 (days 02..04), a gap, then 3 more through today
      do_all(c.evening, range(~D[2026-09-01], ~D[2026-09-03]), ~T[19:00:00])
      do_all(c.morning, range(~D[2026-09-02], ~D[2026-09-04]), ~T[07:00:00])
      do_all(c.evening, range(~D[2026-09-08], ~D[2026-09-09]), ~T[19:00:00])
      do_all(c.morning, range(~D[2026-09-09], ~D[2026-09-10]), ~T[07:00:00])

      assert %{current: 2, longest: 3, today: :standing} = streak(c.kid)
    end
  end

  describe "parity with Chores.standing/2" do
    test "agrees day for day over staged history", c do
      other = kid_fixture(%{name: "Other", position: 4})
      o_morning = chore_fixture(other, %{routine: "morning"})
      o_evening = chore_fixture(other, %{routine: "evening"})

      do_all(
        c.evening,
        [~D[2026-09-01], ~D[2026-09-02], ~D[2026-09-04], ~D[2026-09-06]],
        ~T[19:00:00]
      )

      do_all(
        c.morning,
        [~D[2026-09-02], ~D[2026-09-03], ~D[2026-09-05], ~D[2026-09-07]],
        ~T[07:00:00]
      )

      do_all(o_evening, range(~D[2026-08-28], ~D[2026-09-09]), ~T[19:00:00])
      do_all(o_morning, range(~D[2026-08-29], ~D[2026-09-10]), ~T[07:00:00])
      {:ok, _} = Chores.fail_chore(o_morning, la(~D[2026-09-03], ~T[12:00:00]))

      result = Streaks.by_kid(la(@today, ~T[23:00:00]), entry())

      for {kid, first} <- [{c.kid, ~D[2026-09-01]}, {other, ~D[2026-08-28]}] do
        flags =
          for day <- range(first, @today),
              do: Chores.standing(kid, day).standing?

        {current, longest} = reference(flags)
        assert %{current: ^current, longest: ^longest} = result[kid.id]
      end
    end

    # The run ending at the last day, and the longest run, of a boolean list.
    defp reference(flags) do
      runs =
        Enum.chunk_by(flags, & &1) |> Enum.filter(&hd/1) |> Enum.map(&length/1)

      current = if List.last(flags), do: List.last(runs), else: 0
      {current, Enum.max(runs, fn -> 0 end)}
    end
  end

  describe "cost and history" do
    test "a schedule change never alters a past streak", c do
      do_all(c.evening, range(~D[2026-09-05], ~D[2026-09-09]), ~T[19:00:00])
      do_all(c.morning, range(~D[2026-09-06], ~D[2026-09-09]), ~T[07:00:00])

      before = streak(c.kid)
      put_bonuses(9, 9)
      put_windows({~T[04:00:00], ~T[10:00:00]}, {~T[12:00:00], ~T[14:00:00]})

      assert Streaks.by_kid(early(), Schedules.day_entry(LocalTime.now()))[c.kid.id] == before
    end

    test "the query count does not grow with history", c do
      e = entry()
      do_all(c.evening, range(~D[2026-09-08], ~D[2026-09-09]), ~T[19:00:00])
      do_all(c.morning, range(~D[2026-09-09], ~D[2026-09-09]), ~T[07:00:00])
      short = count_queries(fn -> Streaks.by_kid(early(), e) end)

      do_all(c.evening, range(~D[2026-06-01], ~D[2026-09-07]), ~T[19:00:00])
      do_all(c.morning, range(~D[2026-06-02], ~D[2026-09-08]), ~T[07:00:00])
      long = count_queries(fn -> Streaks.by_kid(early(), e) end)

      assert short == long
      assert short <= 5
    end
  end

  defp count_queries(fun) do
    test_pid = self()
    id = make_ref()

    :telemetry.attach(
      id,
      [:bear_cub, :repo, :query],
      fn _e, _m, _meta, _c -> if self() == test_pid, do: send(test_pid, :query) end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    drain(0)
  end

  defp drain(n) do
    receive do
      :query -> drain(n + 1)
    after
      0 -> n
    end
  end
end
