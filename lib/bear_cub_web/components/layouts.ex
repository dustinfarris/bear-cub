defmodule BearCubWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use BearCubWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    {render_slot(@inner_block)}
    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Admin shell (design §4, Phase 3): wraps admin pages with the fixed
  bottom tab bar — thumb-reachable on the phone, the primary admin form
  factor (FR-25). Rendered only by /admin templates; the kiosk never
  sees an anchor (FR-26).
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :active, :atom, required: true, values: [:today, :chores, :kids]
  slot :inner_block, required: true

  def admin(assigns) do
    ~H"""
    <main class="min-h-dvh bg-base-200 pb-24">
      {render_slot(@inner_block)}
    </main>

    <nav
      id="admin-tabs"
      class="fixed inset-x-0 bottom-0 border-t border-base-300 bg-base-100 pb-[env(safe-area-inset-bottom)]"
    >
      <div class="mx-auto grid max-w-md grid-cols-3">
        <.admin_tab
          navigate={~p"/admin"}
          icon="hero-check-circle"
          label="Today"
          active={@active == :today}
        />
        <.admin_tab
          navigate={~p"/admin/chores"}
          icon="hero-list-bullet"
          label="Chores"
          active={@active == :chores}
        />
        <.admin_tab
          navigate={~p"/admin/kids"}
          icon="hero-user-group"
          label="Kids"
          active={@active == :kids}
        />
      </div>
    </nav>

    <.flash_group flash={@flash} />
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, required: true

  defp admin_tab(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      aria-current={@active && "page"}
      class={[
        "flex flex-col items-center gap-1 py-2 text-xs font-semibold transition",
        @active && "text-primary",
        !@active && "text-base-content/60"
      ]}
    >
      <.icon name={@icon} class="size-6" />
      {@label}
    </.link>
    """
  end
end
