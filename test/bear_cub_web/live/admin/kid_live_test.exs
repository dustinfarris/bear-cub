defmodule BearCubWeb.Admin.KidLiveTest do
  use BearCubWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import BearCub.ChoresFixtures

  alias BearCub.Chores

  setup do
    kid_a = kid_fixture(%{name: "Kid A", color: "#f59e0b", position: 0})
    kid_b = kid_fixture(%{name: "Kid B", color: "#0ea5e9", position: 1})
    %{kid_a: kid_a, kid_b: kid_b}
  end

  describe "index" do
    test "lists both kids with edit links and no create/delete controls",
         %{conn: conn, kid_a: kid_a, kid_b: kid_b} do
      {:ok, view, html} = live(conn, ~p"/admin/kids")

      assert has_element?(view, "#admin-kid-#{kid_a.id}", "Kid A")
      assert has_element?(view, "#admin-kid-#{kid_b.id}", "Kid B")
      assert has_element?(view, "#edit-kid-#{kid_a.id}")

      # kids are edit-only in v1 (design §1): no create, no delete, anywhere
      refute html =~ "New Kid"
      refute html =~ "Delete"
    end

    test "a rename from elsewhere appears without refresh (FR-9)", %{conn: conn, kid_a: kid_a} do
      {:ok, view, _html} = live(conn, ~p"/admin/kids")

      {:ok, _} = Chores.update_kid(kid_a, %{name: "Bear"})

      assert has_element?(view, "#admin-kid-#{kid_a.id}", "Bear")
    end
  end

  describe "form" do
    test "renames and recolors from the swatch palette; the kiosk follows live",
         %{conn: conn, kid_a: kid_a} do
      {:ok, kiosk, _} = live(Phoenix.ConnTest.build_conn(), ~p"/")
      {:ok, view, _html} = live(conn, ~p"/admin/kids/#{kid_a.id}/edit")

      view
      |> form("#kid-form", kid: %{name: "Bear", color: "#2563eb"})
      |> render_submit()

      assert_redirect(view, ~p"/admin/kids")

      updated = Chores.get_kid!(kid_a.id)
      assert updated.name == "Bear"
      assert updated.color == "#2563eb"

      assert has_element?(kiosk, "#kid-column-#{kid_a.id}", "Bear")

      assert has_element?(
               kiosk,
               "#kid-column-#{kid_a.id} header[style*='background-color: #2563eb']"
             )
    end

    test "a current color outside the palette still renders as a selected swatch",
         %{conn: conn, kid_a: kid_a} do
      # #f59e0b (the seed amber) is not one of the ten curated swatches
      {:ok, view, _html} = live(conn, ~p"/admin/kids/#{kid_a.id}/edit")

      assert has_element?(view, "#swatch-f59e0b input[checked]")
    end

    test "rejects a blank name", %{conn: conn, kid_a: kid_a} do
      {:ok, view, _html} = live(conn, ~p"/admin/kids/#{kid_a.id}/edit")

      html =
        view
        |> form("#kid-form", kid: %{name: ""})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert Chores.get_kid!(kid_a.id).name == "Kid A"
    end
  end
end
