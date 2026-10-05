defmodule BearCub.PointsRedemptionsTest do
  # Story 03's own pin AC: the redemptions leg composes into
  # Points.balance/2 without disturbing Chores.earnings, proven both by
  # an empty table (this file) and by the Story-01 pinning suite
  # (points_test.exs) passing byte-unmodified alongside it.

  use BearCub.DataCase

  alias BearCub.Chores
  alias BearCub.Points
  alias BearCub.Rewards

  import BearCub.ChoresFixtures
  import BearCub.RewardsFixtures

  @tz "America/Los_Angeles"

  defp la(date, time), do: DateTime.new!(date, time, @tz)

  test "with the redemptions table empty, zero rows contribute zero to every balance (SC-9, D72)" do
    kid = kid_fixture()
    chore = chore_fixture(kid, %{name: "Extra", routine: nil, points: 7})
    {:ok, _} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[08:00:00]), "kiosk")

    assert Rewards.spend_totals_by_kid(~D[2026-07-10]) == %{}
    assert Points.balance(kid, ~D[2026-07-10]) == 7
    assert Points.balances(~D[2026-07-10]) == %{kid.id => 7}
  end

  test "an approved unreversed redemption lowers the balance by its snapshot price and it stays down (SC-3, D57)" do
    kid = kid_fixture()
    chore = chore_fixture(kid, %{name: "Extra", routine: nil, points: 20})
    {:ok, _} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[08:00:00]), "kiosk")

    reward = reward_fixture(kid, %{points: 8})
    balance_before = Points.balance(kid, ~D[2026-07-10])

    {:ok, redemption} =
      Rewards.direct_redeem(kid, reward, balance_before, la(~D[2026-07-10], ~T[09:00:00]))

    assert Points.balance(kid, ~D[2026-07-10]) == 12
    assert Points.balances(~D[2026-07-10]) == %{kid.id => 12}

    {:ok, _} = Rewards.reverse_redemption(redemption, la(~D[2026-07-11], ~T[08:00:00]))
    assert Points.balance(kid, ~D[2026-07-11]) == 20
  end
end
