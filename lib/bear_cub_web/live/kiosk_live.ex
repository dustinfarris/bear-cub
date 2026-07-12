defmodule BearCubWeb.KioskLive do
  use BearCubWeb, :live_view

  alias BearCub.Calendars
  alias BearCub.Chores
  alias BearCub.LocalTime
  alias BearCub.Messages
  alias BearCub.Routines

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Chores.subscribe()
      Calendars.subscribe()
    end

    # one clock read per mount — two could straddle a window edge
    now = LocalTime.now()

    {:ok,
     socket
     |> assign(:expanded, MapSet.new())
     |> load(now)
     |> schedule_boundary(now)}
  end

  @impl true
  def handle_event("toggle-chore", %{"chore-id" => id}, socket) do
    now = LocalTime.now()

    case Chores.get_chore(id) do
      # deleted from admin after this render — drop the tap, refresh the row away
      nil ->
        {:noreply, load(socket, now)}

      chore ->
        if Map.has_key?(socket.assigns.completions, chore.id) do
          # {:error, :not_completed} if another surface undid it first — no-op
          Chores.undo_chore(chore, now)
        else
          # a racing double-complete hits the partial unique index — already done
          Chores.complete_chore(chore, now, "kiosk")
        end

        {:noreply, load(socket, now)}
    end
  end

  # Manual re-expand (state 4, D34): ephemeral, assign-level, never persisted.
  # `load/2` drops a kid_id from this set the moment their routine stops
  # being reveal-eligible (window closes or a chore gets undone).
  def handle_event("toggle-band", %{"kid-id" => kid_id}, socket) do
    kid_id = String.to_integer(kid_id)
    expanded = socket.assigns.expanded

    expanded =
      if MapSet.member?(expanded, kid_id),
        do: MapSet.delete(expanded, kid_id),
        else: MapSet.put(expanded, kid_id)

    {:noreply, socket |> assign(:expanded, expanded) |> load(LocalTime.now())}
  end

  @impl true
  def handle_info(:chores_changed, socket) do
    {:noreply, load(socket, LocalTime.now())}
  end

  def handle_info(:calendars_changed, socket) do
    {:noreply, load(socket, LocalTime.now())}
  end

  def handle_info(:boundary, socket) do
    # Window handoff (FR-3) and the midnight re-render of derived day state
    # (design §2) are all one event: recompute everything and schedule the
    # next boundary.
    now = LocalTime.now()
    {:noreply, socket |> load(now) |> schedule_boundary(now)}
  end

  defp load(socket, local_now) do
    {routine_state, auto} = Routines.current(local_now)
    night? = routine_state == :upcoming
    today = DateTime.to_date(local_now)

    # done today? — derived, never stored (design §2)
    completions = Chores.current_completions(today)
    expanded = socket.assigns.expanded

    columns =
      for kid <- Chores.list_kids() do
        build_column(kid, auto, night?, completions, today, expanded)
      end

    # Reveal gating flips clear the ephemeral re-expand entry (D34): a kid
    # stays in `expanded` only while their routine is still reveal-eligible.
    still_expanded =
      columns
      |> Enum.filter(& &1.reveal?)
      |> Enum.map(& &1.kid.id)
      |> MapSet.new()
      |> MapSet.intersection(expanded)

    assign(socket,
      columns: columns,
      completions: completions,
      expanded: still_expanded,
      calendars_stale?: Calendars.any_stale?(local_now)
    )
  end

  defp build_column(kid, auto, night?, completions, today, expanded) do
    chores = if night?, do: [], else: Chores.list_chores(kid, Atom.to_string(auto))
    complete? = chores != [] and Enum.all?(chores, &Map.has_key?(completions, &1.id))
    reveal? = not night? and complete?
    kid_expanded? = MapSet.member?(expanded, kid.id)

    state =
      cond do
        night? -> :night
        reveal? and not kid_expanded? -> :band
        true -> :rows
      end

    extras =
      if state == :band and auto == :morning do
        for extra <- Chores.list_extras(kid, today) do
          %{chore: extra, done?: Map.has_key?(completions, extra.id)}
        end
      else
        []
      end

    %{
      kid: kid,
      state: state,
      routine: auto,
      reveal?: reveal?,
      chores:
        for(chore <- chores, do: %{chore: chore, done?: Map.has_key?(completions, chore.id)}),
      extras: extras,
      events: Calendars.today_events(kid.id, today)
    }
  end

  defp schedule_boundary(socket, now) do
    if connected?(socket) do
      ms = DateTime.diff(Routines.next_boundary(now), now, :millisecond)
      # floor guards against a timer that fires a hair early re-arming hot
      Process.send_after(self(), :boundary, max(ms, 1_000))
    end

    socket
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div
        id="kiosk"
        class="relative grid h-dvh grid-cols-2 gap-px overflow-hidden bg-base-300"
      >
        <%!-- Corner glyph (D4): dim when the calendar cache has gone stale.
             Global, not per-calendar or per-column — per-calendar diagnosis
             belongs in server logs. Sits alongside the existing (unstyled)
             socket-down disconnect indicator from Layouts.app. --%>
        <div
          :if={@calendars_stale?}
          id="calendar-stale-glyph"
          class="absolute left-4 top-4 z-10 text-base-content/30"
        >
          <.icon name="hero-clock" class="size-5" />
        </div>

        <section
          :for={
            %{
              kid: kid,
              state: state,
              routine: routine,
              chores: chores,
              extras: extras,
              events: events
            } <-
              @columns
          }
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

          <%!-- Events strip: chronological, blended per-kid + family list
               (FR-19). All-day events pin to the top (FR-22); a family
               event renders as a neutral chip + house glyph in every
               column, a personal event as the kid-color dot. --%>
          <div id={"events-#{kid.id}"} class="border-b border-base-300 px-5 py-3">
            <p :if={events == []} class="text-sm text-base-content/40">No events today</p>
            <ul :if={events != []} class="flex flex-col gap-1.5">
              <li
                :for={event <- events}
                id={"event-#{kid.id}-#{event.uid}"}
                class="flex items-center gap-2 text-sm"
              >
                <span
                  :if={!event.family?}
                  class="size-2.5 shrink-0 rounded-full"
                  style={"background-color: #{kid.color}"}
                />
                <span
                  :if={event.family?}
                  class="flex size-4 shrink-0 items-center justify-center rounded-full bg-base-300"
                >
                  <.icon name="hero-home" class="size-3 text-base-content/60" />
                </span>
                <span class="shrink-0 text-base-content/40">{event_time_label(event)}</span>
                <span class="truncate font-medium">{event.summary}</span>
              </li>
            </ul>
          </div>

          <%!-- Good Night mode (state 5, D32): the 23:00–05:00 gap. No rows,
               no extras, not expandable — corrections go to admin. --%>
          <div
            :if={state == :night}
            id={"goodnight-#{kid.id}"}
            class="flex items-center justify-center overflow-hidden bg-base-100 px-6 text-center"
          >
            <p class="text-2xl font-semibold text-base-content/60">
              {Messages.good_night()}
            </p>
          </div>

          <%!-- Chores: equal full-width rows; at ≤5 the 1fr region divides
               evenly, beyond 5 only this region scrolls (FR-6). Done = kid-color
               fill + check, emoji still visible (FR-7); tap again to undo, no
               confirmation (FR-8). phx-throttle swallows the excited rapid
               double-tap (D15). Also covers the manually re-expanded band
               (state 4, D34): same rows, all shown done, tap-to-undo. --%>
          <ul
            :if={state == :rows}
            id={"chores-#{kid.id}"}
            class="grid auto-rows-fr gap-px overflow-y-auto bg-base-300"
          >
            <.chore_row
              :for={%{chore: chore, done?: done?} <- chores}
              chore={chore}
              done?={done?}
              kid={kid}
            />
          </ul>

          <%!-- Collapse band (states 2/3, D33/D34): reveal gated by the
               active window, not pure completion. Morning additionally
               reveals extras below the band; evening never does. Tapping
               the band re-expands to the rows above. --%>
          <div :if={state == :band} class="grid grid-rows-[auto_1fr] overflow-hidden bg-base-100">
            <button
              type="button"
              id={"band-#{kid.id}"}
              phx-click="toggle-band"
              phx-value-kid-id={kid.id}
              class="flex items-center justify-center px-6 py-8 text-center transition active:scale-[0.99]"
              style={"background-color: #{kid.color}"}
            >
              <p class="text-2xl font-semibold text-white drop-shadow-sm">
                {band_message(routine)}
              </p>
            </button>

            <ul
              :if={routine == :morning}
              id={"extras-#{kid.id}"}
              class="grid auto-rows-fr gap-px overflow-y-auto bg-base-300"
            >
              <.chore_row
                :for={%{chore: chore, done?: done?} <- extras}
                chore={chore}
                done?={done?}
                kid={kid}
              />
            </ul>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :chore, :map, required: true
  attr :done?, :boolean, required: true
  attr :kid, :map, required: true

  # Shared row markup for both routine chores and extras (D34 technical
  # notes: extras are chores, so this is the same tappable row).
  defp chore_row(assigns) do
    ~H"""
    <li
      id={"chore-#{@chore.id}"}
      data-done={@done?}
      phx-click="toggle-chore"
      phx-value-chore-id={@chore.id}
      phx-throttle="1000"
      class={[
        "flex min-h-[88px] cursor-pointer select-none items-center gap-5 px-6 transition-colors",
        !@done? && "bg-base-100"
      ]}
      style={@done? && "background-color: #{@kid.color}"}
    >
      <span class="text-[2.5rem] leading-none">{@chore.icon}</span>
      <span class={["text-2xl font-semibold", @done? && "text-white drop-shadow-sm"]}>
        {@chore.name}
      </span>
      <.icon :if={@done?} name="hero-check" class="ml-auto size-10 text-white drop-shadow-sm" />
    </li>
    """
  end

  defp band_message(:morning), do: Messages.morning_complete()
  defp band_message(:evening), do: Messages.evening_complete()

  # FR-22: an event clipped at the start of today's window (it started
  # before today) shows only its end — "until 2:00 PM" — rather than a
  # start time that isn't actually today's.
  defp event_time_label(%{all_day: true}), do: "All day"

  defp event_time_label(%{clipped_start?: true, ends_at: ends_at}),
    do: "until #{format_time(ends_at)}"

  defp event_time_label(%{starts_at: starts_at}), do: format_time(starts_at)

  defp format_time(%DateTime{} = utc_time) do
    utc_time
    |> DateTime.shift_zone!(LocalTime.timezone())
    |> Calendar.strftime("%-I:%M %p")
  end
end
