defmodule BearCubWeb.Admin.ChoreLiveTest do
  use BearCubWeb.ConnCase

  import Phoenix.LiveViewTest
  import BearCub.ChoresFixtures

  alias BearCub.Chores
  alias BearCub.LocalTime
  alias BearCub.Routines

  # Same convention as the kiosk tests: expected outcomes are computed
  # from the real clock with the app's own pure functions — no mocking.
  defp auto_routine do
    {_state, auto} = Routines.current(LocalTime.now())
    auto
  end

  # Pins morning active all day, evening never active — deterministic
  # regardless of when the suite runs, mirroring the kiosk tests' helper
  # of the same name (tests must pin the local datetime, never inherit the
  # real one — see docs/learnings.org).
  defp morning_active do
    Application.put_env(:bear_cub, :routine_windows,
      morning: {~T[00:00:00], ~T[23:59:59]},
      evening: {~T[23:59:59], ~T[23:59:59]}
    )
  end

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
    test "defaults to the first kid, grouping chores by routine", %{conn: conn, kid_a: kid_a} do
      morning = chore_fixture(kid_a, %{name: "Brush Teeth", icon: "🪥"})
      evening = chore_fixture(kid_a, %{name: "Pajamas On", icon: "🌙", routine: "evening"})

      {:ok, view, _html} = live(conn, ~p"/admin/chores")

      assert has_element?(view, "#chores-morning #admin-chore-#{morning.id}", "Brush Teeth")
      assert has_element?(view, "#chores-evening #admin-chore-#{evening.id}", "Pajamas On")
    end

    test "the kid toggle switches whose chores are shown",
         %{conn: conn, kid_a: kid_a, kid_b: kid_b} do
      a_chore = chore_fixture(kid_a, %{name: "Feed Cat", icon: "🐱"})
      b_chore = chore_fixture(kid_b, %{name: "Feed Dog", icon: "🐶"})

      {:ok, view, _html} = live(conn, ~p"/admin/chores")

      assert has_element?(view, "#admin-chore-#{a_chore.id}")
      refute has_element?(view, "#admin-chore-#{b_chore.id}")

      view |> element("#kid-tab-#{kid_b.id}") |> render_click()

      assert has_element?(view, "#admin-chore-#{b_chore.id}")
      refute has_element?(view, "#admin-chore-#{a_chore.id}")
    end

    test "▼ swaps the chore with the one below; the kiosk re-orders live",
         %{conn: conn, kid_a: kid_a} do
      original_windows = Application.fetch_env!(:bear_cub, :routine_windows)
      on_exit(fn -> Application.put_env(:bear_cub, :routine_windows, original_windows) end)
      morning_active()

      routine = Atom.to_string(auto_routine())
      first = chore_fixture(kid_a, %{name: "First", icon: "1️⃣", routine: routine})
      second = chore_fixture(kid_a, %{name: "Second", icon: "2️⃣", routine: routine})

      {:ok, kiosk, _} = live(Phoenix.ConnTest.build_conn(), ~p"/")
      {:ok, view, _} = live(conn, ~p"/admin/chores")

      view |> element("#move-down-#{first.id}") |> render_click()

      assert Enum.map(Chores.list_chores(kid_a, routine), & &1.id) == [second.id, first.id]

      assert ordered_ids(render(view), "#chores-#{routine} li[id]") ==
               ["admin-chore-#{second.id}", "admin-chore-#{first.id}"]

      assert ordered_ids(render(kiosk), "#chores-#{kid_a.id} li[id]") ==
               ["chore-#{second.id}", "chore-#{first.id}"]
    end

    test "▲ on the top chore is a harmless no-op", %{conn: conn, kid_a: kid_a} do
      chore = chore_fixture(kid_a, %{name: "Only", icon: "🌟"})

      {:ok, view, _html} = live(conn, ~p"/admin/chores")

      view |> element("#move-up-#{chore.id}") |> render_click()

      assert has_element?(view, "#admin-chore-#{chore.id}")
    end

    test "chores created elsewhere appear without refresh (FR-9)", %{conn: conn, kid_a: kid_a} do
      {:ok, view, _html} = live(conn, ~p"/admin/chores")

      {:ok, chore} =
        Chores.create_chore(kid_a, %{name: "Water Plants", icon: "🪴", routine: "morning"})

      assert has_element?(view, "#admin-chore-#{chore.id}")
    end

    test "shows an Extras section listing outstanding + done-today extras; a retired extra never appears",
         %{conn: conn, kid_a: kid_a} do
      now = LocalTime.now()

      outstanding = chore_fixture(kid_a, %{name: "Wash Car", icon: "🚗", routine: nil})
      done_today = chore_fixture(kid_a, %{name: "Water Plants", icon: "🪴", routine: nil})
      retired = chore_fixture(kid_a, %{name: "Rake Leaves", icon: "🍂", routine: nil})

      {:ok, _} = Chores.complete_chore(done_today, now, "admin")
      {:ok, _} = Chores.complete_chore(retired, DateTime.add(now, -1, :day), "admin")

      {:ok, view, _html} = live(conn, ~p"/admin/chores")

      assert has_element?(view, "#chores-extras #admin-chore-#{outstanding.id}", "Wash Car")
      assert has_element?(view, "#chores-extras #admin-chore-#{done_today.id}", "Water Plants")
      refute has_element?(view, "#admin-chore-#{retired.id}")
    end

    test "the Extras + Add link carries no routine param", %{conn: conn, kid_a: kid_a} do
      {:ok, view, _html} = live(conn, ~p"/admin/chores")

      href =
        view
        |> element("#new-chore-extras")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.attribute("href")

      assert href == ["/admin/chores/new?kid=#{kid_a.id}"]
    end
  end

  describe "form" do
    test "creates a chore for the kid in the URL, appended to the routine",
         %{conn: conn, kid_a: kid_a} do
      chore_fixture(kid_a, %{name: "Brush Teeth", icon: "🪥"})

      {:ok, view, _html} = live(conn, ~p"/admin/chores/new?kid=#{kid_a.id}&routine=morning")

      view
      |> form("#chore-form", chore: %{name: "Make Bed", icon: "🛏️"})
      |> render_submit()

      assert_redirect(view, ~p"/admin/chores?kid=#{kid_a.id}")

      [_, created] = Chores.list_chores(kid_a, "morning")
      assert created.name == "Make Bed"
      assert created.kid_id == kid_a.id
      assert created.position == 1
    end

    test "the evening + Add link also files the new chore into the evening bucket",
         %{conn: conn, kid_a: kid_a} do
      {:ok, view, _html} = live(conn, ~p"/admin/chores/new?kid=#{kid_a.id}&routine=evening")

      view
      |> form("#chore-form", chore: %{name: "Pajamas On", icon: "🌙"})
      |> render_submit()

      assert_redirect(view, ~p"/admin/chores?kid=#{kid_a.id}")

      assert [created] = Chores.list_chores(kid_a, "evening")
      assert created.name == "Pajamas On"
    end

    test "kid_id, position, and routine cannot be forged through params",
         %{conn: conn, kid_a: kid_a, kid_b: kid_b} do
      {:ok, view, _html} = live(conn, ~p"/admin/chores/new?kid=#{kid_a.id}&routine=morning")

      render_submit(view, :save, %{
        "chore" => %{
          "name" => "Sneaky",
          "icon" => "🕵️",
          "routine" => "evening",
          "kid_id" => Integer.to_string(kid_b.id),
          "position" => "9"
        }
      })

      assert [chore] = Chores.list_chores(kid_a, "morning")
      assert chore.kid_id == kid_a.id
      assert chore.position == 0
      assert Chores.list_chores(kid_b, "morning") == []
    end

    test "the routine field is not shown on create", %{conn: conn, kid_a: kid_a} do
      {:ok, view, _html} = live(conn, ~p"/admin/chores/new?kid=#{kid_a.id}")

      refute has_element?(view, "#chore_routine")
    end

    test "creates an extra when the new-chore link carries no routine param",
         %{conn: conn, kid_a: kid_a} do
      {:ok, view, _html} = live(conn, ~p"/admin/chores/new?kid=#{kid_a.id}")

      view
      |> form("#chore-form", chore: %{name: "Wash Car", icon: "🚗"})
      |> render_submit()

      assert_redirect(view, ~p"/admin/chores?kid=#{kid_a.id}")

      [created] = Chores.list_extras(kid_a, LocalTime.now() |> DateTime.to_date())
      assert created.name == "Wash Car"
      assert created.routine == nil
    end

    test "shows validation errors without saving", %{conn: conn, kid_a: kid_a} do
      {:ok, view, _html} = live(conn, ~p"/admin/chores/new?kid=#{kid_a.id}")

      html =
        view
        |> form("#chore-form", chore: %{name: "", icon: ""})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert Chores.list_chores(kid_a, "morning") == []
    end

    test "edits a chore's name and icon", %{conn: conn, kid_a: kid_a} do
      chore = chore_fixture(kid_a, %{name: "Brush Teeth", icon: "🪥"})

      {:ok, view, _html} = live(conn, ~p"/admin/chores/#{chore.id}/edit")

      view
      |> form("#chore-form", chore: %{name: "Brush Teeth Well", icon: "🦷"})
      |> render_submit()

      assert_redirect(view, ~p"/admin/chores?kid=#{kid_a.id}")

      updated = Chores.get_chore!(chore.id)
      assert updated.name == "Brush Teeth Well"
      assert updated.icon == "🦷"
    end

    test "delete on the edit form removes the chore — an explicit parent choice",
         %{conn: conn, kid_a: kid_a} do
      chore = chore_fixture(kid_a)

      {:ok, view, _html} = live(conn, ~p"/admin/chores/#{chore.id}/edit")

      view |> element("#delete-chore") |> render_click()

      assert_redirect(view, ~p"/admin/chores?kid=#{kid_a.id}")
      assert Chores.get_chore(chore.id) == nil
    end

    test "the edit form shows a single 'Shows in' select offering all three buckets",
         %{conn: conn, kid_a: kid_a} do
      chore = chore_fixture(kid_a)

      {:ok, view, _html} = live(conn, ~p"/admin/chores/#{chore.id}/edit")

      html = render(view)
      assert html =~ "Shows in"

      options =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#chore_routine option")

      assert LazyHTML.attribute(options, "value") == ["morning", "evening", ""]

      assert options |> LazyHTML.to_tree() |> Enum.map(fn {"option", _, [text]} -> text end) == [
               "Morning routine",
               "Evening routine",
               "After routines (extra)"
             ]
    end

    test "reclassifying to extra via Edit saves routine nil and appends to the extras bucket",
         %{conn: conn, kid_a: kid_a} do
      existing_extra = chore_fixture(kid_a, %{name: "Wash Car", icon: "🚗", routine: nil})
      chore = chore_fixture(kid_a, %{name: "Make Bed", icon: "🛏️"})

      {:ok, view, _html} = live(conn, ~p"/admin/chores/#{chore.id}/edit")

      view
      |> form("#chore-form", chore: %{routine: ""})
      |> render_submit()

      assert_redirect(view, ~p"/admin/chores?kid=#{kid_a.id}")

      updated = Chores.get_chore!(chore.id)
      assert updated.routine == nil

      assert Enum.map(Chores.list_extras(kid_a, LocalTime.now() |> DateTime.to_date()), & &1.id) ==
               [existing_extra.id, updated.id]
    end

    test "the points input defaults to 5 and is present on the new-chore form",
         %{conn: conn, kid_a: kid_a} do
      {:ok, view, _html} = live(conn, ~p"/admin/chores/new?kid=#{kid_a.id}")

      assert view |> element("#chore_points") |> render() =~ ~s(value="5")
    end

    test "creates an extra with a parent-adjusted points value", %{conn: conn, kid_a: kid_a} do
      {:ok, view, _html} = live(conn, ~p"/admin/chores/new?kid=#{kid_a.id}")

      view
      |> form("#chore-form", chore: %{name: "Wash Car", icon: "🚗", points: "8"})
      |> render_submit()

      assert_redirect(view, ~p"/admin/chores?kid=#{kid_a.id}")

      [created] = Chores.list_extras(kid_a, LocalTime.now() |> DateTime.to_date())
      assert created.points == 8
    end

    test "editing a chore's points updates the stored value", %{conn: conn, kid_a: kid_a} do
      chore = chore_fixture(kid_a, %{name: "Wash Car", icon: "🚗", routine: nil, points: 5})

      {:ok, view, _html} = live(conn, ~p"/admin/chores/#{chore.id}/edit")

      view
      |> form("#chore-form", chore: %{points: "12"})
      |> render_submit()

      assert_redirect(view, ~p"/admin/chores?kid=#{kid_a.id}")

      updated = Chores.get_chore!(chore.id)
      assert updated.points == 12
    end

    test "reclassifying an extra to evening via Edit re-appends to the evening bucket",
         %{conn: conn, kid_a: kid_a} do
      existing_evening =
        chore_fixture(kid_a, %{name: "Pajamas On", icon: "🌙", routine: "evening"})

      chore = chore_fixture(kid_a, %{name: "Wash Car", icon: "🚗", routine: nil})

      {:ok, view, _html} = live(conn, ~p"/admin/chores/#{chore.id}/edit")

      view
      |> form("#chore-form", chore: %{routine: "evening"})
      |> render_submit()

      assert_redirect(view, ~p"/admin/chores?kid=#{kid_a.id}")

      updated = Chores.get_chore!(chore.id)
      assert updated.routine == "evening"

      assert Enum.map(Chores.list_chores(kid_a, "evening"), & &1.id) ==
               [existing_evening.id, updated.id]
    end
  end
end
