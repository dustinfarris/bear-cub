defmodule BearCubWeb.KioskLive do
  use BearCubWeb, :live_view

  alias BearCub.Chores

  @impl true
  def mount(_params, _session, socket) do
    kids = Chores.list_kids()

    columns =
      for kid <- kids do
        %{kid: kid, chores: Chores.list_chores(kid, "morning")}
      end

    {:ok, assign(socket, :columns, columns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="kiosk" class="grid h-dvh grid-cols-2 gap-px overflow-hidden bg-base-300">
        <section
          :for={%{kid: kid, chores: chores} <- @columns}
          id={"kid-column-#{kid.id}"}
          class="grid grid-rows-[auto_auto_1fr] overflow-hidden bg-base-100"
        >
          <%!-- Header band: the color block, not the name, is the primary
               identifier (FR-5a) — a pre-reader finds their column by color. --%>
          <header
            class="flex items-center justify-center py-5"
            style={"background-color: #{kid.color}"}
          >
            <h1 class="text-4xl font-bold tracking-tight text-white drop-shadow-sm">
              {kid.name}
            </h1>
          </header>

          <%!-- Events strip: populated in Phase 4; the region exists now so the
               three-band column layout is what on-device QA actually sees. --%>
          <div id={"events-#{kid.id}"} class="border-b border-base-300 px-5 py-3">
            <p class="text-sm text-base-content/40">No events today</p>
          </div>

          <%!-- Chores: equal full-width rows; at ≤5 the 1fr region divides
               evenly, beyond 5 only this region scrolls (FR-6). Static in
               Phase 1 — taps arrive in Phase 2. --%>
          <ul
            id={"chores-#{kid.id}"}
            class="grid auto-rows-fr gap-px overflow-y-auto bg-base-300"
          >
            <li
              :for={chore <- chores}
              id={"chore-#{chore.id}"}
              class="flex min-h-[88px] items-center gap-5 bg-base-100 px-6"
            >
              <span class="text-[2.5rem] leading-none">{chore.icon}</span>
              <span class="text-2xl font-semibold">{chore.name}</span>
            </li>
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
