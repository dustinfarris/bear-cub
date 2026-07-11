defmodule BearCubWeb.Admin.KidLive.Index do
  use BearCubWeb, :live_view

  alias BearCub.Chores

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Chores.subscribe()

    {:ok, load(socket)}
  end

  @impl true
  def handle_info(:chores_changed, socket) do
    {:noreply, load(socket)}
  end

  defp load(socket), do: assign(socket, :kids, Chores.list_kids())

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} active={:kids}>
      <div id="admin-kids" class="mx-auto max-w-md px-4 py-6">
        <.header>
          Kids
          <:subtitle>Rename and recolor — the roster itself is fixed</:subtitle>
        </.header>

        <ul class="divide-y divide-base-200 overflow-hidden rounded-2xl bg-base-100 shadow-sm">
          <li :for={kid <- @kids} id={"admin-kid-#{kid.id}"} class="flex items-center gap-4 px-4 py-4">
            <span class="size-8 rounded-full" style={"background-color: #{kid.color}"}></span>
            <span class="min-w-0 flex-1 truncate text-lg font-semibold">{kid.name}</span>
            <.link
              id={"edit-kid-#{kid.id}"}
              navigate={~p"/admin/kids/#{kid}/edit"}
              class="text-sm font-semibold text-primary"
            >
              Edit
            </.link>
          </li>
        </ul>
      </div>
    </Layouts.admin>
    """
  end
end
