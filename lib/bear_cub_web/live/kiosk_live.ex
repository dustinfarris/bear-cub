defmodule BearCubWeb.KioskLive do
  use BearCubWeb, :live_view

  alias BearCub.Calendars
  alias BearCub.Chores
  alias BearCub.LocalTime
  alias BearCub.Messages
  alias BearCub.Points
  alias BearCub.Rewards
  alias BearCub.Routines

  # Collapse-delay (Story 07, SC-7): the pause between the last routine
  # chore completing and the routine list collapsing, so that chore's own
  # completion stays briefly visible before the whole-routine collapse. The
  # concrete duration is implementation freedom, tuned at the on-device gate.
  @collapse_delay_ms 400

  # Settle-delay (D106): the pause between a routine chore completing and
  # its row sinking to the done stack. The row holds its done treatment in
  # place first, so the tap is answered where the finger is — the done
  # stack can be below the fold. Same shape as the collapse delay above;
  # the duration is tuned at the local gate, not design-pinned.
  @settle_delay_ms 700

  # Reward-shop idle auto-return (Story 05, D65): how long a column stays
  # open with no tap before it snaps back to normal, in case a child wanders
  # off mid-shop. Deliberately not design-pinned — tuned at the on-device
  # gate exactly like @collapse_delay_ms was; 30s is the starting guess.
  @rewards_idle_ms 30_000

  @impl true
  def mount(_params, _session, socket) do
    # A deploy leaves the tablet patching new markup into a document whose
    # stylesheet predates it (see BearCubWeb.StaticChanged). Reload rather
    # than render into it: an unstyled kiosk is nobody's job to notice, and
    # there is no in-progress work here to protect.
    if socket.assigns.static_changed? do
      {:ok, redirect(socket, to: ~p"/")}
    else
      mount_kiosk(socket)
    end
  end

  defp mount_kiosk(socket) do
    if connected?(socket) do
      Chores.subscribe()
      Calendars.subscribe()
      Rewards.subscribe()
    end

    # one clock read per mount — two could straddle a window edge
    now = LocalTime.now()

    {:ok,
     socket
     |> assign(:expanded, MapSet.new())
     |> assign(:pending_collapse, MapSet.new())
     |> assign(:settling, MapSet.new())
     |> assign(:rewards, MapSet.new())
     |> assign(:rewards_timers, %{})
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
          {:noreply, load(socket, now)}
        else
          # a racing double-complete hits the partial unique index — already done
          Chores.complete_chore(chore, now, "kiosk")
          {:noreply, socket |> settle_later(chore.id) |> load(now)}
        end
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

  # The gift button toggles the shop (Story 08, D75): opens it when closed,
  # closes it when open, in either glyph state. `:rewards` is a
  # socket-level MapSet of kid ids, exactly like `@expanded` — never
  # persisted.
  def handle_event("open-shop", %{"kid-id" => id}, socket) do
    kid_id = String.to_integer(id)

    socket =
      if MapSet.member?(socket.assigns.rewards, kid_id) do
        socket
        |> cancel_rewards_idle_timer(kid_id)
        |> assign(:rewards, MapSet.delete(socket.assigns.rewards, kid_id))
      else
        socket
        |> assign(:rewards, MapSet.put(socket.assigns.rewards, kid_id))
        |> arm_rewards_idle_timer(kid_id)
      end

    {:noreply, load(socket, LocalTime.now())}
  end

  # Explicit ✕ dismiss (D65): cancels the idle timer and returns the
  # column to its normal state.
  def handle_event("dismiss-shop", %{"kid-id" => id}, socket) do
    kid_id = String.to_integer(id)

    socket =
      socket
      |> cancel_rewards_idle_timer(kid_id)
      |> assign(:rewards, MapSet.delete(socket.assigns.rewards, kid_id))

    {:noreply, load(socket, LocalTime.now())}
  end

  # One tap to ask (D65, D63, D75): no affordability/availability/audience
  # check here — the card's own tappability (derived by
  # `Rewards.card_state/5`) is the whole guard, and a race that hits the
  # duplicate-ask index (D77) is treated as already-asked, per
  # `request_redemption/3`'s own doc. The shop stays open (D75): the
  # tapped card transitions in place to its pending rendering on the next
  # `load/2`, so this is an in-view tap that resets the idle timer rather
  # than one that closes the view.
  def handle_event("request-reward", %{"kid-id" => id, "reward-id" => reward_id}, socket) do
    now = LocalTime.now()
    kid_id = String.to_integer(id)

    case {Chores.get_kid(kid_id), Rewards.get_reward(reward_id)} do
      {%Chores.Kid{} = kid, %Rewards.Reward{} = reward} ->
        Rewards.request_redemption(kid, reward, now)

      _ ->
        :ok
    end

    socket = arm_rewards_idle_timer(socket, kid_id)

    {:noreply, load(socket, now)}
  end

  # One tap to take it back (D76): withdraws the kid's own pending request
  # for this reward, with no confirmation — re-asking is the undo. The
  # shop stays open and the card falls back to its plain state on the
  # next `load/2`; this is also an in-view tap and resets the idle timer.
  def handle_event("withdraw-request", %{"kid-id" => id, "reward-id" => reward_id}, socket) do
    now = LocalTime.now()
    kid_id = String.to_integer(id)
    reward_id = String.to_integer(reward_id)
    today = DateTime.to_date(now)

    case Rewards.get_pending_redemption(kid_id, reward_id, today) do
      nil -> :ok
      redemption -> Rewards.withdraw_redemption(redemption, now)
    end

    socket = arm_rewards_idle_timer(socket, kid_id)

    {:noreply, load(socket, now)}
  end

  @impl true
  def handle_info(:chores_changed, socket) do
    {:noreply, load(socket, LocalTime.now())}
  end

  def handle_info(:calendars_changed, socket) do
    {:noreply, load(socket, LocalTime.now())}
  end

  # Story 04, D71: a redemption (any of Rewards' write paths) changes a
  # kid's balance — the points badge (D43) must reflect it live. The
  # reward view / banner button / card states this topic also feeds are
  # Story 05's job; this clause only keeps the badge fresh.
  def handle_info(:rewards_changed, socket) do
    {:noreply, load(socket, LocalTime.now())}
  end

  def handle_info(:boundary, socket) do
    # Window handoff (FR-3) and the midnight re-render of derived day state
    # (design §2) are all one event: recompute everything and schedule the
    # next boundary. The reward shop is cleared here too (D65): `:rewards`
    # does not carry across a routine boundary re-render.
    now = LocalTime.now()

    socket =
      socket
      |> cancel_all_rewards_idle_timers()
      |> assign(:rewards, MapSet.new())
      |> load(now)
      |> schedule_boundary(now)

    {:noreply, socket}
  end

  # Idle auto-return (D65): fires when a shopping column has seen no tap
  # for `@rewards_idle_ms`. Harmless no-op if the kid already isn't
  # shopping (dismissed, requested, or a boundary already cleared it) —
  # including a stray fire at night, when no column could ever be open.
  def handle_info({:rewards_idle, kid_id}, socket) do
    socket =
      socket
      |> assign(:rewards_timers, Map.delete(socket.assigns.rewards_timers, kid_id))
      |> assign(:rewards, MapSet.delete(socket.assigns.rewards, kid_id))

    {:noreply, load(socket, LocalTime.now())}
  end

  # Collapse-delay (Story 07): fires once per kid whose routine just became
  # complete. Clearing the kid out of `pending_collapse` here — never
  # inside `load/2`'s own diffing — is what actually lets the routine
  # collapse once the delay has elapsed.
  def handle_info({:collapse_ready, kid_id}, socket) do
    pending_collapse = MapSet.delete(socket.assigns.pending_collapse, kid_id)
    {:noreply, socket |> assign(:pending_collapse, pending_collapse) |> load(LocalTime.now())}
  end

  # Settle-delay (D106): the held row may sink now. A stray message — the
  # chore was undone mid-hold, or never held — is a harmless no-op.
  def handle_info({:settled, chore_id}, socket) do
    settling = MapSet.delete(socket.assigns.settling, chore_id)
    {:noreply, socket |> assign(:settling, settling) |> load(LocalTime.now())}
  end

  defp settle_later(socket, chore_id) do
    Process.send_after(self(), {:settled, chore_id}, @settle_delay_ms)
    assign(socket, :settling, MapSet.put(socket.assigns.settling, chore_id))
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
    settling = socket.assigns.settling
    rewards = socket.assigns.rewards

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
          pending_collapse,
          settling,
          rewards
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
      night?: night?,
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
         pending_collapse,
         settling,
         rewards
       ) do
    chores = if night?, do: [], else: Chores.list_chores(kid, Atom.to_string(auto))
    complete? = chores != [] and Enum.all?(chores, &Map.has_key?(completions, &1.id))

    # Routine-day `failed?` (D45, D47): any of today's routine chores carries
    # a failed completion, independent of done-today — a redo can leave
    # `complete? = true` and `failed? = true` at once. The completion icon's
    # badge reads that combination as "forfeited" (forfeited? = failed?).
    failed? = Enum.any?(chores, &MapSet.member?(failed_ids, &1.id))

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
    shopping? = not night? and MapSet.member?(rewards, kid.id)

    # Good standing (Story 05, D95): the band/ring live only in the morning
    # window, and computed only then — the only time the kiosk ever shows
    # them. Gated on `delaying?` rather than `reveal?`: `reveal?` is false
    # for the vacuously-satisfied empty-roster kid (D92), which would hide
    # their band forever; `delaying?` is false for that kid since they
    # never enter `pending_collapse`, so the band shows from window open.
    standing? =
      auto == :morning and not night? and
        Chores.standing(kid, today).standing? and not delaying?

    # Early bird (D100, D101): read only where the bird can render — the
    # completion icon's morning form — so the evening column and the
    # incomplete column pay nothing for it. Forfeiture on a fail is inside
    # the predicate, matching the bonus badge's own "not if failed" rule.
    early_bird? = reveal? and auto == :morning and Chores.early_bird?(kid, today)

    state =
      cond do
        night? -> :night
        shopping? -> :rewards
        reveal? and not kid_expanded? -> :band
        true -> :rows
      end

    # Done rows sink (D105): pending rows keep authored order on top, done
    # rows stack beneath them newest-first, so the kid-color mass grows
    # downward as the routine fills in. Extras below are not sunk.
    chore_rows =
      chores |> build_rows(completions, failed_ids) |> sink_done(completions, settling)

    extras =
      if state == :band and auto == :morning do
        build_rows(Chores.list_extras(kid, today), completions, failed_ids)
      else
        []
      end

    # Gift-button pending state (Story 05, D65, D67): read regardless of
    # `state`, since the banner (and its button) render in every non-night
    # state, not only while shopping.
    pending_request? = not night? and Rewards.any_pending?(kid.id, today)

    # The catalog itself is only ever fetched while this kid is actually
    # shopping — the sibling column pays nothing for the reward domain.
    catalog = if state == :rewards, do: build_catalog(kid, today), else: []

    column = %{
      kid: kid,
      state: state,
      routine: auto,
      reveal?: reveal?,
      complete?: complete?,
      standing?: standing?,
      early_bird?: early_bird?,
      failed?: failed?,
      chores: chore_rows,
      extras: extras,
      # The routine-penalty strip is a single capped indicator, modeled on
      # the boolean "any routine chore failed-and-not-redone" rather than a
      # per-chore loop (D45, D46) — only relevant in the expanded rows state.
      routine_penalty?: state == :rows and Enum.any?(chore_rows, & &1.failed?),
      events: Calendars.today_events(kid.id, today),
      points: Points.total(kid, today),
      pending_request?: pending_request?,
      catalog: catalog
    }

    {column, pending_collapse}
  end

  # Reward cards, in catalog order, resolved through the seven-row
  # precedence table (D66/D77) and filtered to what's actually rendered —
  # rows 1 and 2 render nothing, so an `:absent` card never reaches the
  # template at all. `pending_total` (D77's reserve) is hoisted here once
  # per column, exactly as `balance` already is.
  defp build_catalog(kid, today) do
    balance = Points.balance(kid, today)
    pending_total = Rewards.pending_total(kid.id, today)

    kid
    |> Rewards.list_rewards(today)
    |> Enum.map(
      &%{reward: &1, state: Rewards.card_state(&1, kid.id, balance, pending_total, today)}
    )
    |> Enum.reject(&(&1.state == :absent))
  end

  # A card's tap either asks or takes the ask back (D76) — row 3's own
  # tap is a withdraw, never a re-ask, since asking again is the undo.
  defp reward_card_click(:available), do: "request-reward"
  defp reward_card_click(:pending), do: "withdraw-request"
  defp reward_card_click(_), do: nil

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

  # Pending rows first in authored order; done rows after, most recent
  # completion first (D105). `completed_at` is second-resolution, so the
  # completion id breaks ties in the same second — a later tap is a later
  # row. A done row still settling (D106) is not yet sunk: it keeps its
  # authored place among the pending rows for the hold, marked `sunk?:
  # false` so the template renders it done but in the slot group.
  defp sink_done(rows, completions, settling) do
    rows =
      for row <- rows,
          do: Map.put(row, :sunk?, row.done? and not MapSet.member?(settling, row.chore.id))

    {done, pending} = Enum.split_with(rows, & &1.sunk?)

    done =
      Enum.sort_by(
        done,
        fn %{chore: chore} ->
          completion = Map.fetch!(completions, chore.id)
          {DateTime.to_unix(completion.completed_at), completion.id}
        end,
        :desc
      )

    pending ++ done
  end

  defp schedule_boundary(socket, now) do
    if connected?(socket) do
      ms = DateTime.diff(Routines.next_boundary(now), now, :millisecond)
      # floor guards against a timer that fires a hair early re-arming hot
      Process.send_after(self(), :boundary, max(ms, 1_000))
    end

    socket
  end

  # Idle auto-return timer (Story 05, D65): armed on open, replaced (not
  # merely reset) on each tap inside the view. Cancelling any existing
  # timer before arming a new one is what makes "reset" correct — an
  # earlier still-pending timer message would otherwise close the view
  # early even though the child just interacted with it.
  defp arm_rewards_idle_timer(socket, kid_id) do
    socket = cancel_rewards_idle_timer(socket, kid_id)
    ref = Process.send_after(self(), {:rewards_idle, kid_id}, @rewards_idle_ms)
    assign(socket, :rewards_timers, Map.put(socket.assigns.rewards_timers, kid_id, ref))
  end

  defp cancel_rewards_idle_timer(socket, kid_id) do
    case Map.get(socket.assigns.rewards_timers, kid_id) do
      nil ->
        socket

      ref ->
        Process.cancel_timer(ref)
        assign(socket, :rewards_timers, Map.delete(socket.assigns.rewards_timers, kid_id))
    end
  end

  defp cancel_all_rewards_idle_timers(socket) do
    Enum.each(socket.assigns.rewards_timers, fn {_kid_id, ref} -> Process.cancel_timer(ref) end)
    assign(socket, :rewards_timers, %{})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div
        id="kiosk"
        class="relative grid h-dvh grid-cols-2 gap-4 p-4 overflow-hidden bg-base-300"
      >
        <%!-- Night screen (D56, supersedes D32's per-column Good Night
             message): the 23:00–05:00 gap is a single dark screen with one
             large evening-colored moon and nothing else — no columns, no
             banners, no points badges (the D43 always-visible badge is
             scoped to the waking windows), no events, no stale glyph.
             Corrections still go to admin; nothing here is tappable. --%>
        <div
          :if={@night?}
          id="night-screen"
          class="col-span-2 flex items-center justify-center bg-stone-950"
          style="color: var(--routine-evening)"
        >
          <.icon name="hero-moon-solid" class="size-52" />
        </div>

        <%!-- Corner glyph (D4): dim when the calendar cache has gone stale.
             Global, not per-calendar or per-column — per-calendar diagnosis
             belongs in server logs. Sits alongside the existing (unstyled)
             socket-down disconnect indicator from Layouts.app. --%>
        <div
          :if={@calendars_stale? and not @night?}
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
              reveal?: reveal?,
              complete?: complete?,
              standing?: standing?,
              early_bird?: early_bird?,
              failed?: failed?,
              chores: chores,
              extras: extras,
              routine_penalty?: routine_penalty?,
              events: events,
              points: points,
              pending_request?: pending_request?,
              catalog: catalog
            } <-
              @columns
          }
          :if={!@night?}
          id={"kid-column-#{kid.id}"}
          class={[
            "grid grid-rows-[auto_auto_1fr] overflow-hidden bg-base-100 rounded-lg",
            standing? &&
              "ring-4 shadow-[0_0_8px_6px_rgba(245,245,0,0.92)] ring-success"
          ]}
        >
          <%!-- Header band: the color block, not the name, is the primary
               identifier (FR-5a) — a pre-reader finds their column by color.
               Never dimmed: identity stays legible across the kitchen.
               The points badge belongs to the child, not the routine (D43):
               it renders unconditionally here, independent of the routine
               card's collapse/expand and of any routine state below. The
               completion icon (D44) is the retired routine header bar's
               replacement: it is now the routine card's collapse/expand
               affordance, so it renders whenever the routine is complete
               and reveal-eligible (`reveal?`), in both the collapsed band
               and the manually re-expanded rows (D47). --%>
          <header
            class="relative flex items-center justify-center py-5"
            style={"background-color: #{kid.color}"}
          >
            <button
              :if={reveal?}
              type="button"
              id={"completion-icon-#{kid.id}"}
              phx-click="toggle-band"
              phx-value-kid-id={kid.id}
              class="absolute left-5 flex items-center justify-center transition active:scale-[0.99]"
            >
              <span class="relative flex items-center justify-center">
                <.icon
                  name={completion_icon_name(routine)}
                  class="size-14 text-white drop-shadow-sm"
                />
                <%!-- Bonus badge (D44, D47, D104): shown only "if not
                     forfeited" — forfeited? = failed?, the routine-day
                     boolean. A forfeited bonus shows no badge at all rather
                     than a zeroed one; the icon itself still toggles. On an
                     early morning the badge carries R + E as one number
                     (D104), and the EARLY pill below the sun says why. --%>
                <span
                  :if={not failed?}
                  id={"completion-badge-#{kid.id}"}
                  class="absolute -right-4 -top-1 flex items-center rounded-full border-2 bg-success px-2 py-0.5 font-reward text-sm font-black text-success-content drop-shadow-sm"
                  style={"border-color: #{kid.color}"}
                >
                  +{Routines.bonus() + if(early_bird?, do: Routines.early_bird_bonus(), else: 0)}
                </span>
                <%!-- Early bird pill (D100, D104): a white EARLY pill under
                     the sun in the kid's own color. Same forfeit rule as the
                     badge — `early_bird?` is already false when failed. --%>
                <span
                  :if={early_bird?}
                  id={"early-bird-#{kid.id}"}
                  class="absolute -bottom-1.5 left-1/2 -translate-x-1/2 rounded-full bg-white px-2 py-0.5 font-reward text-xs font-black tracking-wide drop-shadow-sm"
                  style={"color: #{kid.color}"}
                >
                  EARLY
                </span>
              </span>
            </button>
            <h1 class="font-reward text-4xl font-black tracking-tight text-white drop-shadow-sm">
              {kid.name}
            </h1>
            <%!-- Points badge + gift button (Story 05, D65): grouped on the
                 right — badge and shop are the same economy, so they read
                 as one unit. The badge's own tap gesture stays unbound
                 (the deferred points-stats affordance is not precluded);
                 the gift button is a distinct gesture, always tappable,
                 opening the shop regardless of the pending state its own
                 glyph shows. --%>
            <div class="absolute right-5 flex items-center gap-2">
              <span
                id={"points-badge-#{kid.id}"}
                class="flex items-center gap-1 rounded-full bg-white/20 px-3 py-1 font-reward text-lg font-black text-white drop-shadow-sm"
              >
                <.icon name="hero-star-solid" class="size-4" />
                {points}
              </span>
              <button
                type="button"
                id={"gift-button-#{kid.id}"}
                phx-click="open-shop"
                phx-value-kid-id={kid.id}
                data-pending={pending_request?}
                class="flex size-9 items-center justify-center rounded-full bg-white/20 text-xl leading-none transition active:scale-[0.99]"
              >
                <%= if pending_request? do %>
                  ⏳
                <% else %>
                  🎁
                <% end %>
              </button>
            </div>
          </header>

          <%!-- Standing band (Story 05, D95, D97, D98, D99): renders only
               while `standing?` (already window- and delay-gated in
               `build_column/10`) — never text, just stars, so it reads for
               a pre-reader across the room. Thirteen uniform size-9 stars
               (D99, dropping D98's five/three/five size arc after on-screen
               review). It survives the reward shop below (D97: standing is
               a property of the child's day, not of which body view is
               open), which is why it sits above both branches rather than
               inside either. --%>
          <div
            :if={standing?}
            id={"standing-band-#{kid.id}"}
            class="row-start-2 flex h-16 min-w-full items-center justify-center gap-4 bg-success overflow-visible"
          >
            <div class="w-max whitespace-nowrap">
              <.icon
                :for={_ <- 1..13}
                name="hero-star-solid"
                class="size-9 text-success-content"
              />
            </div>
          </div>

          <%!-- Column body: either the normal routine region (events,
               routine card, extras) or the reward shop (Story 05, D65) —
               the shop replaces the whole body, never sits beside it, so
               the 5-chore no-scroll budget (FR-6) is untouched by
               construction. The banner above is shared by both. --%>
          <div
            :if={state != :rewards}
            class="row-start-3 grid grid-rows-[auto_auto_1fr_auto] overflow-hidden"
          >
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

            <%!-- Stake bar (D105): the routine's all-or-nothing prize and
                 progress toward it, with no words — a routine-colored icon,
                 one segment per chore filling in the kid's color, and the
                 single +R chip (routine chores carry no per-chore number).
                 Paid (every chore done): segments, chip and ground all go
                 success-green, the app's one "you earned something" color.
                 Forfeited (a routine chore failed): the chip disappears,
                 exactly as the header badge does (D47); the segments stay.
                 Present in the rows and band states alike — the band is the
                 paid state, not a different card — and absent in the shop. --%>
            <div
              id={"stake-bar-#{kid.id}"}
              data-paid={complete?}
              class={[
                "flex items-center gap-3 border-b px-4 py-3 transition-colors duration-300",
                complete? && "border-[color:var(--paid-edge)] bg-[color:var(--paid-tint)]"
              ]}
              style={
                if(complete?,
                  do: nil,
                  else:
                    "background-color: var(--routine-#{routine}-tint); border-color: var(--routine-#{routine}-edge)"
                )
              }
            >
              <span class="flex shrink-0" style={"color: var(--routine-#{routine})"}>
                <.icon name={completion_icon_name(routine)} class="size-8" />
              </span>
              <%!-- Filled segments lead, left to right, as a progress bar
                   fills — the segments count completions, they are not the
                   rows (which sink done-last). --%>
              <div class="grid flex-1 auto-cols-fr grid-flow-col gap-1.5">
                <span
                  :for={done? <- Enum.sort_by(chores, &(not &1.done?)) |> Enum.map(& &1.done?)}
                  data-segment
                  data-filled={done?}
                  class={[
                    "block h-3.5 rounded transition-colors duration-300",
                    complete? && "bg-success"
                  ]}
                  style={stake_segment_style(done?, complete?, routine, kid.color)}
                />
              </div>
              <span
                :if={not failed?}
                id={"stake-chip-#{kid.id}"}
                class={[
                  "flex shrink-0 items-center rounded-full px-3 py-0.5 font-reward text-lg font-black transition-colors duration-300",
                  if(complete?,
                    do: "bg-success text-success-content drop-shadow-sm",
                    else: "bg-base-content/10 text-base-content/80"
                  )
                ]}
              >
                +{Routines.bonus()}
              </span>
            </div>

            <%!-- Routine card: either the chore rows (normal or manually
                 re-expanded) or the completion message (collapsed band). The
                 persistent routine header bar is retired (D44, D48) — the
                 banner completion icon above is now the sole collapse/expand
                 affordance; a tap is a no-op server-side unless the routine
                 is reveal-eligible (D33/D34). Columns never render at night
                 (D56), so no :night state reaches this markup. --%>
            <div id={"routine-#{kid.id}"} class="overflow-hidden bg-base-100">
              <%!-- Chores: fixed-height full-width rows, top-aligned (empty
                   space below the last card is fine); beyond capacity only
                   this region scrolls (FR-6). A done row shrinks a little
                   (h-24 → h-20) — a quiet completion signal that also buys
                   back vertical room for the no-scroll budget.
                   Not done = a dashed slot in the routine tint (D105);
                   done = kid-color fill + circled check, emoji still visible
                   (FR-7), sunk beneath the pending rows; tap again to undo,
                   no confirmation (FR-8).
                   phx-throttle swallows the excited rapid double-tap (D15).
                   Also covers the manually re-expanded band (state 4, D34):
                   same rows, all shown done, tap-to-undo. --%>
              <div :if={state == :rows} class="grid h-full grid-rows-[auto_1fr] overflow-hidden">
                <%!-- Routine-penalty strip: a single capped −R shown once while
                     any routine chore is failed-and-not-redone (D45, D46) —
                     never a per-chore sum (two fails still show one −R, not
                     −2R). Explicit row-start so the chore list below always
                     lands in the 1fr track, strip present or not. --%>
                <div
                  :if={routine_penalty?}
                  id={"routine-penalty-#{kid.id}"}
                  class="row-start-1 flex items-center justify-center gap-2 bg-warning px-4 py-2 font-reward text-base font-black text-warning-content"
                >
                  <.icon name="hero-exclamation-triangle" class="size-5" />
                  <span>−{Routines.bonus()}</span>
                </div>

                <%!-- Two stacks (D105): pending rows as dashed slots in a
                     padded group, done rows flush beneath as one kid-color
                     mass — `sink_done/2` has already ordered the list, so
                     this only splits it. Slot padding (10px) + border (3px)
                     + row padding (14px) = the done row's 27px, so the emoji
                     column lines up across both stacks. --%>
                <div
                  id={"chores-#{kid.id}"}
                  class="row-start-2 max-h-full self-start overflow-y-auto"
                >
                  <ul
                    :if={Enum.any?(chores, &(not &1.sunk?))}
                    class="flex flex-col gap-2 p-2.5"
                  >
                    <.chore_row
                      :for={%{chore: chore, done?: done?, failed?: failed?, sunk?: false} <- chores}
                      chore={chore}
                      done?={done?}
                      failed?={failed?}
                      kid={kid}
                      routine={routine}
                      slot?={true}
                    />
                  </ul>
                  <ul :if={Enum.any?(chores, & &1.sunk?)} class="flex flex-col">
                    <.chore_row
                      :for={%{chore: chore, sunk?: true} <- chores}
                      chore={chore}
                      done?={true}
                      kid={kid}
                      routine={routine}
                    />
                  </ul>
                </div>
              </div>

              <%!-- Collapse band (states 2/3, D33/D34): reveal gated by the
                   active window, not pure completion. A single bounded card —
                   message inside, no tint fill (dropped, D98); no header bar
                   edge (retired, D44, D48). `self-start` keeps it hugging its
                   own content height instead of stretching to fill the
                   column (docs/design-language.org). The banner completion
                   icon above is the tap target back to the rows, not the
                   card itself (D44). --%>
              <div
                :if={state == :band}
                id={"band-#{kid.id}"}
                class="flex flex-col self-start"
              >
                <span class="px-4 py-3 text-center font-reward text-lg font-extrabold">
                  {band_message(routine)}
                </span>
              </div>
            </div>

            <%!-- Extras: below the routine card, never tinted (invariant —
                 docs/design-language.org). Morning-only reveal, gated with
                 the band (D34 technical notes: extras are chores, so this is
                 the same tappable row, just styled as a fixed neutral card). --%>
            <ul
              :if={state == :band and routine == :morning}
              id={"extras-#{kid.id}"}
              class="grid auto-rows-min gap-px overflow-y-auto bg-base-300"
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
          </div>

          <%!-- Reward shop (Story 05/08, D65-D67, D75-D77): one tap to ask,
               one tap to take it back — no modal, no confirmation either
               way — the seven-row precedence table (D66/D77) is the whole
               guard, so an unaffordable/unavailable/claimed/declined card
               carries no phx-click at all and is inert under a tap; a
               pending card's phx-click withdraws rather than re-asking. --%>
          <div
            :if={state == :rewards}
            id={"rewards-#{kid.id}"}
            class="row-start-3 grid grid-rows-[auto_1fr] overflow-hidden"
          >
            <div class="flex items-center justify-between border-b border-base-300 px-5 py-3">
              <span class="text-sm font-semibold text-base-content/60">Shop</span>
              <button
                type="button"
                id={"dismiss-shop-#{kid.id}"}
                phx-click="dismiss-shop"
                phx-value-kid-id={kid.id}
                class="flex size-8 items-center justify-center rounded-full text-base-content/60 transition active:scale-[0.99]"
              >
                <.icon name="hero-x-mark" class="size-6" />
              </button>
            </div>

            <ul
              id={"reward-list-#{kid.id}"}
              class="grid auto-rows-min gap-px overflow-y-auto bg-base-300"
            >
              <li
                :for={%{reward: reward, state: card_state} <- catalog}
                id={"reward-card-#{reward.id}-#{kid.id}"}
                data-card-state={card_state}
                phx-click={reward_card_click(card_state)}
                phx-value-kid-id={kid.id}
                phx-value-reward-id={reward.id}
                phx-throttle="1000"
                class={
                  [
                    "flex h-24 items-center gap-5 px-6 transition-all",
                    # Pending (row 3) is tappable too — its tap withdraws
                    # (D76) — so it shares the tappable treatment with
                    # available (row 7).
                    card_state in [:available, :pending] && "cursor-pointer active:scale-[0.99]",
                    # Rows 4-6 (declined/claimed/locked) share one dim
                    # treatment (D66) — pending (row 3) is its own untappable
                    # treatment, carrying the banner's own =⏳= glyph rather
                    # than joining the dim group.
                    card_state in [:declined, :claimed, :locked] && "opacity-45"
                  ]
                }
                style="background-color: var(--extra-card-background); color: var(--extra-card-content)"
              >
                <span class="text-[2.5rem] leading-none">{reward.icon}</span>
                <span class="font-reward text-2xl font-extrabold">{reward.name}</span>
                <span class="ml-auto flex items-center gap-1 font-reward text-lg font-black">
                  <.icon name="hero-star-solid" class="size-4" />
                  {reward.points}
                </span>
                <span :if={card_state == :pending} class="text-3xl leading-none">⏳</span>
                <%!-- Declined/claimed carry color, not just glyph (design-
                     language dim+glyph Ruling, amended 2026-07-25): an
                     uncolored ✕ reads as a close control on a surface that
                     has one, so declined is error red; claimed is success
                     green, the same family the +N chip carries. Locked
                     stays neutral — it is a state, not a verdict. --%>
                <.icon
                  :if={card_state == :declined}
                  name="hero-x-mark"
                  class="size-9 text-error"
                />
                <.icon :if={card_state == :claimed} name="hero-check" class="size-9 text-success" />
                <.icon
                  :if={card_state == :locked}
                  name="hero-lock-closed"
                  class="size-9 text-base-content/60"
                />
              </li>
            </ul>
          </div>
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
  # In the slot group: a done row here is mid-hold (D106) — it keeps the
  # slot's size and corners, filled and solid-edged, until it sinks.
  attr :slot?, :boolean, default: false

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
      class={
        [
          "flex cursor-pointer select-none items-center gap-4 transition-all active:scale-[0.97]",
          cond do
            # Held in place (D106): the slot, filled — same box as the dashed
            # slot so nothing around it shifts during the hold.
            @done? and @slot? -> "h-24 rounded-xl border-[3px] px-3.5"
            # Done (routine or extra): kid-color fill, flush, a hairline
            # between consecutive done rows (D105).
            @done? -> "h-20 border-t border-white/35 px-[27px] first:border-t-0"
            # Pending extra: the fixed neutral card with the child-color
            # ownership border (docs/design-language.org).
            @extra? -> "h-24 border-l-[length:var(--child-border-width)] px-6"
            # Pending routine chore: a dashed slot in the routine tint (D105).
            true -> "h-24 rounded-xl border-[3px] border-dashed px-3.5"
          end
        ]
      }
      style={chore_card_style(@done?, @extra?, @slot?, @routine, @kid.color)}
    >
      <span class="text-[2.5rem] leading-none">{@chore.icon}</span>
      <span class={["text-2xl font-bold", @done? && "text-white drop-shadow-sm"]}>
        {@chore.name}
      </span>
      <span
        :if={@done? and @extra?}
        id={"chore-earned-#{@chore.id}"}
        class="ml-auto flex items-center rounded-full bg-success px-3 py-1 font-reward font-black text-success-content drop-shadow-sm"
      >
        +{@chore.points}
      </span>
      <%!-- Circled check (D105): a white disc carrying the check in the
           kid's own color — it reads as "earned", not as a target, which is
           also why a pending row has nothing in this column. --%>
      <span
        :if={@done?}
        id={"chore-check-#{@chore.id}"}
        class={
          [
            "flex size-9 shrink-0 items-center justify-center rounded-full bg-white drop-shadow-sm",
            not @extra? && "ml-auto",
            # The disc springs in during the hold only — a sunk row is a
            # re-inserted element, and re-popping below the fold is noise.
            @slot? && "animate-pop"
          ]
        }
        style={"color: #{@kid.color}"}
      >
        <.icon name="hero-check" class="size-6" />
      </span>
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
        <span class="font-reward text-2xl font-black">−{@chore.points}</span>
      </span>
    </li>
    """
  end

  # Done: full kid-color fill, no border of any kind — the fill is already
  # the child's own color. Pending extra: fixed neutral surface plus the
  # child-color ownership border (docs/design-language.org). Pending routine
  # chore: routine tint fill with a dashed routine-colored edge (D105) — the
  # column already carries ownership, so no child-color border here.
  defp chore_card_style(true, _extra?, true, _routine, kid_color),
    do: "background-color: #{kid_color}; border-color: #{kid_color}"

  defp chore_card_style(true, _extra?, false, _routine, kid_color),
    do: "background-color: #{kid_color}"

  defp chore_card_style(false, true, _slot?, _routine, kid_color),
    do:
      "background-color: var(--extra-card-background); border-left-color: #{kid_color}; color: var(--extra-card-content)"

  defp chore_card_style(false, false, _slot?, routine, _kid_color),
    do:
      "background-color: var(--routine-#{routine}-tint); border-color: var(--routine-#{routine}-edge)"

  # Stake segment (D105): paid rows take the class-level bg-success; a done
  # segment before payout is the kid's color; an empty one the routine edge.
  defp stake_segment_style(_done?, true, _routine, _kid_color), do: nil
  defp stake_segment_style(true, false, _routine, kid_color), do: "background-color: #{kid_color}"

  defp stake_segment_style(false, false, routine, _kid_color),
    do: "background-color: var(--routine-#{routine}-edge)"

  defp completion_icon_name(:morning), do: "hero-sun-solid"
  defp completion_icon_name(:evening), do: "hero-moon-solid"

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
