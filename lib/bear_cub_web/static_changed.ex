defmodule BearCubWeb.StaticChanged do
  @moduledoc """
  Detects a client left running an outdated asset bundle, and lets each
  surface react.

  `phx-track-static` in the root layout is only half a mechanism: it makes
  the client send the `href`/`src` of its stylesheet and script as the
  `_track_static` connect param on every join, reconnects included, and
  nothing on the server looks at that unless you ask. This hook is the other
  half — `Phoenix.LiveView.static_changed?/1` compares what the client
  actually loaded against what this release digests.

  It matters because a deploy restarts the release without reloading any open
  page. The client rejoins, LiveView patches freshly rendered markup into the
  *old* document, and any class minted since that document's stylesheet was
  built has no rule behind it — the markup is new, the CSS is not, and the
  class silently does nothing.

  Reaction is the surface's choice, not this hook's:

    * `BearCubWeb.KioskLive` reloads itself — nobody is standing at the
      fridge to tap a banner, and a kiosk has no work in progress to lose.
    * `BearCubWeb.Layouts.admin/1` offers a link instead, rather than yanking
      a half-filled form out from under a parent.

  Inert outside prod: `static_changed?/1` reads the digest manifest that only
  `mix phx.digest` warms into the endpoint, so with no manifest configured
  (dev, test) it is always false.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, static_changed?: 1]

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign(:static_changed?, static_changed?(socket))
      |> assign(:static_reload_href, nil)

    if socket.assigns.static_changed? do
      {:cont, attach_hook(socket, :static_reload_href, :handle_params, &put_reload_href/3)}
    else
      {:cont, socket}
    end
  end

  # The reload link has to point at the page the parent is already on, which
  # only `handle_params` knows. Path + query only: an absolute href would
  # bake in the LAN IP or tailnet name the page happened to be reached by.
  defp put_reload_href(_params, uri, socket) do
    %URI{path: path, query: query} = URI.parse(uri)
    href = URI.to_string(%URI{path: path, query: query})

    {:cont, assign(socket, :static_reload_href, href)}
  end
end
