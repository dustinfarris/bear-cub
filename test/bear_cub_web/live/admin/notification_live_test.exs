defmodule BearCubWeb.Admin.NotificationLiveTest do
  use BearCubWeb.ConnCase

  import Phoenix.LiveViewTest
  import BearCub.ChoresFixtures

  @url "https://ntfy.example/bear-cub-s3cr3t"

  setup do
    original = Application.get_env(:bear_cub, :ntfy_url)
    on_exit(fn -> Application.put_env(:bear_cub, :ntfy_url, original) end)
    %{kid: kid_fixture(%{name: "Kid A"})}
  end

  test "the Chores page links to the notifications page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/chores")

    assert view |> element("#view-notifications") |> render() =~ ~p"/admin/notifications"
  end

  test "shows the topic to subscribe to when a topic URL is configured", %{conn: conn} do
    Application.put_env(:bear_cub, :ntfy_url, @url)

    {:ok, view, html} = live(conn, ~p"/admin/notifications")

    assert html =~ "Notifications"
    assert has_element?(view, "#ntfy-server", "https://ntfy.example")
    assert has_element?(view, "#ntfy-topic", "bear-cub-s3cr3t")
    assert has_element?(view, "#ntfy-url", @url)
    assert has_element?(view, "#admin-tabs a[aria-current='page']", "Chores")
  end

  test "says notifications are off when no topic URL is configured", %{conn: conn} do
    Application.put_env(:bear_cub, :ntfy_url, nil)

    {:ok, view, html} = live(conn, ~p"/admin/notifications")

    assert html =~ "Notifications are off"
    assert html =~ "BEAR_CUB_NTFY_URL"
    refute has_element?(view, "#ntfy-topic")
  end
end
