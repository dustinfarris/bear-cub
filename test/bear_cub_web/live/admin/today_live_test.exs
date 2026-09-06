defmodule BearCubWeb.Admin.TodayLiveTest do
  use BearCubWeb.ConnCase

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import BearCub.ChoresFixtures

  alias BearCub.Chores
  alias BearCub.Chores.Completion
  alias BearCub.LocalTime
  alias BearCub.Points
  alias BearCub.Repo
  alias BearCub.Routines

  # No clock mocking: the expected active routine comes from the same
  # pure functions the view uses (accepted rare window-edge flake).
  defp active_routine do
    {_state, active} = Routines.current(LocalTime.now())
    active
  end

  # For tests that also mount the kiosk view: the kiosk's own night/day
  # state must agree with whichever routine `active_routine/0` already
  # picked for this test's fixtures, regardless of real wall-clock time
  # (tests must pin the local datetime, never inherit the real one — see
  # docs/learnings.org). Mirrors the kiosk tests' morning_active/0.
  defp pin_active_routine(active) do
    inactive = Routines.other(active)

    Application.put_env(:bear_cub, :routine_windows, [
      {active, {~T[00:00:00], ~T[23:59:59]}},
      {inactive, {~T[23:59:59], ~T[23:59:59]}}
    ])
  end

  setup do
    kid_a = kid_fixture(%{name: "Kid A", color: "#f59e0b", position: 0})
    kid_b = kid_fixture(%{name: "Kid B", color: "#0ea5e9", position: 1})
    active = active_routine()
    inactive = Routines.other(active)

    a_active =
      chore_fixture(kid_a, %{name: "Brush Teeth", icon: "🪥", routine: Atom.to_string(active)})

    a_inactive =
      chore_fixture(kid_a, %{name: "Pajamas On", icon: "🌙", routine: Atom.to_string(inactive)})

    b_active =
      chore_fixture(kid_b, %{name: "Feed Dog", icon: "🐶", routine: Atom.to_string(active)})

    %{
      kid_a: kid_a,
      kid_b: kid_b,
      active: active,
      inactive: inactive,
      a_active: a_active,
      a_inactive: a_inactive,
      b_active: b_active
    }
  end

  test "stacks both kid cards, active routine expanded, the other collapsed to its count",
       %{conn: conn, kid_a: kid_a, kid_b: kid_b} = ctx do
    {:ok, view, _html} = live(conn, ~p"/admin")

    assert has_element?(view, "#today-kid-#{kid_a.id}", "Kid A")
    assert has_element?(view, "#today-kid-#{kid_b.id}", "Kid B")

    # active routine expanded with its progress count
    assert has_element?(view, "#today-chore-#{ctx.a_active.id}")
    assert has_element?(view, "#progress-#{kid_a.id}-#{ctx.active}", "0/1")

    # inactive routine collapsed: header + count only
    refute has_element?(view, "#today-chore-#{ctx.a_inactive.id}")
    assert has_element?(view, "#progress-#{kid_a.id}-#{ctx.inactive}", "0/1")
  end

  test "the active routine section renders first", %{conn: conn, kid_a: kid_a} = ctx do
    {:ok, view, _html} = live(conn, ~p"/admin")

    sections =
      render(view)
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#today-kid-#{kid_a.id} [id^='section-']")
      |> LazyHTML.attribute("id")

    assert sections == [
             "section-#{kid_a.id}-#{ctx.active}",
             "section-#{kid_a.id}-#{ctx.inactive}"
           ]
  end

  test "tapping a chore completes it on the kid's behalf; the kiosk follows",
       %{conn: conn} = ctx do
    original_windows = Application.fetch_env!(:bear_cub, :routine_windows)
    on_exit(fn -> Application.put_env(:bear_cub, :routine_windows, original_windows) end)
    pin_active_routine(ctx.active)

    {:ok, kiosk, _} = live(Phoenix.ConnTest.build_conn(), ~p"/")
    {:ok, view, _html} = live(conn, ~p"/admin")

    view |> element("#today-chore-#{ctx.a_active.id}") |> render_click()

    assert has_element?(view, "#today-chore-#{ctx.a_active.id}[data-done]")

    completion = Repo.one!(from c in Completion, where: c.chore_id == ^ctx.a_active.id)
    assert completion.source == "admin"

    # kid_a's only active-routine chore is now done — the kiosk enters the
    # collapse-delay (story 07) before showing the reveal band rather than
    # a done row; simulate the timer firing rather than sleeping in the test
    send(kiosk.pid, {:collapse_ready, ctx.kid_a.id})
    assert has_element?(kiosk, "#band-#{ctx.kid_a.id}")
  end

  test "tapping a done chore undoes it", %{conn: conn} = ctx do
    {:ok, view, _html} = live(conn, ~p"/admin")

    view |> element("#today-chore-#{ctx.a_active.id}") |> render_click()
    view |> element("#today-chore-#{ctx.a_active.id}") |> render_click()

    refute has_element?(view, "#today-chore-#{ctx.a_active.id}[data-done]")

    completion = Repo.one!(from c in Completion, where: c.chore_id == ^ctx.a_active.id)
    refute is_nil(completion.undone_at)
  end

  test "a collapsed section expands on tap and its chores are editable",
       %{conn: conn, kid_a: kid_a} = ctx do
    {:ok, view, _html} = live(conn, ~p"/admin")

    view |> element("#section-#{kid_a.id}-#{ctx.inactive}") |> render_click()

    assert has_element?(view, "#today-chore-#{ctx.a_inactive.id}")

    view |> element("#today-chore-#{ctx.a_inactive.id}") |> render_click()

    assert has_element?(view, "#today-chore-#{ctx.a_inactive.id}[data-done]")
    assert has_element?(view, "#progress-#{kid_a.id}-#{ctx.inactive}", "1/1")
  end

  describe "approval queue and reversal (Story 06, D69, D62, D63, D71)" do
    import BearCub.RewardsFixtures

    alias BearCub.Rewards

    setup %{active: active} do
      original_windows = Application.fetch_env!(:bear_cub, :routine_windows)
      on_exit(fn -> Application.put_env(:bear_cub, :routine_windows, original_windows) end)
      pin_active_routine(active)
      :ok
    end

    defp fail_for_penalty(kid, points) do
      chore = chore_fixture(kid, %{name: "Wash Car", icon: "🚗", routine: nil, points: points})
      now = LocalTime.now()
      {:ok, _} = Chores.complete_chore(chore, now, "kiosk")
      {:ok, _} = Chores.fail_chore(chore, now)
      :ok
    end

    defp earn(kid, points) do
      extra = chore_fixture(kid, %{name: "Mow Lawn", icon: "🌱", routine: nil, points: points})
      {:ok, _} = Chores.complete_chore(extra, LocalTime.now(), "kiosk")
      :ok
    end

    test "a pending request shows the reward's icon, name, and snapshot price only — no per-request balance line",
         %{conn: conn, kid_a: kid_a} do
      reward = reward_fixture(kid_a, %{name: "Movie Night", icon: "🎬", points: 30})
      {:ok, request} = Rewards.request_redemption(kid_a, reward, LocalTime.now())
      fail_for_penalty(kid_a, 40)

      {:ok, view, _html} = live(conn, ~p"/admin")

      assert has_element?(view, "#request-#{request.id}", "🎬")
      assert has_element?(view, "#request-#{request.id}", "Movie Night")
      assert has_element?(view, "#request-#{request.id}", "30")
      # the balance moved up to the kid's header band (D64, placement advisory)
      refute has_element?(view, "#request-#{request.id}", "-40")
    end

    test "the kid's header band shows the true signed balance, negative included, whether or not the kid has requests, extras, or redemptions (D64, placement advisory)",
         %{conn: conn, kid_a: kid_a, kid_b: kid_b} do
      fail_for_penalty(kid_a, 40)

      {:ok, view, _html} = live(conn, ~p"/admin")

      assert has_element?(view, "#today-balance-#{kid_a.id}", "★")
      assert has_element?(view, "#today-balance-#{kid_a.id}", "-40")
      # kid_b has no requests, extras, or redemptions today — balance still renders
      assert has_element?(view, "#today-balance-#{kid_b.id}", "★")
      assert has_element?(view, "#today-balance-#{kid_b.id}", "0")
    end

    test "the queue never shows a request left unanswered from an earlier day (SC-6, D61, D73)",
         %{conn: conn, kid_a: kid_a} do
      reward = reward_fixture(kid_a)
      {:ok, lapsed} = Rewards.request_redemption(kid_a, reward, la(~D[2026-07-09], ~T[08:00:00]))

      {:ok, view, _html} = live(conn, ~p"/admin")

      refute has_element?(view, "#request-#{lapsed.id}")
    end

    test "approve is data-confirm guarded, and on confirmation lowers the kid's balance and clears the request",
         %{conn: conn, kid_a: kid_a} do
      earn(kid_a, 50)
      reward = reward_fixture(kid_a, %{points: 20})
      {:ok, request} = Rewards.request_redemption(kid_a, reward, LocalTime.now())

      {:ok, view, _html} = live(conn, ~p"/admin")

      assert has_element?(view, "#approve-request-#{request.id}[data-confirm]")
      # worded Redeem, matching the direct-redeem control it mirrors (D53, D69)
      confirm_html = view |> element("#approve-request-#{request.id}") |> render()
      assert confirm_html =~ "data-confirm=\"Redeem"
      refute confirm_html =~ "Give"

      view |> element("#approve-request-#{request.id}") |> render_click()

      refute has_element?(view, "#request-#{request.id}")
      approved = Rewards.get_redemption!(request.id)
      assert approved.approved_at
      assert Points.balance(kid_a, DateTime.to_date(LocalTime.now())) == 30
    end

    test "approving keeps the balance down (it stays lowered, SC-3, SC-7)",
         %{conn: conn, kid_a: kid_a} do
      earn(kid_a, 50)
      reward = reward_fixture(kid_a, %{points: 20})
      {:ok, request} = Rewards.request_redemption(kid_a, reward, LocalTime.now())
      {:ok, view, _html} = live(conn, ~p"/admin")

      view |> element("#approve-request-#{request.id}") |> render_click()
      {:ok, view, _html} = live(conn, ~p"/admin")

      assert Points.balance(kid_a, DateTime.to_date(LocalTime.now())) == 30
      refute has_element?(view, "#request-#{request.id}")
    end

    test "decline carries no confirmation, costs nothing, and removes the request from the queue",
         %{conn: conn, kid_a: kid_a} do
      reward = reward_fixture(kid_a, %{points: 20})
      {:ok, request} = Rewards.request_redemption(kid_a, reward, LocalTime.now())

      {:ok, view, _html} = live(conn, ~p"/admin")

      refute has_element?(view, "#decline-request-#{request.id}[data-confirm]")

      view |> element("#decline-request-#{request.id}") |> render_click()

      refute has_element?(view, "#request-#{request.id}")
      declined = Rewards.get_redemption!(request.id)
      assert declined.declined_at
      assert Points.balance(kid_a, DateTime.to_date(LocalTime.now())) == 0
    end

    test "a failed affordability re-check tells the parent and leaves the request pending",
         %{conn: conn, kid_a: kid_a} do
      reward = reward_fixture(kid_a, %{points: 20})
      {:ok, request} = Rewards.request_redemption(kid_a, reward, LocalTime.now())
      fail_for_penalty(kid_a, 30)

      {:ok, view, _html} = live(conn, ~p"/admin")

      view |> element("#approve-request-#{request.id}") |> render_click()

      assert has_element?(view, "#request-#{request.id}")
      assert render(view) =~ "afford"
      refute Rewards.get_redemption!(request.id).approved_at
    end

    test "the same-kid interleaving: a direct-redeem lands between ask and approve, failing the availability check and saying so",
         %{conn: conn, kid_a: kid_a} do
      reward = reward_fixture(kid_a, %{points: 10, repeatable: false})
      {:ok, request} = Rewards.request_redemption(kid_a, reward, LocalTime.now())
      {:ok, _direct} = Rewards.direct_redeem(kid_a, reward, 100, LocalTime.now())

      {:ok, view, _html} = live(conn, ~p"/admin")

      view |> element("#approve-request-#{request.id}") |> render_click()

      assert has_element?(view, "#request-#{request.id}")
      assert render(view) =~ "already claimed"
      refute Rewards.get_redemption!(request.id).approved_at
    end

    test "a reverse control sits beside the day's redemptions, is data-confirm guarded, and restores points and availability",
         %{conn: conn, kid_a: kid_a} do
      reward = reward_fixture(kid_a, %{points: 20, repeatable: false})
      {:ok, redemption} = Rewards.direct_redeem(kid_a, reward, 100, LocalTime.now())

      {:ok, view, _html} = live(conn, ~p"/admin")

      assert has_element?(view, "#reverse-redemption-#{redemption.id}[data-confirm]")
      assert Points.balance(kid_a, DateTime.to_date(LocalTime.now())) == -20

      view |> element("#reverse-redemption-#{redemption.id}") |> render_click()

      reversed = Rewards.get_redemption!(redemption.id)
      assert reversed.reversed_at
      assert Points.balance(kid_a, DateTime.to_date(LocalTime.now())) == 0
      assert Rewards.available?(reward, kid_a.id, DateTime.to_date(LocalTime.now()))
    end

    test "reverse is offered only on today's redemptions, never an earlier day's",
         %{conn: conn, kid_a: kid_a} do
      reward = reward_fixture(kid_a, %{points: 20, repeatable: false})

      {:ok, yesterday} =
        Rewards.direct_redeem(kid_a, reward, 100, la(~D[2026-07-09], ~T[08:00:00]))

      {:ok, view, _html} = live(conn, ~p"/admin")

      refute has_element?(view, "#redemption-#{yesterday.id}")
      refute has_element?(view, "#reverse-redemption-#{yesterday.id}")
    end

    test "cross-surface: a kiosk request appears in the admin queue without a reload",
         %{conn: conn, kid_a: kid_a} do
      earn(kid_a, 10)
      reward = reward_fixture(kid_a, %{name: "Bike", points: 10})

      {:ok, kiosk, _html} = live(Phoenix.ConnTest.build_conn(), ~p"/")
      {:ok, view, _html} = live(conn, ~p"/admin")

      refute has_element?(view, "[id^=request-]")

      kiosk
      |> element("#gift-button-#{kid_a.id}")
      |> render_click()

      kiosk
      |> element("#reward-card-#{reward.id}-#{kid_a.id}")
      |> render_click()

      request = Rewards.get_redemption!(Repo.one!(from(r in Rewards.Redemption, select: r.id)))
      assert has_element?(view, "#request-#{request.id}", "Bike")
    end

    test "cross-surface: a kiosk withdraw drops the request from the admin queue with no parent action (D76)",
         %{conn: conn, kid_a: kid_a} do
      earn(kid_a, 10)
      reward = reward_fixture(kid_a, %{name: "Bike", points: 10})
      {:ok, request} = Rewards.request_redemption(kid_a, reward, LocalTime.now())

      {:ok, kiosk, _html} = live(Phoenix.ConnTest.build_conn(), ~p"/")
      {:ok, view, _html} = live(conn, ~p"/admin")

      assert has_element?(view, "#request-#{request.id}", "Bike")

      kiosk
      |> element("#gift-button-#{kid_a.id}")
      |> render_click()

      kiosk
      |> element("#reward-card-#{reward.id}-#{kid_a.id}")
      |> render_click()

      refute has_element?(view, "#request-#{request.id}")
    end

    test "cross-surface: approving moves the kiosk's points badge and flips the gift button back to the idle glyph",
         %{conn: conn, kid_a: kid_a} do
      earn(kid_a, 20)
      reward = reward_fixture(kid_a, %{points: 15})
      {:ok, request} = Rewards.request_redemption(kid_a, reward, LocalTime.now())

      {:ok, kiosk, _html} = live(Phoenix.ConnTest.build_conn(), ~p"/")
      {:ok, view, _html} = live(conn, ~p"/admin")

      before_points = Points.total(kid_a, DateTime.to_date(LocalTime.now()))
      assert has_element?(kiosk, "#points-badge-#{kid_a.id}", "#{before_points}")
      assert has_element?(kiosk, "#gift-button-#{kid_a.id}", "⏳")

      view |> element("#approve-request-#{request.id}") |> render_click()

      after_points = Points.total(kid_a, DateTime.to_date(LocalTime.now()))
      assert after_points < before_points
      assert has_element?(kiosk, "#points-badge-#{kid_a.id}", "#{after_points}")
      assert has_element?(kiosk, "#gift-button-#{kid_a.id}", "🎁")
    end
  end

  test "kiosk taps appear live in the progress counts (FR-9)",
       %{conn: conn, kid_a: kid_a} = ctx do
    {:ok, view, _html} = live(conn, ~p"/admin")

    {:ok, _} = Chores.complete_chore(ctx.a_active, LocalTime.now(), "kiosk")

    assert has_element?(view, "#progress-#{kid_a.id}-#{ctx.active}", "1/1")
    assert has_element?(view, "#today-chore-#{ctx.a_active.id}[data-done]")
  end

  test "a tap racing a chore delete no-ops (stale row)", %{conn: conn} = ctx do
    {:ok, view, _html} = live(conn, ~p"/admin")

    Repo.delete!(ctx.a_active)

    view |> element("#today-chore-#{ctx.a_active.id}") |> render_click()

    refute has_element?(view, "#today-chore-#{ctx.a_active.id}")
  end

  test "the reset controls are gone (D31)", %{conn: conn, kid_a: kid_a} do
    {:ok, view, _html} = live(conn, ~p"/admin")

    refute has_element?(view, "#reset-kid-#{kid_a.id}")
    refute has_element?(view, "#reset-day")
  end

  describe "fail-on-inspection (Story 05, D40)" do
    test "a fail control is exposed only on a done chore, distinct from the toggle",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/admin")

      refute has_element?(view, "#fail-chore-#{ctx.a_active.id}")

      {:ok, _} = Chores.complete_chore(ctx.a_active, LocalTime.now(), "kiosk")
      {:ok, view, _html} = live(conn, ~p"/admin")

      assert has_element?(view, "#fail-chore-#{ctx.a_active.id}")
    end

    test "tapping fail reverts the chore and stamps a persistent penalty",
         %{conn: conn} = ctx do
      {:ok, _} = Chores.complete_chore(ctx.a_active, LocalTime.now(), "kiosk")
      {:ok, view, _html} = live(conn, ~p"/admin")

      view |> element("#fail-chore-#{ctx.a_active.id}") |> render_click()

      refute has_element?(view, "#today-chore-#{ctx.a_active.id}[data-done]")

      completion = Repo.one!(from c in Completion, where: c.chore_id == ^ctx.a_active.id)
      refute is_nil(completion.undone_at)
      refute is_nil(completion.failed_at)
    end

    test "a fail live-updates the kiosk: the chore reverts and the points badge drops",
         %{conn: conn} = ctx do
      original_windows = Application.fetch_env!(:bear_cub, :routine_windows)
      on_exit(fn -> Application.put_env(:bear_cub, :routine_windows, original_windows) end)
      pin_active_routine(ctx.active)

      {:ok, _} = Chores.complete_chore(ctx.a_active, LocalTime.now(), "kiosk")

      {:ok, kiosk, _html} = live(Phoenix.ConnTest.build_conn(), ~p"/")
      {:ok, view, _html} = live(conn, ~p"/admin")

      before_points = Points.total(ctx.kid_a, DateTime.to_date(LocalTime.now()))
      assert has_element?(kiosk, "#points-badge-#{ctx.kid_a.id}", "#{before_points}")
      # kid_a's only active-routine chore is done, so the kiosk shows the
      # collapsed reveal band rather than the individual chore row
      assert has_element?(kiosk, "#band-#{ctx.kid_a.id}")

      view |> element("#fail-chore-#{ctx.a_active.id}") |> render_click()

      after_points = Points.total(ctx.kid_a, DateTime.to_date(LocalTime.now()))
      assert after_points < before_points
      assert has_element?(kiosk, "#points-badge-#{ctx.kid_a.id}", "#{after_points}")

      # the routine is no longer complete: the band drops and the chore
      # row reappears, reverted to incomplete
      refute has_element?(kiosk, "#band-#{ctx.kid_a.id}")
      refute has_element?(kiosk, "#chore-#{ctx.a_active.id}[data-done]")
    end
  end

  describe "fail confirmation guard + standing flag (Story 09, D53)" do
    test "the fail control carries a data-confirm attribute guarding the tap",
         %{conn: conn} = ctx do
      {:ok, _} = Chores.complete_chore(ctx.a_active, LocalTime.now(), "kiosk")
      {:ok, view, _html} = live(conn, ~p"/admin")

      assert has_element?(view, "#fail-chore-#{ctx.a_active.id}[data-confirm]")
    end

    test "a still-done chore shows only the actionable fail control, never the solid flag",
         %{conn: conn} = ctx do
      {:ok, _} = Chores.complete_chore(ctx.a_active, LocalTime.now(), "kiosk")
      {:ok, view, _html} = live(conn, ~p"/admin")

      assert has_element?(view, "#fail-chore-#{ctx.a_active.id}")
      refute has_element?(view, "#failed-flag-#{ctx.a_active.id}")
    end

    test "a failed chore shows the solid, non-interactive flag instead of the actionable control",
         %{conn: conn} = ctx do
      {:ok, _} = Chores.complete_chore(ctx.a_active, LocalTime.now(), "kiosk")
      {:ok, view, _html} = live(conn, ~p"/admin")

      view |> element("#fail-chore-#{ctx.a_active.id}") |> render_click()

      refute has_element?(view, "#fail-chore-#{ctx.a_active.id}")
      assert has_element?(view, "#failed-flag-#{ctx.a_active.id}")
      refute has_element?(view, "#failed-flag-#{ctx.a_active.id}[phx-click]")
    end

    test "redoing a failed chore keeps the solid flag standing; the actionable control does not return",
         %{conn: conn} = ctx do
      {:ok, _} = Chores.complete_chore(ctx.a_active, LocalTime.now(), "kiosk")
      {:ok, view, _html} = live(conn, ~p"/admin")

      view |> element("#fail-chore-#{ctx.a_active.id}") |> render_click()
      view |> element("#today-chore-#{ctx.a_active.id}") |> render_click()

      assert has_element?(view, "#today-chore-#{ctx.a_active.id}[data-done]")
      assert has_element?(view, "#failed-flag-#{ctx.a_active.id}")
      refute has_element?(view, "#fail-chore-#{ctx.a_active.id}")
    end
  end

  describe "standing row (Story 03, D96)" do
    import BearCub.ChoresFixtures

    setup do
      kid = kid_fixture(%{name: "Kid C", color: "#a855f7", position: 2})
      morning_chore = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})
      evening_chore = chore_fixture(kid, %{name: "Pajamas On", icon: "🌙", routine: "evening"})

      # captured once and reused everywhere below — never a second
      # independent LocalTime.now() call, so a test that spans today's
      # morning and yesterday's evening can't straddle a real midnight
      now = LocalTime.now()
      yesterday = DateTime.to_date(now) |> Date.add(-1)

      %{
        kid: kid,
        morning_chore: morning_chore,
        evening_chore: evening_chore,
        now: now,
        yesterday: yesterday
      }
    end

    test "a kid with no chores at all is in good standing: three solid stars and the verdict text",
         %{conn: conn} do
      loner = kid_fixture(%{name: "Kid D", color: "#22c55e", position: 3})

      {:ok, view, _html} = live(conn, ~p"/admin")

      assert has_element?(view, "#standing-#{loner.id}", "In good standing")

      document = LazyHTML.from_fragment(render(view))
      stars = LazyHTML.query(document, "#standing-#{loner.id} .hero-star-solid")
      assert Enum.count(stars) == 3
    end

    test "not in standing shows the muted verdict plus two chips labelled This morning / Last night",
         %{conn: conn, kid: kid, morning_chore: morning_chore, now: now} do
      {:ok, _} = Chores.complete_chore(morning_chore, now, "kiosk")

      {:ok, view, _html} = live(conn, ~p"/admin")

      assert has_element?(view, "#standing-#{kid.id}", "Not in good standing")
      assert has_element?(view, "#standing-chip-morning-#{kid.id}", "This morning ✓")
      assert has_element?(view, "#standing-chip-evening-#{kid.id}", "Last night ✗")

      # the copy hazard (design): never label the evening half "Evening"
      standing_html = view |> element("#standing-#{kid.id}") |> render()
      refute standing_html =~ "Evening"
    end

    test "a chip shows ✗ for a routine that was completed then failed, even after being redone",
         %{conn: conn, kid: kid, evening_chore: evening_chore, yesterday: yesterday} do
      t1 = la(yesterday, ~T[19:00:00])
      t2 = la(yesterday, ~T[19:30:00])
      t3 = la(yesterday, ~T[20:00:00])

      {:ok, _} = Chores.complete_chore(evening_chore, t1, "kiosk")
      {:ok, _} = Chores.fail_chore(evening_chore, t2)
      {:ok, _} = Chores.complete_chore(evening_chore, t3, "admin")

      {:ok, view, _html} = live(conn, ~p"/admin")

      assert has_element?(view, "#standing-#{kid.id}", "Not in good standing")
      assert has_element?(view, "#standing-chip-evening-#{kid.id}", "Last night ✗")
    end

    test "the standing row sits directly beneath the header and above the routine sections",
         %{conn: conn, kid: kid} do
      {:ok, _view, html} = live(conn, ~p"/admin")

      {header_at, _} = :binary.match(html, kid.name)
      {standing_at, _} = :binary.match(html, "standing-#{kid.id}")
      {section_at, _} = :binary.match(html, "section-#{kid.id}-")

      assert header_at < standing_at
      assert standing_at < section_at
    end
  end

  describe "extras" do
    import BearCub.ChoresFixtures

    defp la(date, time), do: DateTime.new!(date, time, LocalTime.timezone())

    setup %{kid_a: kid_a} do
      outstanding = chore_fixture(kid_a, %{name: "Wash Car", icon: "🚗", routine: nil})
      done_today = chore_fixture(kid_a, %{name: "Water Plants", icon: "🪴", routine: nil})
      retired = chore_fixture(kid_a, %{name: "Rake Leaves", icon: "🍂", routine: nil})

      now = LocalTime.now()
      yesterday = DateTime.to_date(now) |> Date.add(-1)

      {:ok, _} = Chores.complete_chore(done_today, now, "kiosk")
      {:ok, _} = Chores.complete_chore(retired, la(yesterday, ~T[12:00:00]), "kiosk")

      %{outstanding: outstanding, done_today: done_today, retired: retired}
    end

    test "the kid's card lists outstanding and done-today extras; a retired extra never appears",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/admin")

      refute has_element?(view, "#today-chore-#{ctx.outstanding.id}[data-done]")
      assert has_element?(view, "#today-chore-#{ctx.outstanding.id}")
      assert has_element?(view, "#today-chore-#{ctx.done_today.id}[data-done]")
      refute has_element?(view, "#today-chore-#{ctx.retired.id}")
    end

    test "marking an outstanding extra done on the kid's behalf", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/admin")

      view |> element("#today-chore-#{ctx.outstanding.id}") |> render_click()

      assert has_element?(view, "#today-chore-#{ctx.outstanding.id}[data-done]")
      completion = Repo.one!(from c in Completion, where: c.chore_id == ^ctx.outstanding.id)
      assert completion.source == "admin"
    end

    test "unmarking a done-today extra", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/admin")

      view |> element("#today-chore-#{ctx.done_today.id}") |> render_click()

      refute has_element?(view, "#today-chore-#{ctx.done_today.id}[data-done]")
    end
  end

  describe "on-behalf extras toggle reaches the kiosk" do
    import BearCub.ChoresFixtures

    # Pins morning active all day, deterministically — extras only reveal
    # in the kiosk band while the morning window is active (D33).
    defp morning_active do
      original = Application.fetch_env!(:bear_cub, :routine_windows)

      Application.put_env(:bear_cub, :routine_windows,
        morning: {~T[00:00:00], ~T[23:59:59]},
        evening: {~T[23:59:59], ~T[23:59:59]}
      )

      original
    end

    test "an on-behalf extra toggle broadcasts on the chores topic so a live kiosk re-renders",
         %{conn: conn} do
      original_windows = morning_active()
      on_exit(fn -> Application.put_env(:bear_cub, :routine_windows, original_windows) end)

      kid = kid_fixture(%{name: "Kid C", color: "#a855f7", position: 2})
      morning_chore = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})
      extra = chore_fixture(kid, %{name: "Wash Car", icon: "🚗", routine: nil})

      {:ok, _} = Chores.complete_chore(morning_chore, LocalTime.now(), "kiosk")

      {:ok, kiosk, _html} = live(Phoenix.ConnTest.build_conn(), ~p"/")
      {:ok, view, _html} = live(conn, ~p"/admin")

      assert has_element?(kiosk, "#chore-#{extra.id}")
      refute has_element?(kiosk, "#chore-#{extra.id}[data-done]")

      view |> element("#today-chore-#{extra.id}") |> render_click()

      assert has_element?(kiosk, "#chore-#{extra.id}[data-done]")
    end
  end
end
