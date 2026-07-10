defmodule BearCubWeb.KioskLiveTest do
  use BearCubWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import BearCub.ChoresFixtures

  describe "with two kids" do
    setup do
      kid_a = kid_fixture(%{name: "Kid A", color: "#f59e0b", position: 0})
      kid_b = kid_fixture(%{name: "Kid B", color: "#0ea5e9", position: 1})
      %{kid_a: kid_a, kid_b: kid_b}
    end

    test "renders one column per kid, headed by name and identity color",
         %{conn: conn, kid_a: kid_a, kid_b: kid_b} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#kid-column-#{kid_a.id}", "Kid A")
      assert has_element?(view, "#kid-column-#{kid_b.id}", "Kid B")
      # identity color is painted as an inline style on the header band
      assert has_element?(
               view,
               "#kid-column-#{kid_a.id} header[style*='background-color: #f59e0b']"
             )

      assert has_element?(
               view,
               "#kid-column-#{kid_b.id} header[style*='background-color: #0ea5e9']"
             )
    end

    test "renders the kid's morning chores as icon + name rows",
         %{conn: conn, kid_a: kid_a} do
      chore = chore_fixture(kid_a, %{name: "Brush Teeth", icon: "🪥", position: 0})

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#chore-#{chore.id}", "Brush Teeth")
      assert has_element?(view, "#chore-#{chore.id}", "🪥")
    end

    test "renders an events strip region per kid", %{conn: conn, kid_a: kid_a} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#events-#{kid_a.id}")
    end

    test "renders fine with zero chores (production first boot)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#kiosk")
    end

    test "kiosk contains no links at all — Fully Kiosk's URL lock is the only fence",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "a")
    end
  end

  describe "with no kids yet (fresh production database)" do
    test "renders the empty kiosk shell without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#kiosk")
      refute has_element?(view, "[id^='kid-column-']")
    end
  end
end
