defmodule BearCubWeb.Admin.CalendarLive.Index do
  use BearCubWeb, :live_view

  alias BearCub.Calendars
  alias BearCub.Chores

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Calendars.subscribe()

    {:ok, load(socket)}
  end

  @impl true
  def handle_info(:calendars_changed, socket) do
    {:noreply, load(socket)}
  end

  defp load(socket) do
    kids = Map.new(Chores.list_kids(), &{&1.id, &1})
    assign(socket, calendars: Calendars.list_calendars(), kids: kids)
  end

  defp owner_label(nil, _kids), do: "Family"
  defp owner_label(kid_id, kids), do: Map.fetch!(kids, kid_id).name

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} active={:calendars}>
      <div id="admin-calendars" class="mx-auto max-w-md px-4 py-6">
        <.header>
          Calendars
          <:actions>
            <.link
              id="new-calendar"
              navigate={~p"/admin/calendars/new"}
              class="text-sm font-semibold text-primary"
            >
              + Add
            </.link>
          </:actions>
        </.header>

        <ul
          id="calendars"
          class="mt-4 divide-y divide-base-200 overflow-hidden rounded-2xl bg-base-100 shadow-sm"
        >
          <li
            :for={calendar <- @calendars}
            id={"admin-calendar-#{calendar.id}"}
            class="flex items-center gap-3 px-4 py-4"
          >
            <div class="min-w-0 flex-1">
              <p class="truncate font-medium">{calendar.label}</p>
              <p class="text-sm text-base-content/60">{owner_label(calendar.kid_id, @kids)}</p>
            </div>
            <.link
              id={"edit-calendar-#{calendar.id}"}
              navigate={~p"/admin/calendars/#{calendar}/edit"}
              class="text-sm font-semibold text-primary"
            >
              Edit
            </.link>
          </li>
          <li :if={@calendars == []} class="px-4 py-3 text-sm text-base-content/40">
            No calendars yet
          </li>
        </ul>
      </div>
    </Layouts.admin>
    """
  end
end
