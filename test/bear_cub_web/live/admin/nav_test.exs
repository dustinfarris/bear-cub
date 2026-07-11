defmodule BearCubWeb.Admin.NavTest do
  use BearCubWeb.ConnCase

  import Phoenix.LiveViewTest
  import BearCub.ChoresFixtures

  setup do
    %{kid: kid_fixture(%{name: "Kid A", color: "#f59e0b", position: 0})}
  end

  for {path, tab} <- [
        {"/admin", "Today"},
        {"/admin/chores", "Chores"},
        {"/admin/kids", "Kids"},
        {"/admin/calendars", "Calendars"}
      ] do
    test "#{path} renders the bottom tab bar with #{tab} active", %{conn: conn} do
      {:ok, view, _html} = live(conn, unquote(path))

      assert has_element?(view, "#admin-tabs")
      assert has_element?(view, "#admin-tabs a[aria-current='page']", unquote(tab))

      # all four destinations are always reachable
      assert has_element?(view, "#admin-tabs a[href='/admin']")
      assert has_element?(view, "#admin-tabs a[href='/admin/chores']")
      assert has_element?(view, "#admin-tabs a[href='/admin/kids']")
      assert has_element?(view, "#admin-tabs a[href='/admin/calendars']")
    end
  end

  test "the kiosk remains anchor-free — the fence holds (FR-26)", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    refute has_element?(view, "a")
  end
end
