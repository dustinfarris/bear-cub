defmodule BearCubWeb.KioskLive do
  use BearCubWeb, :live_view

  alias BearCub.Calendars
  alias BearCub.Chores
  alias BearCub.LocalTime
  alias BearCub.Messages
  alias BearCub.Routines

  # Collapse-delay (Story 07, SC-7): the pause between the last routine
  # chore completing and the routine list collapsing, so that chore's own
  # completion stays briefly visible before the whole-routine collapse. The
  # concrete duration is implementation freedom, tuned at the on-device gate.
  @collapse_delay_ms 400

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
     |> assign(:pending_collapse, MapSet.new())
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

  # Collapse-delay (Story 07): fires once per kid whose routine just became
  # complete. Clearing the kid out of `pending_collapse` here — never
  # inside `load/2`'s own diffing — is what actually lets the routine
  # collapse once the delay has elapsed.
  def handle_info({:collapse_ready, kid_id}, socket) do
    pending_collapse = MapSet.delete(socket.assigns.pending_collapse, kid_id)
    {:noreply, socket |> assign(:pending_collapse, pending_collapse) |> load(LocalTime.now())}
  end

  defp load(socket, local_now) do
    {routine_state, auto} = Routines.current(local_now)
    night? = routine_state == :upcoming
    today = DateTime.to_date(local_now)

    # done today? — derived, never stored (design §2)
    completions = Chores.current_completions(today)
    # A first-ever load (mount) has nothing to diff against — treat it as
    # "nothing just changed" so an already-complete routine renders its
    # true current state instead of a spurious collapse-delay (Story 07).
    old_completions = socket.assigns[:completions] || completions
    # failed today? — kiosk failed-chore marking (D45, D46), independent of
    # done-today: combined with `completions` below to tell "failed and not
    # yet redone" from "failed, then redone"
    failed_ids = Chores.failed_chore_ids(today)
    expanded = socket.assigns.expanded
    pending_collapse = socket.assigns.pending_collapse

    {columns, pending_collapse} =
      Enum.map_reduce(Chores.list_kids(), pending_collapse, fn kid, pending_collapse ->
        build_column(
          kid,
          auto,
          night?,
          completions,
          old_completions,
          failed_ids,
          today,
          expanded,
          pending_collapse
        )
      end)

    # Collapse-delay (Story 07, SC-7): a kid newly added to
    # `pending_collapse` this pass just had their last routine chore
    # completed — schedule the delayed reveal, once per transition.
    if connected?(socket) do
      for kid_id <- MapSet.difference(pending_collapse, socket.assigns.pending_collapse) do
        Process.send_after(self(), {:collapse_ready, kid_id}, @collapse_delay_ms)
      end
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
      pending_collapse: pending_collapse,
      calendars_stale?: Calendars.any_stale?(local_now)
    )
  end

  defp build_column(
         kid,
         auto,
         night?,
         completions,
         old_completions,
         failed_ids,
         today,
         expanded,
         pending_collapse
       ) do
    chores = if night?, do: [], else: Chores.list_chores(kid, Atom.to_string(auto))
    complete? = chores != [] and Enum.all?(chores, &Map.has_key?(completions, &1.id))

    # Collapse-delay (Story 07, SC-7): a routine that just now became fully
    # complete enters `pending_collapse` and stays in :rows through this
    # render — the last chore's own completion stays briefly visible before
    # the routine list collapses. `handle_info({:collapse_ready, ...})` is
    # what clears the entry once the delay has elapsed.
    was_complete? = chores != [] and Enum.all?(chores, &Map.has_key?(old_completions, &1.id))

    pending_collapse =
      cond do
        complete? and not was_complete? -> MapSet.put(pending_collapse, kid.id)
        not complete? -> MapSet.delete(pending_collapse, kid.id)
        true -> pending_collapse
      end

    delaying? = MapSet.member?(pending_collapse, kid.id)
    reveal? = not night? and complete? and not delaying?
    kid_expanded? = MapSet.member?(expanded, kid.id)

    state =
      cond do
        night? -> :night
        reveal? and not kid_expanded? -> :band
        true -> :rows
      end

    chore_rows = build_rows(chores, completions, failed_ids)

    extras =
      if state == :band and auto == :morning do
        build_rows(Chores.list_extras(kid, today), completions, failed_ids)
      else
        []
      end

    column = %{
      kid: kid,
      state: state,
      routine: auto,
      reveal?: reveal?,
      chores: chore_rows,
      extras: extras,
      # The routine-penalty strip is a single capped indicator, modeled on
      # the boolean "any routine chore failed-and-not-redone" rather than a
      # per-chore loop (D45, D46) — only relevant in the expanded rows state.
      routine_penalty?: state == :rows and Enum.any?(chore_rows, & &1.failed?),
      events: Calendars.today_events(kid.id, today),
      points: Chores.points_total(kid, today)
    }

    {column, pending_collapse}
  end

  # A chore/extra reads "failed and not yet redone" (warning shown) only
  # while it has no live completion — once redone, `done?` flips true and
  # the warning naturally disappears, even though `failed_ids` still
  # remembers the fail for the day (D45, D46, D49).
  defp build_rows(chores, completions, failed_ids) do
    for chore <- chores do
      done? = Map.has_key?(completions, chore.id)
      %{chore: chore, done?: done?, failed?: not done? and MapSet.member?(failed_ids, chore.id)}
    end
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
              routine_penalty?: routine_penalty?,
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
            <div :if={state == :rows} class="grid grid-rows-[auto_1fr] overflow-hidden">
              <%!-- Routine-penalty strip: a single capped −R shown once while
                   any routine chore is failed-and-not-redone (D45, D46) —
                   never a per-chore sum (two fails still show one −R, not
                   −2R). Explicit row-start so the chore list below always
                   lands in the 1fr track, strip present or not. --%>
              <div
                :if={routine_penalty?}
                id={"routine-penalty-#{kid.id}"}
                class="row-start-1 flex items-center justify-center gap-2 bg-warning px-4 py-2 text-base font-bold text-warning-content"
              >
                <.icon name="hero-exclamation-triangle" class="size-5" />
                <span>−{Routines.bonus()}</span>
              </div>

              <ul
                id={"chores-#{kid.id}"}
                class="row-start-2 grid max-h-full auto-rows-[6rem] gap-px self-start overflow-y-auto bg-base-300"
              >
                <.chore_row
                  :for={%{chore: chore, done?: done?, failed?: failed?} <- chores}
                  chore={chore}
                  done?={done?}
                  failed?={failed?}
                  kid={kid}
                  routine={routine}
                />
              </ul>
            </div>

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
              :for={%{chore: chore, done?: done?, failed?: failed?} <- extras}
              chore={chore}
              done?={done?}
              failed?={failed?}
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
  attr :failed?, :boolean, default: false
  attr :kid, :map, required: true
  attr :routine, :atom, required: true
  attr :extra?, :boolean, default: false

  # Shared row markup for both routine chores and extras (D34 technical
  # notes: extras are chores, so this is the same tappable row) — extras
  # render on the fixed neutral card surface instead of the routine tint.
  # A failed-and-not-redone card (D45, D46) shows a warning icon; a failed
  # extra also carries its own −N, but a failed routine chore never does —
  # its impact is the single capped routine-penalty strip shown once above.
  defp chore_row(assigns) do
    ~H"""
    <li
      id={"chore-#{@chore.id}"}
      data-done={@done?}
      data-failed={@failed?}
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
      <.icon
        :if={@failed? and not @extra?}
        name="hero-exclamation-triangle"
        class="ml-auto size-10 text-warning"
      />
      <span
        :if={@failed? and @extra?}
        id={"chore-penalty-#{@chore.id}"}
        class="ml-auto flex items-center gap-2 text-warning"
      >
        <.icon name="hero-exclamation-triangle" class="size-8" />
        <span class="text-2xl font-bold">−{@chore.points}</span>
      </span>
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
