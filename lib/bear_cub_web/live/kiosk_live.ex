defmodule BearCubWeb.KioskLive do
  use BearCubWeb, :live_view

  alias BearCub.Chores
  alias BearCub.LocalTime
  alias BearCub.Routines

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Chores.subscribe()

    # one clock read per mount — two could straddle a window edge
    now = LocalTime.now()
    {:ok, socket |> assign(:flipped, false) |> load(now) |> schedule_boundary(now)}
  end

  @impl true
  def handle_event("flip", _params, socket) do
    {:noreply, socket |> update(:flipped, &(!&1)) |> load(LocalTime.now())}
  end

  def handle_event("toggle-chore", %{"chore-id" => id}, socket) do
    chore = Chores.get_chore!(id)
    now = LocalTime.now()

    if Map.has_key?(socket.assigns.completions, chore.id) do
      # {:error, :not_completed} if another surface undid it first — no-op
      Chores.undo_chore(chore, now)
    else
      # a racing double-complete hits the partial unique index — already done
      Chores.complete_chore(chore, now, "kiosk")
    end

    {:noreply, load(socket, now)}
  end

  @impl true
  def handle_info(:chores_changed, socket) do
    {:noreply, load(socket, LocalTime.now())}
  end

  def handle_info(:boundary, socket) do
    # Window handoff (FR-3), flip reversion (FR-4), and the midnight
    # re-render of derived day state (design §2) are all one event:
    # recompute everything and schedule the next boundary.
    now = LocalTime.now()
    {:noreply, socket |> assign(:flipped, false) |> load(now) |> schedule_boundary(now)}
  end

  defp load(socket, local_now) do
    {state, auto} = Routines.current(local_now)
    shown = if socket.assigns.flipped, do: Routines.other(auto), else: auto

    # done today? — derived, never stored (design §2)
    completions = Chores.current_completions(DateTime.to_date(local_now))

    columns =
      for kid <- Chores.list_kids() do
        chores =
          for chore <- Chores.list_chores(kid, Atom.to_string(shown)) do
            %{chore: chore, done?: Map.has_key?(completions, chore.id)}
          end

        %{kid: kid, chores: chores}
      end

    assign(socket,
      columns: columns,
      completions: completions,
      shown: shown,
      dimmed?: socket.assigns.flipped or state == :upcoming
    )
  end

  defp schedule_boundary(socket, now) do
    if connected?(socket) do
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
               evenly, beyond 5 only this region scrolls (FR-6). Done = kid-color
               fill + check, emoji still visible (FR-7); tap again to undo, no
               confirmation (FR-8). phx-throttle swallows the excited rapid
               double-tap (D15). Dimming is visual only — rows stay tappable
               (D19). --%>
          <ul
            id={"chores-#{kid.id}"}
            class={[
              "grid auto-rows-fr gap-px overflow-y-auto bg-base-300 transition-opacity",
              @dimmed? && "opacity-40"
            ]}
          >
            <li
              :for={%{chore: chore, done?: done?} <- chores}
              id={"chore-#{chore.id}"}
              data-done={done?}
              phx-click="toggle-chore"
              phx-value-chore-id={chore.id}
              phx-throttle="1000"
              class={[
                "flex min-h-[88px] cursor-pointer select-none items-center gap-5 px-6 transition-colors",
                !done? && "bg-base-100"
              ]}
              style={done? && "background-color: #{kid.color}"}
            >
              <span class="text-[2.5rem] leading-none">{chore.icon}</span>
              <span class={["text-2xl font-semibold", done? && "text-white drop-shadow-sm"]}>
                {chore.name}
              </span>
              <.icon :if={done?} name="hero-check" class="ml-auto size-10 text-white drop-shadow-sm" />
            </li>
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
