defmodule BearCubWeb.StaticChangedTest do
  # async: false — these tests mutate endpoint-wide static manifest config.
  use BearCubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BearCubWeb.Endpoint

  # Stands in for the map `mix phx.digest` warms into the endpoint in prod.
  # In dev and test no manifest is configured, so `static_changed?/1` is
  # always false and none of this machinery engages.
  @latest %{
    "assets/css/app.css" => "assets/css/app-cafebabe.css",
    "assets/js/app.js" => "assets/js/app-deadbeef.js"
  }

  @current ["http://localhost/assets/css/app-cafebabe.css?vsn=d"]
  @stale ["http://localhost/assets/css/app-0ldbund1e.css?vsn=d"]

  setup do
    previous = Endpoint.config(:cache_static_manifest_latest)
    Phoenix.Config.put(Endpoint, :cache_static_manifest_latest, @latest)
    on_exit(fn -> Phoenix.Config.put(Endpoint, :cache_static_manifest_latest, previous) end)
    :ok
  end

  defp tracking(conn, statics), do: put_connect_params(conn, %{"_track_static" => statics})

  describe "kiosk" do
    test "a client on a stale bundle is sent a full page reload", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(tracking(conn, @stale), ~p"/")
    end

    test "a client on the current bundle mounts normally", %{conn: conn} do
      assert {:ok, _view, _html} = live(tracking(conn, @current), ~p"/")
    end

    test "no manifest configured (dev/test) never reloads", %{conn: conn} do
      Phoenix.Config.put(Endpoint, :cache_static_manifest_latest, nil)
      assert {:ok, _view, _html} = live(tracking(conn, @stale), ~p"/")
    end
  end

  describe "admin" do
    test "a client on a stale bundle gets a reload banner, not a redirect", %{conn: conn} do
      {:ok, view, _html} = live(tracking(conn, @stale), ~p"/admin")

      assert has_element?(view, "#static-reload")
      assert has_element?(view, "#static-reload a[href='/admin']")
    end

    test "the banner links back to the page the parent is on", %{conn: conn} do
      {:ok, view, _html} = live(tracking(conn, @stale), ~p"/admin/rewards")

      assert has_element?(view, "#static-reload a[href='/admin/rewards']")
    end

    test "a client on the current bundle gets no banner", %{conn: conn} do
      {:ok, view, _html} = live(tracking(conn, @current), ~p"/admin")

      refute has_element?(view, "#static-reload")
    end
  end
end
