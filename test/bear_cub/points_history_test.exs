defmodule BearCub.PointsHistoryTest do
  # Points earned in all and by month (D158): the signed contribution of
  # Chores.earnings_by_kid, bucketed by the contribution's local_date, with
  # no redemptions leg. Floors apply per month and to the lifetime figure.

  use BearCub.DataCase

  alias BearCub.Chores
  alias BearCub.Chores.Completion
  alias BearCub.Points
  alias BearCub.Rewards

  import BearCub.ChoresFixtures
  import BearCub.RewardsFixtures
  import BearCub.SchedulesFixtures

  @tz "America/Los_Angeles"

  defp la(date, time), do: DateTime.new!(date, time, @tz)

  defp fail_completion(%Completion{} = completion, at) do
    completion
    |> Ecto.Changeset.change(undone_at: at, failed_at: at)
    |> Repo.update!()
  end

  defp do_extra(chore, date) do
    {:ok, completion} = Chores.complete_chore(chore, la(date, ~T[08:00:00]), "kiosk")
    completion
  end

  describe "Chores.earnings_by_kid_month/1" do
    test "buckets a last-of-month and a first-of-next-month contribution apart" do
      kid = kid_fixture()
      extra = chore_fixture(kid, %{name: "Extra", routine: nil, points: 7})
      routine = chore_fixture(kid, %{name: "Routine", routine: "morning"})

      do_extra(extra, ~D[2026-09-30])
      do_extra(extra, ~D[2026-10-01])
      {:ok, _} = Chores.complete_chore(routine, la(~D[2026-09-30], ~T[08:00:00]), "kiosk")
      {:ok, _} = Chores.complete_chore(routine, la(~D[2026-10-01], ~T[08:00:00]), "kiosk")

      assert Chores.earnings_by_kid_month(~D[2026-10-10]) ==
               %{kid.id => %{~D[2026-09-01] => 12, ~D[2026-10-01] => 12}}
    end

    test "is signed and unfloored, and its months sum to earnings_by_kid" do
      kid = kid_fixture()
      extra = chore_fixture(kid, %{name: "Extra", routine: nil, points: 6})
      other = chore_fixture(kid, %{name: "Other", routine: nil, points: 3})
      fail_completion(do_extra(extra, ~D[2026-09-12]), ~U[2026-09-12 20:00:00Z])
      do_extra(other, ~D[2026-10-02])

      by_month = Chores.earnings_by_kid_month(~D[2026-10-10])

      assert by_month[kid.id] == %{~D[2026-09-01] => -6, ~D[2026-10-01] => 3}

      assert by_month[kid.id] |> Map.values() |> Enum.sum() ==
               Chores.earnings_by_kid(~D[2026-10-10])[kid.id]
    end

    test "ignores contributions after the given date" do
      kid = kid_fixture()
      extra = chore_fixture(kid, %{name: "Extra", routine: nil, points: 6})
      do_extra(extra, ~D[2026-10-20])

      assert Chores.earnings_by_kid_month(~D[2026-10-10]) == %{}
    end
  end

  describe "Points.earned_history/1" do
    test "months run from the first completion month to the current one; earlier months are absent" do
      kid = kid_fixture()
      extra = chore_fixture(kid, %{name: "Extra", routine: nil, points: 4})
      do_extra(extra, ~D[2026-08-15])

      assert %{lifetime: 4, months: months} = Points.earned_history(~D[2026-10-10])[kid.id]

      assert months == [
               {~D[2026-08-01], 4},
               {~D[2026-09-01], 0},
               {~D[2026-10-01], 0}
             ]
    end

    test "lists at most the last 8 months ending with the current month" do
      kid = kid_fixture()
      extra = chore_fixture(kid, %{name: "Extra", routine: nil, points: 4})
      do_extra(extra, ~D[2025-12-15])
      do_extra(extra, ~D[2026-10-02])

      %{lifetime: lifetime, months: months} = Points.earned_history(~D[2026-10-10])[kid.id]

      assert lifetime == 8
      assert length(months) == 8
      assert List.first(months) == {~D[2026-03-01], 0}
      assert List.last(months) == {~D[2026-10-01], 4}
    end

    test "a kid with no completions gets the current month at 0 and lifetime 0" do
      kid = kid_fixture()

      assert Points.earned_history(~D[2026-10-10]) ==
               %{kid.id => %{lifetime: 0, months: [{~D[2026-10-01], 0}]}}
    end

    test "a month whose fails exceed its earnings shows 0, and the lifetime never goes negative" do
      kid = kid_fixture()
      extra = chore_fixture(kid, %{name: "Extra", routine: nil, points: 6})
      fail_completion(do_extra(extra, ~D[2026-09-12]), ~U[2026-09-12 20:00:00Z])
      do_extra(extra, ~D[2026-10-02])

      %{lifetime: lifetime, months: months} = Points.earned_history(~D[2026-10-10])[kid.id]

      assert months == [{~D[2026-09-01], 0}, {~D[2026-10-01], 6}]
      # Unfloored the months sum to 0 (−6 + 6); a further fail goes below.
      assert lifetime == 0

      other = chore_fixture(kid, %{name: "Other", routine: nil, points: 9})
      fail_completion(do_extra(other, ~D[2026-10-03]), ~U[2026-10-03 20:00:00Z])

      assert %{lifetime: 0} = Points.earned_history(~D[2026-10-10])[kid.id]
    end

    test "spending never lowers the history" do
      kid = kid_fixture()
      extra = chore_fixture(kid, %{name: "Extra", routine: nil, points: 20})
      do_extra(extra, ~D[2026-10-02])
      reward = reward_fixture(kid, %{points: 8})
      {:ok, _} = Rewards.direct_redeem(kid, reward, 20, la(~D[2026-10-03], ~T[09:00:00]))

      assert Points.earned_history(~D[2026-10-10])[kid.id] ==
               %{lifetime: 20, months: [{~D[2026-10-01], 20}]}
    end

    test "each contribution keeps the price of the version in force when it was earned (D121)" do
      kid = kid_fixture()
      routine = chore_fixture(kid, %{name: "Routine", routine: "morning"})
      {:ok, _} = Chores.complete_chore(routine, la(~D[2026-09-15], ~T[08:00:00]), "kiosk")

      version_fixture(
        la(~D[2026-09-20], ~T[00:00:00]) |> DateTime.shift_zone!("Etc/UTC"),
        %{routine_bonus: 9}
      )

      {:ok, _} = Chores.complete_chore(routine, la(~D[2026-10-02], ~T[08:00:00]), "kiosk")

      assert Points.earned_history(~D[2026-10-10])[kid.id] ==
               %{lifetime: 14, months: [{~D[2026-09-01], 5}, {~D[2026-10-01], 9}]}
    end

    test "unfloored lifetime minus approved unreversed spend equals the raw balance" do
      kid = kid_fixture()
      routine = chore_fixture(kid, %{name: "Routine", routine: "morning"})
      extra = chore_fixture(kid, %{name: "Extra", routine: nil, points: 20})
      {:ok, _} = Chores.complete_chore(routine, la(~D[2026-09-30], ~T[08:00:00]), "kiosk")
      do_extra(extra, ~D[2026-10-02])
      reward = reward_fixture(kid, %{points: 8})
      {:ok, _} = Rewards.direct_redeem(kid, reward, 25, la(~D[2026-10-03], ~T[09:00:00]))

      today = ~D[2026-10-10]
      unfloored = Chores.earnings_by_kid_month(today)[kid.id] |> Map.values() |> Enum.sum()
      spend = Rewards.spend_totals_by_kid(today)[kid.id]

      assert unfloored + spend == Points.balance(kid, today)
      assert Points.earned_history(today)[kid.id].lifetime == unfloored
    end

    test "takes the same number of queries whatever the history length" do
      kid = kid_fixture()
      extra = chore_fixture(kid, %{name: "Extra", routine: nil, points: 2})
      routine = chore_fixture(kid, %{name: "Routine", routine: "morning"})
      do_extra(extra, ~D[2026-10-01])
      {:ok, _} = Chores.complete_chore(routine, la(~D[2026-10-01], ~T[08:00:00]), "kiosk")

      count = fn ->
        ref = make_ref()
        me = self()

        :telemetry.attach(
          ref,
          [:bear_cub, :repo, :query],
          fn _, _, _, _ -> send(me, {ref, :query}) end,
          nil
        )

        Points.earned_history(~D[2026-10-10])
        :telemetry.detach(ref)
        drain(ref, 0)
      end

      small = count.()

      for day <- 2..9 do
        {:ok, _} =
          Chores.complete_chore(routine, la(Date.new!(2026, 9, day), ~T[08:00:00]), "kiosk")

        do_extra(extra, Date.new!(2026, 8, day))
      end

      assert count.() == small
    end
  end

  defp drain(ref, n) do
    receive do
      {^ref, :query} -> drain(ref, n + 1)
    after
      0 -> n
    end
  end
end
