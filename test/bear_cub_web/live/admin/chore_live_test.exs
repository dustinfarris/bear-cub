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
  end

  describe "form" do
    test "creates a chore for the kid in the URL, appended to the routine",
         %{conn: conn, kid_a: kid_a} do
      chore_fixture(kid_a, %{name: "Brush Teeth", icon: "🪥"})

      {:ok, view, _html} = live(conn, ~p"/admin/chores/new?kid=#{kid_a.id}&routine=morning")

      view
      |> form("#chore-form", chore: %{name: "Make Bed", icon: "🛏️", routine: "morning"})
      |> render_submit()

      assert_redirect(view, ~p"/admin/chores?kid=#{kid_a.id}")

      [_, created] = Chores.list_chores(kid_a, "morning")
      assert created.name == "Make Bed"
      assert created.kid_id == kid_a.id
      assert created.position == 1
    end

    test "kid_id and position cannot be forged through params",
         %{conn: conn, kid_a: kid_a, kid_b: kid_b} do
      {:ok, view, _html} = live(conn, ~p"/admin/chores/new?kid=#{kid_a.id}")

      render_submit(view, :save, %{
        "chore" => %{
          "name" => "Sneaky",
          "icon" => "🕵️",
          "routine" => "morning",
          "kid_id" => Integer.to_string(kid_b.id),
          "position" => "9"
        }
      })

      assert [chore] = Chores.list_chores(kid_a, "morning")
      assert chore.kid_id == kid_a.id
      assert chore.position == 0
      assert Chores.list_chores(kid_b, "morning") == []
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
  end
end
