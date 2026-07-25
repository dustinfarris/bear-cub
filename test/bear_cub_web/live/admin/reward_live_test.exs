defmodule BearCubWeb.Admin.RewardLiveTest do
  use BearCubWeb.ConnCase

  import Phoenix.LiveViewTest
  import BearCub.ChoresFixtures
  import BearCub.RewardsFixtures

  alias BearCub.LocalTime
  alias BearCub.Points
  alias BearCub.Rewards

  defp ordered_ids(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("id")
  end

  setup do
    kid_a = kid_fixture(%{name: "Kid A", color: "#f59e0b", position: 0})
    kid_b = kid_fixture(%{name: "Kid B", color: "#0ea5e9", position: 1})
    %{kid_a: kid_a, kid_b: kid_b}
  end

  describe "index" do
    test "lists the catalog in position order with icon, name, price, repeatable, and audience",
         %{conn: conn, kid_a: kid_a} do
      family = reward_fixture(nil, %{name: "Movie Night", icon: "🎬", points: 30})
      mine = reward_fixture(kid_a, %{name: "Bike", icon: "🚲", points: 500, repeatable: false})

      {:ok, view, _html} = live(conn, ~p"/admin/rewards")

      assert ordered_ids(render(view), "#rewards li[id]") == [
               "reward-#{family.id}",
               "reward-#{mine.id}"
             ]

      assert has_element?(view, "#reward-#{family.id}", "🎬")
      assert has_element?(view, "#reward-#{family.id}", "Movie Night")
      assert has_element?(view, "#reward-#{family.id}", "30")
      assert has_element?(view, "#reward-#{family.id}", "Anyone")

      assert has_element?(view, "#reward-#{mine.id}", "Bike")
      assert has_element?(view, "#reward-#{mine.id}", "Kid A")
      assert has_element?(view, "#reward-#{mine.id}", "One-time")
    end

    test "▼ swaps the reward with the one below", %{conn: conn} do
      first = reward_fixture(nil, %{name: "First", icon: "1️⃣"})
      second = reward_fixture(nil, %{name: "Second", icon: "2️⃣"})

      {:ok, view, _html} = live(conn, ~p"/admin/rewards")

      view |> element("#move-reward-down-#{first.id}") |> render_click()

      assert Rewards.list_all_rewards() |> Enum.map(& &1.id) == [second.id, first.id]

      assert ordered_ids(render(view), "#rewards li[id]") == [
               "reward-#{second.id}",
               "reward-#{first.id}"
             ]
    end

    test "▲ on the top reward is a harmless no-op", %{conn: conn} do
      only = reward_fixture(nil, %{name: "Only", icon: "🌟"})

      {:ok, view, _html} = live(conn, ~p"/admin/rewards")

      view |> element("#move-reward-up-#{only.id}") |> render_click()

      assert has_element?(view, "#reward-#{only.id}")
    end

    test "archive hides the reward from the catalog while the row and its redemptions survive",
         %{conn: conn, kid_a: kid_a} do
      reward = reward_fixture(kid_a, %{name: "Bike", icon: "🚲"})
      now = LocalTime.now()
      {:ok, redemption} = Rewards.direct_redeem(kid_a, reward, 1000, now)

      {:ok, view, _html} = live(conn, ~p"/admin/rewards")

      view |> element("#archive-reward-#{reward.id}") |> render_click()

      refute has_element?(view, "#reward-#{reward.id}")
      assert Rewards.get_reward!(reward.id).retired_at
      assert Rewards.get_redemption!(redemption.id).id == redemption.id
    end

    test "rewards created elsewhere appear without refresh", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/rewards")

      {:ok, reward} =
        Rewards.create_reward(nil, %{name: "Water Balloon Fight", icon: "💧", points: 10})

      assert has_element?(view, "#reward-#{reward.id}")
    end
  end

  describe "direct-redeem" do
    test "opens a kid picker showing each kid's true signed balance, negative included",
         %{conn: conn, kid_a: kid_a} do
      reward = reward_fixture(nil, %{name: "Bike", icon: "🚲", points: 10})
      # extra_contribution/2 is failed_at-first: once failed, the row
      # contributes -chore.points regardless of the earlier completion —
      # a clean, deterministic negative balance with no routine bonus involved.
      {:ok, extra} = BearCub.Chores.create_chore(kid_a, %{name: "X", icon: "🪥", points: 5})
      {:ok, _} = BearCub.Chores.complete_chore(extra, LocalTime.now(), "admin")
      {:ok, _} = BearCub.Chores.fail_chore(extra, LocalTime.now())

      today = DateTime.to_date(LocalTime.now())
      balance = Points.balance(kid_a, today)
      assert balance < 0

      {:ok, view, _html} = live(conn, ~p"/admin/rewards")

      refute has_element?(view, "#redeem-picker-#{reward.id}")

      view |> element("#redeem-reward-#{reward.id}") |> render_click()

      assert has_element?(view, "#redeem-picker-#{reward.id}")
      assert has_element?(view, "#redeem-picker-#{reward.id}", "Kid A")
      assert has_element?(view, "#redeem-picker-#{reward.id}", Integer.to_string(balance))
    end

    test "is data-confirm guarded before the spend lands", %{conn: conn, kid_a: kid_a} do
      reward = reward_fixture(nil, %{name: "Bike", icon: "🚲", points: 10})

      {:ok, view, _html} = live(conn, ~p"/admin/rewards")
      view |> element("#redeem-reward-#{reward.id}") |> render_click()

      html = view |> element("#confirm-redeem-#{reward.id}-#{kid_a.id}") |> render()
      assert html =~ "data-confirm"
    end

    test "a successful direct-redeem lowers the kid's balance and drops live on the connected kiosk without a reload",
         %{conn: conn, kid_a: kid_a} do
      reward = reward_fixture(nil, %{name: "Bike", icon: "🚲", points: 10})
      # an extra (routine: nil), so the full chore.points value counts —
      # a routine chore only ever contributes the flat routine bonus R,
      # regardless of its own points (Chores.routine_day_contribution/3).
      earned = chore_fixture(kid_a, %{points: 50, routine: nil})
      {:ok, _} = BearCub.Chores.complete_chore(earned, LocalTime.now(), "admin")

      today = DateTime.to_date(LocalTime.now())
      before_balance = Points.balance(kid_a, today)

      {:ok, kiosk, _} = live(Phoenix.ConnTest.build_conn(), ~p"/")
      {:ok, view, _html} = live(conn, ~p"/admin/rewards")

      view |> element("#redeem-reward-#{reward.id}") |> render_click()
      view |> element("#confirm-redeem-#{reward.id}-#{kid_a.id}") |> render_click()

      assert Points.balance(kid_a, today) == before_balance - reward.points

      assert has_element?(
               kiosk,
               "#points-badge-#{kid_a.id}",
               Integer.to_string(before_balance - reward.points)
             )
    end

    test "refuses an unaffordable kid, naming the check", %{conn: conn, kid_a: kid_a} do
      reward = reward_fixture(nil, %{name: "Bike", icon: "🚲", points: 100_000})

      {:ok, view, _html} = live(conn, ~p"/admin/rewards")
      view |> element("#redeem-reward-#{reward.id}") |> render_click()
      view |> element("#confirm-redeem-#{reward.id}-#{kid_a.id}") |> render_click()

      assert has_element?(view, "#flash-error", "afford")
      assert Rewards.list_rewards(kid_a, DateTime.to_date(LocalTime.now())) == [reward]
    end

    test "the picker for a kid-scoped reward shows only the kid it's offered to",
         %{conn: conn, kid_a: kid_a, kid_b: kid_b} do
      reward = reward_fixture(kid_a, %{name: "Bike", icon: "🚲", points: 10})

      {:ok, view, _html} = live(conn, ~p"/admin/rewards")
      view |> element("#redeem-reward-#{reward.id}") |> render_click()

      assert has_element?(view, "#redeem-reward-#{reward.id}-kid-#{kid_a.id}")
      refute has_element?(view, "#redeem-reward-#{reward.id}-kid-#{kid_b.id}")
    end

    test "refuses a kid who already claimed a one-time reward, naming the check",
         %{conn: conn, kid_a: kid_a} do
      reward = reward_fixture(nil, %{name: "Bike", icon: "🚲", points: 10, repeatable: false})
      {:ok, _} = Rewards.direct_redeem(kid_a, reward, 1000, LocalTime.now())

      {:ok, view, _html} = live(conn, ~p"/admin/rewards")
      view |> element("#redeem-reward-#{reward.id}") |> render_click()
      view |> element("#confirm-redeem-#{reward.id}-#{kid_a.id}") |> render_click()

      assert has_element?(view, "#flash-error", "claimed")
    end
  end

  describe "form" do
    test "creates a reward offered to Anyone with the emoji default persisted",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/rewards/new")

      assert view |> element("#reward_icon") |> render() =~ ~s(value="🎁")

      view
      |> form("#reward-form", reward: %{name: "Movie Night", points: "30"})
      |> render_submit()

      assert_redirect(view, ~p"/admin/rewards")

      [created] = Rewards.list_all_rewards()
      assert created.name == "Movie Night"
      assert created.icon == "🎁"
      assert created.points == 30
      assert created.repeatable == true
      assert created.kid_id == nil
    end

    test "creates a reward with repeatable unchecked and a custom icon", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/rewards/new")

      view
      |> form("#reward-form",
        reward: %{name: "Bike", icon: "🚲", points: "500", repeatable: "false"}
      )
      |> render_submit()

      assert_redirect(view, ~p"/admin/rewards")

      [created] = Rewards.list_all_rewards()
      assert created.icon == "🚲"
      assert created.repeatable == false
    end

    test "creates a reward offered to a specific kid", %{conn: conn, kid_a: kid_a} do
      {:ok, view, _html} = live(conn, ~p"/admin/rewards/new")

      view
      |> form("#reward-form", reward: %{name: "Bike", points: "500", kid_id: kid_a.id})
      |> render_submit()

      assert_redirect(view, ~p"/admin/rewards")

      [created] = Rewards.list_all_rewards()
      assert created.kid_id == kid_a.id
    end

    test "shows validation errors without saving", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/rewards/new")

      html =
        view
        |> form("#reward-form", reward: %{name: "", points: "10"})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert Rewards.list_all_rewards() == []
    end

    test "edits a reward's fields and audience", %{conn: conn, kid_a: kid_a} do
      reward = reward_fixture(nil, %{name: "Movie Night", points: 30})

      {:ok, view, _html} = live(conn, ~p"/admin/rewards/#{reward}/edit")

      view
      |> form("#reward-form", reward: %{name: "Family Movie Night", kid_id: kid_a.id})
      |> render_submit()

      assert_redirect(view, ~p"/admin/rewards")

      updated = Rewards.get_reward!(reward.id)
      assert updated.name == "Family Movie Night"
      assert updated.kid_id == kid_a.id
    end
  end
end
