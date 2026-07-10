defmodule BearCubWeb.KioskLive do
  use BearCubWeb, :live_view

  alias BearCub.Chores
  alias BearCub.LocalTime
  alias BearCub.Routines

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:flipped, false) |> load(LocalTime.now()) |> schedule_boundary()}
  end

  @impl true
  def handle_event("flip", _params, socket) do
    {:noreply, socket |> update(:flipped, &(!&1)) |> load(LocalTime.now())}
  end

  @impl true
  def handle_info(:boundary, socket) do
    # Window handoff (FR-3), flip reversion (FR-4), and the midnight
    # re-render of derived day state (design §2) are all one event:
    # recompute everything and schedule the next boundary.
    {:noreply, socket |> assign(:flipped, false) |> load(LocalTime.now()) |> schedule_boundary()}
  end

  defp load(socket, local_now) do
    {state, auto} = Routines.current(local_now)
    shown = if socket.assigns.flipped, do: Routines.other(auto), else: auto

    columns =
      for kid <- Chores.list_kids() do
        %{kid: kid, chores: Chores.list_chores(kid, Atom.to_string(shown))}
      end

    assign(socket,
      columns: columns,
      shown: shown,
      dimmed?: socket.assigns.flipped or state == :upcoming
    )
  end

  defp schedule_boundary(socket) do
    if connected?(socket) do
      now = LocalTime.now()
      ms = DateTime.diff(Routines.next_boundary(now), now, :millisecond)
      # floor guards against a timer that fires a hair early re-arming hot
      Process.send_after(self(), :boundary, max(ms, 1_000))
    end

    socket
  end

  defp routine_label(:morning), do: "Morning"
  defp routine_label(:evening), do: "Evening"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div
        id="kiosk"
        data-dimmed={@dimmed?}
        class="relative grid h-dvh grid-cols-2 gap-px overflow-hidden bg-base-300"
      >
        <%!-- The single flip control (FR-4): deliberately small and styled
             nothing like a chore row; reverts at the next boundary. --%>
        <button
          id="routine-flip"
          phx-click="flip"
          class="absolute left-1/2 top-4 z-10 flex -translate-x-1/2 items-center gap-2 rounded-full bg-base-100/90 px-4 py-2 text-sm font-semibold text-base-content shadow-md transition active:scale-95"
        >
          {routine_label(@shown)}
          <.icon name="hero-arrows-right-left" class="size-4" />
        </button>

        <section
          :for={%{kid: kid, chores: chores} <- @columns}
          id={"kid-column-#{kid.id}"}
          class="grid grid-rows-[auto_auto_1fr] overflow-hidden bg-base-100"
        >
          <%!-- Header band: the color block, not the name, is the primary
               identifier (FR-5a) — a pre-reader finds their column by color.
               Never dimmed: identity stays legible across the kitchen. --%>
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
          <div
            id={"events-#{kid.id}"}
            class={[
              "border-b border-base-300 px-5 py-3 transition-opacity",
              @dimmed? && "opacity-40"
            ]}
          >
            <p class="text-sm text-base-content/40">No events today</p>
          </div>

          <%!-- Chores: equal full-width rows; at ≤5 the 1fr region divides
               evenly, beyond 5 only this region scrolls (FR-6). Dimmed when
               the shown routine is not the active one (design §5). --%>
          <ul
            id={"chores-#{kid.id}"}
            class={[
              "grid auto-rows-fr gap-px overflow-y-auto bg-base-300 transition-opacity",
              @dimmed? && "opacity-40"
            ]}
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
