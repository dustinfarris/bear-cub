defmodule BearCubWeb.Admin.NotificationLive do
  @moduledoc """
  Where a parent finds the ntfy topic to subscribe to. The topic is
  generated on the server at first boot (nix/module.nix, the
  `SECRET_KEY_BASE` pattern) rather than placed by hand, so this page is
  the only place it is ever shown — admin is tailnet-only (D5), the same
  trust the calendar forms extend to the ICS URLs.
  """
  use BearCubWeb, :live_view

  alias BearCub.Notifications

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, subscription: subscription(Notifications.topic_url()))}
  end

  defp subscription(nil), do: nil

  defp subscription(url) do
    uri = URI.parse(url)

    %{
      url: url,
      server: %{uri | path: nil, query: nil, fragment: nil} |> URI.to_string(),
      topic: String.trim_leading(uri.path || "", "/")
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} active={:chores} static_reload_href={@static_reload_href}>
      <div id="admin-notifications" class="mx-auto max-w-md px-4 py-6">
        <.header>
          Notifications
          <:subtitle>Pushes for flagged chores, finished routines, and reward asks</:subtitle>
        </.header>

        <div :if={@subscription} class="mt-6 space-y-4 text-sm">
          <p>
            Install the <span class="font-semibold">ntfy</span>
            app on your phone and subscribe to this topic. Anyone who knows it can read and
            send these pushes, so treat it like a password.
          </p>
          <dl class="space-y-3 rounded-xl bg-base-100 p-4">
            <div>
              <dt class="text-xs uppercase text-base-content/60">Server</dt>
              <dd id="ntfy-server" class="font-mono break-all">{@subscription.server}</dd>
            </div>
            <div>
              <dt class="text-xs uppercase text-base-content/60">Topic</dt>
              <dd id="ntfy-topic" class="font-mono break-all select-all">{@subscription.topic}</dd>
            </div>
            <div>
              <dt class="text-xs uppercase text-base-content/60">Full URL</dt>
              <dd id="ntfy-url" class="font-mono break-all select-all">{@subscription.url}</dd>
            </div>
          </dl>
        </div>

        <div :if={is_nil(@subscription)} class="mt-6 space-y-2 text-sm">
          <p class="font-semibold">Notifications are off.</p>
          <p>
            No topic URL is configured: set <code class="font-mono">BEAR_CUB_NTFY_URL</code>
            (the NixOS module generates one on first boot when
            <code class="font-mono">ntfyServer</code>
            is set).
          </p>
        </div>
      </div>
    </Layouts.admin>
    """
  end
end
