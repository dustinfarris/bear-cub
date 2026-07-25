defmodule BearCub.RewardsTest do
  # Story 03 — the rewards domain, headless: schema, write paths,
  # derivations, PubSub. No route, no LiveView, no template exercises
  # this; the tests below are the exercise.

  use BearCub.DataCase

  alias BearCub.Rewards

  import BearCub.ChoresFixtures
  import BearCub.RewardsFixtures

  @tz "America/Los_Angeles"

  # Per docs/learnings.org [2026-07-17]: pin the windows even though none
  # of this story's derivations read them, so nothing here can come to
  # depend on the wall clock by accident.
  setup do
    original_windows = Application.fetch_env!(:bear_cub, :routine_windows)
    on_exit(fn -> Application.put_env(:bear_cub, :routine_windows, original_windows) end)

    Application.put_env(:bear_cub, :routine_windows,
      morning: {~T[05:00:00], ~T[17:00:00]},
      evening: {~T[17:00:00], ~T[23:00:00]}
    )

    :ok
  end

  defp la(date, time), do: DateTime.new!(date, time, @tz)

  defp sibling(attrs \\ %{}) do
    kid_fixture(Enum.into(attrs, %{name: "Sibling", color: "#123456", position: 1}))
  end

  describe "catalog (SC-1, D58)" do
    test "create_reward/2 offered to a specific kid sets kid_id, never cast from attrs" do
      kid = kid_fixture()
      other = sibling()

      {:ok, reward} =
        Rewards.create_reward(kid, %{name: "Movie Night", icon: "🎬", points: 30, kid_id: other.id})

      assert reward.kid_id == kid.id
    end

    test "create_reward/2 offered to any kid stores a nil kid_id" do
      {:ok, reward} = Rewards.create_reward(nil, %{name: "Bike", icon: "🚲", points: 500})
      assert reward.kid_id == nil
    end

    test "create_reward/2 appends at the end of the flat, non-bucketed position list" do
      {:ok, r1} = Rewards.create_reward(nil, %{name: "A", icon: "🎁", points: 5})
      {:ok, r2} = Rewards.create_reward(nil, %{name: "B", icon: "🎁", points: 5})
      assert r2.position == r1.position + 1
    end

    test "update_reward/3 reassigns audience via kid_or_nil, never from attrs" do
      kid = kid_fixture()
      other = sibling()
      reward = reward_fixture(kid)

      {:ok, updated} = Rewards.update_reward(reward, other, %{kid_id: kid.id})
      assert updated.kid_id == other.id
    end

    test "list_rewards/2 returns rewards offered to any kid or to this kid, not retired, ordered by position" do
      kid = kid_fixture()
      other = sibling()

      family = reward_fixture(nil, %{name: "Family Movie"})
      mine = reward_fixture(kid, %{name: "Mine"})
      _theirs = reward_fixture(other, %{name: "Theirs"})

      assert Rewards.list_rewards(kid, ~D[2026-07-25]) == [family, mine]
    end

    test "archive_reward/2 stamps retired_at and removes the reward from list_rewards/2, never deleting it" do
      kid = kid_fixture()
      reward = reward_fixture(kid)

      {:ok, archived} = Rewards.archive_reward(reward, la(~D[2026-07-25], ~T[10:00:00]))

      assert archived.retired_at
      assert Rewards.list_rewards(kid, ~D[2026-07-25]) == []
      assert Rewards.get_reward!(reward.id).id == reward.id
    end

    test "list_all_rewards/0 returns every non-retired reward regardless of audience, in position order" do
      kid = kid_fixture()
      other = sibling()

      family = reward_fixture(nil, %{name: "Family Movie"})
      mine = reward_fixture(kid, %{name: "Mine"})
      theirs = reward_fixture(other, %{name: "Theirs"})

      {:ok, archived} =
        Rewards.archive_reward(
          reward_fixture(nil, %{name: "Gone"}),
          la(~D[2026-07-25], ~T[10:00:00])
        )

      assert Rewards.list_all_rewards() |> Enum.map(& &1.id) == [family.id, mine.id, theirs.id]
      refute archived.id in (Rewards.list_all_rewards() |> Enum.map(& &1.id))
    end

    test "get_reward/1 returns nil for a vanished reward instead of raising" do
      reward = reward_fixture()
      assert Rewards.get_reward(reward.id).id == reward.id

      Repo.delete!(reward)
      assert Rewards.get_reward(reward.id) == nil
    end

    test "list_all_rewards/0 preloads :kid so callers can show who a reward is offered to" do
      kid = kid_fixture()
      reward_fixture(kid, %{name: "Mine"})

      [loaded] = Rewards.list_all_rewards()
      assert %BearCub.Chores.Kid{} = loaded.kid
      assert loaded.kid.id == kid.id
    end
  end

  describe "ordering (SC-1, D68)" do
    test "move_reward/2 :down swaps position with the next reward" do
      {:ok, first} = Rewards.create_reward(nil, %{name: "First", icon: "1️⃣", points: 5})
      {:ok, second} = Rewards.create_reward(nil, %{name: "Second", icon: "2️⃣", points: 5})

      {:ok, _} = Rewards.move_reward(first, :down)

      assert Rewards.list_all_rewards() |> Enum.map(& &1.id) == [second.id, first.id]
    end

    test "move_reward/2 :up swaps position with the previous reward" do
      {:ok, first} = Rewards.create_reward(nil, %{name: "First", icon: "1️⃣", points: 5})
      {:ok, second} = Rewards.create_reward(nil, %{name: "Second", icon: "2️⃣", points: 5})

      {:ok, _} = Rewards.move_reward(second, :up)

      assert Rewards.list_all_rewards() |> Enum.map(& &1.id) == [second.id, first.id]
    end

    test "move_reward/2 is a silent no-op at the top of the list" do
      {:ok, only} = Rewards.create_reward(nil, %{name: "Only", icon: "🌟", points: 5})

      assert {:ok, _} = Rewards.move_reward(only, :up)
      assert Rewards.list_all_rewards() |> Enum.map(& &1.id) == [only.id]
    end

    test "move_reward/2 is a silent no-op at the bottom of the list" do
      {:ok, only} = Rewards.create_reward(nil, %{name: "Only", icon: "🌟", points: 5})

      assert {:ok, _} = Rewards.move_reward(only, :down)
      assert Rewards.list_all_rewards() |> Enum.map(& &1.id) == [only.id]
    end

    test "move_reward/2 broadcasts :rewards_changed" do
      {:ok, first} = Rewards.create_reward(nil, %{name: "First", icon: "1️⃣", points: 5})
      {:ok, _second} = Rewards.create_reward(nil, %{name: "Second", icon: "2️⃣", points: 5})
      Rewards.subscribe()

      {:ok, _} = Rewards.move_reward(first, :down)
      assert_receive :rewards_changed
    end

    test "the new order from move_reward/2 is what the kiosk-facing list_rewards/2 also reads" do
      kid = kid_fixture()
      {:ok, first} = Rewards.create_reward(nil, %{name: "First", icon: "1️⃣", points: 5})
      {:ok, second} = Rewards.create_reward(nil, %{name: "Second", icon: "2️⃣", points: 5})

      {:ok, _} = Rewards.move_reward(first, :down)

      assert Rewards.list_rewards(kid, ~D[2026-07-25]) |> Enum.map(& &1.id) == [
               second.id,
               first.id
             ]
    end
  end

  describe "one open request per kid per local day (D61)" do
    test "a second request the same day errors; the next local day succeeds with yesterday's row untouched" do
      kid = kid_fixture()
      reward_a = reward_fixture(kid, %{name: "A"})
      reward_b = reward_fixture(kid, %{name: "B"})

      {:ok, first} = Rewards.request_redemption(kid, reward_a, la(~D[2026-07-10], ~T[08:00:00]))

      assert {:error, %Ecto.Changeset{}} =
               Rewards.request_redemption(kid, reward_b, la(~D[2026-07-10], ~T[09:00:00]))

      {:ok, next_day} =
        Rewards.request_redemption(kid, reward_b, la(~D[2026-07-11], ~T[08:00:00]))

      assert next_day.local_date == ~D[2026-07-11]

      unchanged = Rewards.get_redemption!(first.id)
      assert unchanged.requested_at == first.requested_at
      assert is_nil(unchanged.approved_at)
      assert is_nil(unchanged.declined_at)
    end
  end

  describe "write paths — each stamps its own marker (D59)" do
    test "request_redemption/3 sets only requested_at, snapshotting the reward's price" do
      kid = kid_fixture()
      reward = reward_fixture(kid, %{points: 40})

      {:ok, r} = Rewards.request_redemption(kid, reward, la(~D[2026-07-10], ~T[08:00:00]))

      assert r.requested_at
      assert is_nil(r.approved_at)
      assert is_nil(r.declined_at)
      assert is_nil(r.reversed_at)
      assert r.points == 40
      assert r.source == "kiosk"
      assert r.local_date == ~D[2026-07-10]
    end

    test "direct_redeem/4 sets approved_at with no prior request" do
      kid = kid_fixture()
      reward = reward_fixture(kid, %{points: 10})

      {:ok, r} = Rewards.direct_redeem(kid, reward, 100, la(~D[2026-07-10], ~T[08:00:00]))

      assert is_nil(r.requested_at)
      assert r.approved_at
      assert r.source == "admin"
      assert r.points == 10
    end

    test "approve_redemption/3 stamps approved_at on a pending request, leaving requested_at alone" do
      kid = kid_fixture()
      reward = reward_fixture(kid, %{points: 10})
      {:ok, pending} = Rewards.request_redemption(kid, reward, la(~D[2026-07-10], ~T[08:00:00]))

      {:ok, approved} = Rewards.approve_redemption(pending, 100, la(~D[2026-07-10], ~T[09:00:00]))

      assert approved.approved_at
      assert approved.requested_at == pending.requested_at
    end

    test "decline_redemption/2 stamps declined_at" do
      kid = kid_fixture()
      reward = reward_fixture(kid)
      {:ok, pending} = Rewards.request_redemption(kid, reward, la(~D[2026-07-10], ~T[08:00:00]))

      {:ok, declined} = Rewards.decline_redemption(pending, la(~D[2026-07-10], ~T[09:00:00]))
      assert declined.declined_at
    end

    test "reverse_redemption/2 stamps reversed_at, leaving approved_at intact" do
      kid = kid_fixture()
      reward = reward_fixture(kid, %{points: 10, repeatable: false})

      {:ok, redemption} =
        Rewards.direct_redeem(kid, reward, 100, la(~D[2026-07-10], ~T[08:00:00]))

      {:ok, reversed} = Rewards.reverse_redemption(redemption, la(~D[2026-07-11], ~T[08:00:00]))

      assert reversed.reversed_at
      assert reversed.approved_at == redemption.approved_at
    end
  end

  describe "derived state — no status column (D59)" do
    test "pending?/2 is true only for an unanswered request dated today" do
      kid = kid_fixture()
      reward = reward_fixture(kid)
      {:ok, r} = Rewards.request_redemption(kid, reward, la(~D[2026-07-10], ~T[08:00:00]))

      assert Rewards.pending?(r, ~D[2026-07-10])
      refute Rewards.pending?(r, ~D[2026-07-11])
    end

    test "lapsed?/2 is true for an unanswered request dated before today" do
      kid = kid_fixture()
      reward = reward_fixture(kid)
      {:ok, r} = Rewards.request_redemption(kid, reward, la(~D[2026-07-10], ~T[08:00:00]))

      refute Rewards.lapsed?(r, ~D[2026-07-10])
      assert Rewards.lapsed?(r, ~D[2026-07-11])
    end

    test "approved?/1, reversed?/1, declined?/1 reflect the markers" do
      kid = kid_fixture()
      reward = reward_fixture(kid, %{repeatable: false})
      {:ok, approved} = Rewards.direct_redeem(kid, reward, 100, la(~D[2026-07-10], ~T[08:00:00]))

      assert Rewards.approved?(approved)
      refute Rewards.reversed?(approved)
      refute Rewards.declined?(approved)

      {:ok, reversed} = Rewards.reverse_redemption(approved, la(~D[2026-07-11], ~T[08:00:00]))
      refute Rewards.approved?(reversed)
      assert Rewards.reversed?(reversed)

      reward2 = reward_fixture(kid)
      {:ok, pending} = Rewards.request_redemption(kid, reward2, la(~D[2026-07-10], ~T[08:00:00]))
      {:ok, declined} = Rewards.decline_redemption(pending, la(~D[2026-07-10], ~T[09:00:00]))
      assert Rewards.declined?(declined)
    end
  end

  describe "contribution is marker-first (D59)" do
    test "reversed -> 0, approved -> -points, pending/declined/lapsed -> 0" do
      kid = kid_fixture()

      reward = reward_fixture(kid, %{points: 25, repeatable: false})
      {:ok, approved} = Rewards.direct_redeem(kid, reward, 100, la(~D[2026-07-10], ~T[08:00:00]))
      assert Rewards.redemption_contribution(approved) == -25

      {:ok, reversed} = Rewards.reverse_redemption(approved, la(~D[2026-07-11], ~T[08:00:00]))
      assert Rewards.redemption_contribution(reversed) == 0

      reward2 = reward_fixture(kid, %{points: 25})
      {:ok, pending} = Rewards.request_redemption(kid, reward2, la(~D[2026-07-10], ~T[08:00:00]))
      assert Rewards.redemption_contribution(pending) == 0

      {:ok, declined} = Rewards.decline_redemption(pending, la(~D[2026-07-10], ~T[09:00:00]))
      assert Rewards.redemption_contribution(declined) == 0

      reward3 = reward_fixture(kid, %{points: 25})
      {:ok, lapsed} = Rewards.request_redemption(kid, reward3, la(~D[2026-07-10], ~T[08:00:00]))
      assert Rewards.redemption_contribution(lapsed) == 0
    end
  end

  describe "price snapshot (D60)" do
    test "redemptions.points is taken at request time and never moves when the reward's price changes later" do
      kid = kid_fixture()
      reward = reward_fixture(kid, %{points: 40})

      {:ok, requested} = Rewards.request_redemption(kid, reward, la(~D[2026-07-10], ~T[08:00:00]))

      {:ok, _approved} =
        Rewards.approve_redemption(requested, 100, la(~D[2026-07-10], ~T[09:00:00]))

      {:ok, _repriced} = Rewards.update_reward(reward, kid, %{points: 999})

      unchanged = Rewards.get_redemption!(requested.id)
      assert unchanged.points == 40
      assert Rewards.redemption_contribution(unchanged) == -40
    end

    test "direct_redeem/4 snapshots at redeem time" do
      kid = kid_fixture()
      reward = reward_fixture(kid, %{points: 15})

      {:ok, redemption} =
        Rewards.direct_redeem(kid, reward, 100, la(~D[2026-07-10], ~T[08:00:00]))

      {:ok, _repriced} = Rewards.update_reward(reward, kid, %{points: 999})

      assert Rewards.get_redemption!(redemption.id).points == 15
    end
  end

  describe "no reward-name snapshot (D60, D68)" do
    test "renaming a reward changes how its past redemptions read; archiving keeps them joinable" do
      kid = kid_fixture()
      reward = reward_fixture(kid, %{name: "Movie Night"})

      {:ok, redemption} =
        Rewards.direct_redeem(kid, reward, 100, la(~D[2026-07-10], ~T[08:00:00]))

      {:ok, _renamed} = Rewards.update_reward(reward, kid, %{name: "Cinema Trip"})
      assert Rewards.get_reward!(redemption.reward_id).name == "Cinema Trip"

      {:ok, _archived} = Rewards.archive_reward(reward, la(~D[2026-07-11], ~T[08:00:00]))
      joined = Rewards.get_reward!(redemption.reward_id)
      assert joined.id == reward.id
      assert joined.retired_at
    end
  end

  describe "availability — one-time, per kid, forever (D62)" do
    test "consumed for this kid on any later day; a sibling's availability is untouched" do
      kid = kid_fixture()
      other = sibling()
      reward = reward_fixture(nil, %{repeatable: false, points: 10})

      assert Rewards.available?(reward, kid.id, ~D[2026-07-10])

      {:ok, _} = Rewards.direct_redeem(kid, reward, 100, la(~D[2026-07-10], ~T[08:00:00]))

      refute Rewards.available?(reward, kid.id, ~D[2026-07-10])
      refute Rewards.available?(reward, kid.id, ~D[2026-08-01])
      assert Rewards.available?(reward, other.id, ~D[2026-07-10])
    end
  end

  describe "availability — repeatable, per kid, one local day (D62)" do
    test "on cooldown only for an approval dated today; available again the next local date" do
      kid = kid_fixture()
      reward = reward_fixture(kid, %{repeatable: true, points: 10})

      {:ok, _} = Rewards.direct_redeem(kid, reward, 100, la(~D[2026-07-10], ~T[08:00:00]))

      refute Rewards.available?(reward, kid.id, ~D[2026-07-10])
      assert Rewards.available?(reward, kid.id, ~D[2026-07-11])
    end
  end

  describe "reversal restores availability for free (D62, SC-8)" do
    test "a one-time redemption returns to the kid's catalog once reversed" do
      kid = kid_fixture()
      reward = reward_fixture(kid, %{repeatable: false, points: 10})

      {:ok, redemption} =
        Rewards.direct_redeem(kid, reward, 100, la(~D[2026-07-10], ~T[08:00:00]))

      refute Rewards.available?(reward, kid.id, ~D[2026-07-10])

      {:ok, _} = Rewards.reverse_redemption(redemption, la(~D[2026-07-11], ~T[08:00:00]))
      assert Rewards.available?(reward, kid.id, ~D[2026-07-11])
    end

    test "a repeatable redemption's same-day cooldown clears once reversed" do
      kid = kid_fixture()
      reward = reward_fixture(kid, %{repeatable: true, points: 10})

      {:ok, redemption} =
        Rewards.direct_redeem(kid, reward, 100, la(~D[2026-07-10], ~T[08:00:00]))

      refute Rewards.available?(reward, kid.id, ~D[2026-07-10])

      {:ok, _} = Rewards.reverse_redemption(redemption, la(~D[2026-07-10], ~T[10:00:00]))
      assert Rewards.available?(reward, kid.id, ~D[2026-07-10])
    end
  end

  describe "pending requests consume and contribute nothing (D62, D63)" do
    test "leaves availability and balance untouched; two kids may both hold one for the same reward" do
      kid = kid_fixture()
      other = sibling()
      reward = reward_fixture(nil, %{repeatable: false, points: 10})

      {:ok, _} = Rewards.request_redemption(kid, reward, la(~D[2026-07-10], ~T[08:00:00]))
      {:ok, _} = Rewards.request_redemption(other, reward, la(~D[2026-07-10], ~T[08:05:00]))

      assert Rewards.available?(reward, kid.id, ~D[2026-07-10])
      assert Rewards.available?(reward, other.id, ~D[2026-07-10])
      assert Rewards.spend_totals_by_kid(~D[2026-07-10]) == %{}
    end
  end

  describe "affordability is strict on both legs, no override (D63)" do
    test "direct_redeem/4 refuses an unaffordable spend" do
      kid = kid_fixture()
      reward = reward_fixture(kid, %{points: 50})

      assert {:error, :unaffordable} =
               Rewards.direct_redeem(kid, reward, 49, la(~D[2026-07-10], ~T[08:00:00]))

      assert Rewards.spend_totals_by_kid(~D[2026-07-10]) == %{}
    end

    test "direct_redeem/4 refuses against a negative true balance" do
      kid = kid_fixture()
      reward = reward_fixture(kid, %{points: 1})

      assert {:error, :unaffordable} =
               Rewards.direct_redeem(kid, reward, -20, la(~D[2026-07-10], ~T[08:00:00]))
    end

    test "direct_redeem/4 succeeds at exactly the reward's price" do
      kid = kid_fixture()
      reward = reward_fixture(kid, %{points: 50})

      assert {:ok, _} = Rewards.direct_redeem(kid, reward, 50, la(~D[2026-07-10], ~T[08:00:00]))
    end
  end

  describe "approval re-validates affordability and availability, naming the failed check (D62, D63)" do
    test "refuses on affordability, leaving the request pending" do
      kid = kid_fixture()
      reward = reward_fixture(kid, %{points: 50})
      {:ok, pending} = Rewards.request_redemption(kid, reward, la(~D[2026-07-10], ~T[08:00:00]))

      assert {:error, :unaffordable} =
               Rewards.approve_redemption(pending, 10, la(~D[2026-07-10], ~T[09:00:00]))

      refute Rewards.approved?(Rewards.get_redemption!(pending.id))
    end

    test "catches the same-kid interleaving: a direct-redeem lands between ask and answer" do
      kid = kid_fixture()
      reward = reward_fixture(kid, %{points: 10, repeatable: false})

      {:ok, pending} = Rewards.request_redemption(kid, reward, la(~D[2026-07-10], ~T[08:00:00]))
      {:ok, _direct} = Rewards.direct_redeem(kid, reward, 100, la(~D[2026-07-10], ~T[08:30:00]))

      assert {:error, :unavailable} =
               Rewards.approve_redemption(pending, 100, la(~D[2026-07-10], ~T[09:00:00]))
    end

    test "succeeds when both checks pass" do
      kid = kid_fixture()
      reward = reward_fixture(kid, %{points: 10})
      {:ok, pending} = Rewards.request_redemption(kid, reward, la(~D[2026-07-10], ~T[08:00:00]))

      assert {:ok, approved} =
               Rewards.approve_redemption(pending, 100, la(~D[2026-07-10], ~T[09:00:00]))

      assert Rewards.approved?(approved)
    end
  end

  describe "write paths refuse to act on the wrong state (AC-6 integrity)" do
    test "approve_redemption/3 refuses a request already declined" do
      kid = kid_fixture()
      reward = reward_fixture(kid, %{points: 10})
      {:ok, pending} = Rewards.request_redemption(kid, reward, la(~D[2026-07-10], ~T[08:00:00]))
      {:ok, declined} = Rewards.decline_redemption(pending, la(~D[2026-07-10], ~T[09:00:00]))

      assert {:error, :not_open} =
               Rewards.approve_redemption(declined, 100, la(~D[2026-07-10], ~T[10:00:00]))

      refute Rewards.get_redemption!(declined.id).approved_at
    end

    test "decline_redemption/2 refuses a request already approved" do
      kid = kid_fixture()
      reward = reward_fixture(kid, %{points: 10})
      {:ok, pending} = Rewards.request_redemption(kid, reward, la(~D[2026-07-10], ~T[08:00:00]))
      {:ok, approved} = Rewards.approve_redemption(pending, 100, la(~D[2026-07-10], ~T[09:00:00]))

      assert {:error, :not_open} =
               Rewards.decline_redemption(approved, la(~D[2026-07-10], ~T[10:00:00]))

      refute Rewards.get_redemption!(approved.id).declined_at
    end

    test "reverse_redemption/2 refuses a redemption that was never approved" do
      kid = kid_fixture()
      reward = reward_fixture(kid, %{points: 10})
      {:ok, pending} = Rewards.request_redemption(kid, reward, la(~D[2026-07-10], ~T[08:00:00]))

      assert {:error, :not_approved} =
               Rewards.reverse_redemption(pending, la(~D[2026-07-10], ~T[09:00:00]))
    end

    test "reverse_redemption/2 refuses a redemption already reversed" do
      kid = kid_fixture()
      reward = reward_fixture(kid, %{points: 10, repeatable: false})
      {:ok, approved} = Rewards.direct_redeem(kid, reward, 100, la(~D[2026-07-10], ~T[08:00:00]))
      {:ok, reversed} = Rewards.reverse_redemption(approved, la(~D[2026-07-11], ~T[08:00:00]))

      assert {:error, :not_approved} =
               Rewards.reverse_redemption(reversed, la(~D[2026-07-12], ~T[08:00:00]))
    end

    test "approve_redemption/3 refuses a request that has lapsed" do
      kid = kid_fixture()
      reward = reward_fixture(kid, %{points: 10})
      {:ok, pending} = Rewards.request_redemption(kid, reward, la(~D[2026-07-10], ~T[08:00:00]))

      assert {:error, :not_open} =
               Rewards.approve_redemption(pending, 100, la(~D[2026-07-11], ~T[08:00:00]))

      refute Rewards.get_redemption!(pending.id).approved_at
    end

    test "decline_redemption/2 refuses a request that has lapsed" do
      kid = kid_fixture()
      reward = reward_fixture(kid, %{points: 10})
      {:ok, pending} = Rewards.request_redemption(kid, reward, la(~D[2026-07-10], ~T[08:00:00]))

      assert {:error, :not_open} =
               Rewards.decline_redemption(pending, la(~D[2026-07-11], ~T[08:00:00]))

      refute Rewards.get_redemption!(pending.id).declined_at
    end
  end

  describe "live updates (D71)" do
    test "subscribe/0 receives a payload-free :rewards_changed on every successful write" do
      kid = kid_fixture()
      Rewards.subscribe()

      {:ok, reward} = Rewards.create_reward(kid, %{name: "A", icon: "🎁", points: 5})
      assert_receive :rewards_changed

      {:ok, reward} = Rewards.update_reward(reward, kid, %{points: 6})
      assert_receive :rewards_changed

      {:ok, requested} = Rewards.request_redemption(kid, reward, la(~D[2026-07-10], ~T[08:00:00]))
      assert_receive :rewards_changed

      {:ok, approved} =
        Rewards.approve_redemption(requested, 100, la(~D[2026-07-10], ~T[09:00:00]))

      assert_receive :rewards_changed

      {:ok, _} = Rewards.reverse_redemption(approved, la(~D[2026-07-11], ~T[08:00:00]))
      assert_receive :rewards_changed

      {:ok, reward2} = Rewards.create_reward(kid, %{name: "B", icon: "🎁", points: 5})
      assert_receive :rewards_changed

      {:ok, pending2} = Rewards.request_redemption(kid, reward2, la(~D[2026-07-11], ~T[08:00:00]))
      assert_receive :rewards_changed

      {:ok, _} = Rewards.decline_redemption(pending2, la(~D[2026-07-11], ~T[09:00:00]))
      assert_receive :rewards_changed

      {:ok, reward3} = Rewards.create_reward(kid, %{name: "C", icon: "🎁", points: 5})
      assert_receive :rewards_changed

      {:ok, _} = Rewards.direct_redeem(kid, reward3, 100, la(~D[2026-07-11], ~T[08:00:00]))
      assert_receive :rewards_changed

      {:ok, _} = Rewards.archive_reward(reward3, la(~D[2026-07-11], ~T[10:00:00]))
      assert_receive :rewards_changed
    end
  end
end
