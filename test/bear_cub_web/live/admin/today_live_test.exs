defmodule BearCubWeb.Admin.TodayLiveTest do
  use BearCubWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import BearCub.ChoresFixtures

  alias BearCub.Chores
  alias BearCub.Chores.Completion
  alias BearCub.LocalTime
  alias BearCub.Repo
  alias BearCub.Routines

  # No clock mocking: the expected active routine comes from the same
  # pure functions the view uses (accepted rare window-edge flake).
  defp active_routine do
    {_state, active} = Routines.current(LocalTime.now())
    active
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
    {:ok, kiosk, _} = live(Phoenix.ConnTest.build_conn(), ~p"/")
    {:ok, view, _html} = live(conn, ~p"/admin")

    view |> element("#today-chore-#{ctx.a_active.id}") |> render_click()

    assert has_element?(view, "#today-chore-#{ctx.a_active.id}[data-done]")

    completion = Repo.one!(from c in Completion, where: c.chore_id == ^ctx.a_active.id)
    assert completion.source == "admin"

    assert has_element?(kiosk, "#chore-#{ctx.a_active.id}[data-done]")
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

  test "reset day for one kid bulk-undoes only that kid (D21)",
       %{conn: conn, kid_a: kid_a} = ctx do
    now = LocalTime.now()
    {:ok, _} = Chores.complete_chore(ctx.a_active, now, "kiosk")
    {:ok, _} = Chores.complete_chore(ctx.a_inactive, now, "kiosk")
    {:ok, _} = Chores.complete_chore(ctx.b_active, now, "kiosk")

    {:ok, view, _html} = live(conn, ~p"/admin")

    view |> element("#reset-kid-#{kid_a.id}") |> render_click()

    refute has_element?(view, "#today-chore-#{ctx.a_active.id}[data-done]")
    assert has_element?(view, "#today-chore-#{ctx.b_active.id}[data-done]")

    # bulk undo, never delete (FR-17): all three rows survive
    assert Repo.aggregate(Completion, :count) == 3
  end

  test "reset whole day clears both kids", %{conn: conn} = ctx do
    now = LocalTime.now()
    {:ok, _} = Chores.complete_chore(ctx.a_active, now, "kiosk")
    {:ok, _} = Chores.complete_chore(ctx.b_active, now, "kiosk")

    {:ok, view, _html} = live(conn, ~p"/admin")

    view |> element("#reset-day") |> render_click()

    refute has_element?(view, "#today-chore-#{ctx.a_active.id}[data-done]")
    refute has_element?(view, "#today-chore-#{ctx.b_active.id}[data-done]")
    assert Chores.current_completions(DateTime.to_date(now)) == %{}
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

  test "both reset buttons ask for confirmation", %{conn: conn, kid_a: kid_a} do
    {:ok, view, _html} = live(conn, ~p"/admin")

    assert has_element?(view, "#reset-kid-#{kid_a.id}[data-confirm]")
    assert has_element?(view, "#reset-day[data-confirm]")
  end
end
