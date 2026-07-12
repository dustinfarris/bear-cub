defmodule BearCubWeb.Admin.ChoreLive.Index do
  use BearCubWeb, :live_view

  alias BearCub.Chores
  alias BearCub.LocalTime

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Chores.subscribe()

    {:ok, assign(socket, :kid_param, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign(:kid_param, params["kid"]) |> load()}
  end

  @impl true
  def handle_event("move", %{"chore-id" => id, "dir" => dir}, socket) when dir in ~w(up down) do
    case Chores.get_chore(id) do
      # deleted from another surface after this render — the reload drops the row
      nil ->
        {:noreply, load(socket)}

      chore ->
        {:ok, _} = Chores.move_chore(chore, String.to_existing_atom(dir))
        {:noreply, load(socket)}
    end
  end

  @impl true
  def handle_info(:chores_changed, socket) do
    {:noreply, load(socket)}
  end

  defp load(socket) do
    kids = Chores.list_kids()

    selected =
      Enum.find(kids, List.first(kids), fn kid ->
        Integer.to_string(kid.id) == socket.assigns.kid_param
      end)

    sections =
      for routine <- [:morning, :evening] do
        chores =
          if selected, do: Chores.list_chores(selected, Atom.to_string(routine)), else: []

        {routine, chores}
      end

    extras =
      if selected, do: Chores.list_extras(selected, DateTime.to_date(LocalTime.now())), else: []

    assign(socket, kids: kids, selected_kid: selected, sections: sections, extras: extras)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} active={:chores}>
      <div id="admin-chores" class="mx-auto max-w-md px-4 py-6">
        <.header>Chores</.header>

        <div
          :if={@kids != []}
          id="kid-toggle"
          class="grid grid-cols-2 gap-1 rounded-xl bg-base-200 p-1"
        >
          <.link
            :for={kid <- @kids}
            id={"kid-tab-#{kid.id}"}
            patch={~p"/admin/chores?kid=#{kid.id}"}
            class={[
              "flex items-center justify-center gap-2 rounded-lg px-3 py-2 text-sm font-semibold transition",
              @selected_kid && @selected_kid.id == kid.id && "bg-base-100 shadow",
              !(@selected_kid && @selected_kid.id == kid.id) && "text-base-content/60"
            ]}
          >
            <span class="size-2.5 rounded-full" style={"background-color: #{kid.color}"}></span>
            {kid.name}
          </.link>
        </div>

        <section :for={{routine, chores} <- @sections} id={"routine-#{routine}"} class="mt-8">
          <div class="flex items-center justify-between">
            <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
              {routine_label(routine)}
            </h2>
            <.link
              :if={@selected_kid}
              id={"new-chore-#{routine}"}
              navigate={~p"/admin/chores/new?kid=#{@selected_kid.id}&routine=#{routine}"}
              class="text-sm font-semibold text-primary"
            >
              + Add
            </.link>
          </div>

          <ul
            id={"chores-#{routine}"}
            class="mt-2 divide-y divide-base-200 overflow-hidden rounded-2xl bg-base-100 shadow-sm"
          >
            <.chore_row :for={chore <- chores} chore={chore} />
            <li :if={chores == []} class="px-4 py-3 text-sm text-base-content/40">
              No chores yet
            </li>
          </ul>
        </section>

        <section id="routine-extras" class="mt-8">
          <div class="flex items-center justify-between">
            <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
              Extras
            </h2>
            <.link
              :if={@selected_kid}
              id="new-chore-extras"
              navigate={~p"/admin/chores/new?kid=#{@selected_kid.id}"}
              class="text-sm font-semibold text-primary"
            >
              + Add
            </.link>
          </div>

          <ul
            id="chores-extras"
            class="mt-2 divide-y divide-base-200 overflow-hidden rounded-2xl bg-base-100 shadow-sm"
          >
            <.chore_row :for={chore <- @extras} chore={chore} />
            <li :if={@extras == []} class="px-4 py-3 text-sm text-base-content/40">
              No chores yet
            </li>
          </ul>
        </section>
      </div>
    </Layouts.admin>
    """
  end

  attr :chore, :map, required: true

  defp chore_row(assigns) do
    ~H"""
    <li id={"admin-chore-#{@chore.id}"} class="flex items-center gap-3 px-4 py-3">
      <span class="text-2xl leading-none">{@chore.icon}</span>
      <span class="min-w-0 flex-1 truncate font-medium">{@chore.name}</span>

      <button
        id={"move-up-#{@chore.id}"}
        phx-click="move"
        phx-value-chore-id={@chore.id}
        phx-value-dir="up"
        aria-label={"Move #{@chore.name} up"}
        class="rounded-lg p-2 text-base-content/60 transition active:scale-95"
      >
        <.icon name="hero-chevron-up" class="size-5" />
      </button>
      <button
        id={"move-down-#{@chore.id}"}
        phx-click="move"
        phx-value-chore-id={@chore.id}
        phx-value-dir="down"
        aria-label={"Move #{@chore.name} down"}
        class="rounded-lg p-2 text-base-content/60 transition active:scale-95"
      >
        <.icon name="hero-chevron-down" class="size-5" />
      </button>

      <.link
        id={"edit-chore-#{@chore.id}"}
        navigate={~p"/admin/chores/#{@chore}/edit"}
        class="ml-1 text-sm font-semibold text-primary"
      >
        Edit
      </.link>
    </li>
    """
  end
end
