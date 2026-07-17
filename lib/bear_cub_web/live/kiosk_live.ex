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
      events: Calendars.today_events(kid.id, today),
      points: Chores.points_total(kid, today)
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
              events: events,
              points: points
            } <-
              @columns
          }
          id={"kid-column-#{kid.id}"}
          class="grid grid-rows-[auto_auto_1fr_auto] overflow-hidden bg-base-100"
        >
          <%!-- Header band: the color block, not the name, is the primary
               identifier (FR-5a) — a pre-reader finds their column by color.
               Never dimmed: identity stays legible across the kitchen.
               The points badge belongs to the child, not the routine (D43):
               it renders unconditionally here, independent of the routine
               card's collapse/expand and of any routine state below. --%>
          <header
            class="relative flex items-center justify-center py-5"
            style={"background-color: #{kid.color}"}
          >
            <h1 class="text-4xl font-bold tracking-tight text-white drop-shadow-sm">
              {kid.name}
            </h1>
            <span
              id={"points-badge-#{kid.id}"}
              class="absolute right-5 flex items-center gap-1 rounded-full bg-white/20 px-3 py-1 text-lg font-bold text-white drop-shadow-sm"
            >
              <.icon name="hero-star-solid" class="size-4" />
              {points}
            </span>
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

          <%!-- Routine card: a persistent, routine-colored header (yellow for
               morning, purple for evening) sits above either the chore rows
               (expanded) or the completion message (collapsed band).
               Tapping the header toggles collapse; the tap is a no-op
               server-side unless the routine is reveal-eligible (D33/D34).
               No completion indicator on the header — collapse + the
               completion message are the signal (docs/design-language.org). --%>
          <div
            :if={state != :night}
            id={"routine-#{kid.id}"}
            class="grid grid-rows-[auto_1fr] overflow-hidden bg-base-100"
          >
            <button
              :if={state == :rows}
              type="button"
              id={"routine-header-#{kid.id}"}
              phx-click="toggle-band"
              phx-value-kid-id={kid.id}
              class="flex items-center justify-center px-4 py-3 transition active:scale-[0.99]"
              style={routine_bar_style(routine)}
            >
              <span class="text-center text-xl font-bold tracking-tight">
                {routine_title(routine)}
              </span>
            </button>

            <%!-- Chores: fixed-height full-width rows, top-aligned (empty
                 space below the last card is fine); beyond capacity only
                 this region scrolls (FR-6). Not done = routine tint fill +
                 child-color border (chore ownership); done = kid-color fill
                 + check, emoji still visible (FR-7), border merged into the
                 fill; tap again to undo, no confirmation (FR-8).
                 phx-throttle swallows the excited rapid double-tap (D15).
                 Also covers the manually re-expanded band (state 4, D34):
                 same rows, all shown done, tap-to-undo. --%>
            <ul
              :if={state == :rows}
              id={"chores-#{kid.id}"}
              class="grid max-h-full auto-rows-[6rem] gap-px self-start overflow-y-auto bg-base-300"
            >
              <.chore_row
                :for={%{chore: chore, done?: done?} <- chores}
                chore={chore}
                done?={done?}
                kid={kid}
                routine={routine}
              />
            </ul>

            <%!-- Collapse band (states 2/3, D33/D34): reveal gated by the
                 active window, not pure completion. A single bounded card —
                 routine tint fill (same token as chore cards), routine-color
                 header as its top edge, message inside — not a header
                 floating over the page background. `self-start` keeps it
                 hugging its own content height instead of stretching to
                 fill the column (docs/design-language.org). The whole card
                 is the tap target back to the rows above; shorter than a
                 chore card and border-free by design (docs/design-language.org). --%>
            <button
              :if={state == :band}
              type="button"
              id={"band-#{kid.id}"}
              phx-click="toggle-band"
              phx-value-kid-id={kid.id}
              class="flex flex-col self-start overflow-hidden text-left transition active:scale-[0.99]"
              style={"background-color: var(--routine-#{routine}-tint)"}
            >
              <span
                class="flex items-center justify-center px-4 py-3"
                style={routine_bar_style(routine)}
              >
                <span class="text-center text-xl font-bold tracking-tight">
                  {routine_title(routine)}
                </span>
              </span>
              <span class="px-4 py-3 text-center text-base font-semibold">
                {band_message(routine)}
              </span>
            </button>
          </div>

          <%!-- Extras: below the routine card, never tinted (invariant —
               docs/design-language.org). Morning-only reveal, gated with
               the band (D34 technical notes: extras are chores, so this is
               the same tappable row, just styled as a fixed neutral card). --%>
          <ul
            :if={state == :band and routine == :morning}
            id={"extras-#{kid.id}"}
            class="grid auto-rows-[6rem] gap-px overflow-y-auto bg-base-300"
          >
            <.chore_row
              :for={%{chore: chore, done?: done?} <- extras}
              chore={chore}
              done?={done?}
              kid={kid}
              routine={routine}
              extra?={true}
            />
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :chore, :map, required: true
  attr :done?, :boolean, required: true
  attr :kid, :map, required: true
  attr :routine, :atom, required: true
  attr :extra?, :boolean, default: false

  # Shared row markup for both routine chores and extras (D34 technical
  # notes: extras are chores, so this is the same tappable row) — extras
  # render on the fixed neutral card surface instead of the routine tint.
  defp chore_row(assigns) do
    ~H"""
    <li
      id={"chore-#{@chore.id}"}
      data-done={@done?}
      phx-click="toggle-chore"
      phx-value-chore-id={@chore.id}
      phx-throttle="1000"
      class="flex h-24 cursor-pointer select-none items-center gap-5 border-l-[length:var(--child-border-width)] px-6 transition-colors"
      style={chore_card_style(@done?, @extra?, @routine, @kid.color)}
    >
      <span class="text-[2.5rem] leading-none">{@chore.icon}</span>
      <span class={["text-2xl font-semibold", @done? && "text-white drop-shadow-sm"]}>
        {@chore.name}
      </span>
      <.icon :if={@done?} name="hero-check" class="ml-auto size-10 text-white drop-shadow-sm" />
    </li>
    """
  end

  # Not done: routine tint + child-color border (chore ownership). Done: full
  # kid-color fill, border merged into the fill rather than layered on top —
  # the fill is already the child's own color, so a matching border added no
  # legibility (docs/design-language.org). The border width is always
  # reserved (see the `li` class above) so completing a chore never shifts
  # its content; done just makes the border transparent instead of removing
  # it. Extras never take the routine tint — they're a fixed neutral
  # surface (docs/design-language.org).
  defp chore_card_style(true, _extra?, _routine, kid_color),
    do: "background-color: #{kid_color}; border-left-color: transparent"

  defp chore_card_style(false, true, _routine, kid_color),
    do:
      "background-color: var(--extra-card-background); border-left-color: #{kid_color}; color: var(--extra-card-content)"

  defp chore_card_style(false, false, routine, kid_color),
    do: "background-color: var(--routine-#{routine}-tint); border-left-color: #{kid_color}"

  defp routine_bar_style(routine),
    do: "background-color: var(--routine-#{routine}); color: var(--routine-#{routine}-content)"

  defp routine_title(:morning), do: "Morning Routine"
  defp routine_title(:evening), do: "Evening Routine"

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
