defmodule BearCubWeb.KioskLive do
  use BearCubWeb, :live_view

  import BearCubWeb.KioskComponents

  alias BearCub.Calendars
  alias BearCub.Chores
  alias BearCub.LocalTime
  alias BearCub.Points
  alias BearCub.Rewards
  alias BearCub.Routines
  alias BearCub.Schedules

  # Collapse-delay (Story 07, SC-7): the pause between the last routine
  # chore completing and the routine list collapsing, so that chore's own
  # completion stays briefly visible before the whole-routine collapse. The
  # concrete duration is implementation freedom, tuned at the on-device
  # gate. Raised [2026-09-07] from 400ms so it clears the settle beat plus
  # the 300ms sink animation — the last chore's sink finishes before the
  # band replaces the rows, instead of being cut off mid-flight.
  @collapse_delay_ms 500

  # Settle-delay (D106): the pause between a routine chore completing and
  # its row sinking to the done stack — the row shows its done treatment
  # in place first, so the tap registers where the finger is. Shortened
  # [2026-09-07] from 700ms on the human's ruling once the sink itself
  # animated (the collapsing ghost now answers the tap where it landed):
  # the slightest beat, not a hold. Same shape as the collapse delay
  # above; tuned at the local gate, not design-pinned.
  @settle_delay_ms 150
  # The pressed beat on a confirmed count panel (D117): the write lands at the
  # tap, the row lands as done this much later.
  @confirm_delay_ms 280

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
      Schedules.subscribe()
    end

    # one clock read per mount — two could straddle a window edge
    now = LocalTime.now()

    {:ok,
     socket
     |> assign(:expanded, MapSet.new())
     |> assign(:pending_collapse, MapSet.new())
     |> assign(:settling, MapSet.new())
     |> assign(:just_risen, nil)
     |> assign(:rewards, MapSet.new())
     |> assign(:rewards_timers, %{})
     |> assign(:counting, %{})
     |> assign(:boundary_timer, nil)
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
        cond do
          Map.has_key?(socket.assigns.completions, chore.id) ->
            case Chores.undo_chore(chore, now) do
              # The undone completion is the rise's marker: its chore id names
              # the row that grows back into its slot, and its timestamp is
              # where the ghost sits in the done stack (that completion is
              # gone from `completions` by the time `load/2` runs). Held in
              # an assign because the write's own `:chores_changed` echo
              # re-renders right behind this tap and must still carry it —
              # unlike the sink, no timer separates the tap from the echo.
              {:ok, completion} ->
                {:noreply, socket |> assign(:just_risen, completion) |> load(now)}

              # another surface undid it first — no-op
              {:error, :not_completed} ->
                {:noreply, load(socket, now)}
            end

          # A pending counted extra opens the count panel instead of
          # completing outright (Story 04): the tap that would otherwise
          # complete a flat chore instead seeds a fresh entry (always 1,
          # never a prior count) for this kid, replacing any other open
          # panel of theirs — one panel per kid at a time (D-Story04).
          counted?(chore) ->
            counting =
              Map.put(socket.assigns.counting, chore.kid_id, %{
                chore_id: chore.id,
                count: 1,
                confirmed?: false
              })

            {:noreply, socket |> assign(:counting, counting) |> load(now)}

          true ->
            # a racing double-complete hits the partial unique index — already done
            Chores.complete_chore(chore, now, "kiosk")
            {:noreply, socket |> settle_later(chore.id) |> load(now)}
        end
    end
  end

  # Server-side clamp (Story 04): a forged event can never push the count
  # outside 1..unit_max, and the changeset bound on confirm refuses it
  # again if it somehow does.
  def handle_event("count-step", %{"kid-id" => kid_id, "dir" => dir}, socket) do
    delta = if dir == "inc", do: 1, else: -1
    counting = step_count(socket, String.to_integer(kid_id), delta)
    {:noreply, socket |> assign(:counting, counting) |> load(LocalTime.now())}
  end

  # The write lands at the tap; the entry stays, marked confirmed, so the
  # panel holds its pressed look for `@confirm_delay_ms` and is inert
  # meanwhile (D117). `{:confirm_landed, ...}` drops it.
  def handle_event("count-confirm", %{"kid-id" => kid_id}, socket) do
    now = LocalTime.now()
    kid_id = String.to_integer(kid_id)

    case Map.fetch(socket.assigns.counting, kid_id) do
      {:ok, %{confirmed?: false, chore_id: chore_id, count: count} = entry} ->
        case Chores.get_chore(chore_id) do
          nil -> :ok
          chore -> Chores.complete_chore(chore, now, "kiosk", count)
        end

        Process.send_after(self(), {:confirm_landed, kid_id, chore_id}, @confirm_delay_ms)
        counting = Map.put(socket.assigns.counting, kid_id, %{entry | confirmed?: true})
        {:noreply, socket |> assign(:counting, counting) |> load(now)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("count-cancel", %{"kid-id" => kid_id}, socket) do
    kid_id = String.to_integer(kid_id)

    case Map.get(socket.assigns.counting, kid_id) do
      %{confirmed?: true} ->
        {:noreply, socket}

      _ ->
        counting = Map.delete(socket.assigns.counting, kid_id)
        {:noreply, socket |> assign(:counting, counting) |> load(LocalTime.now())}
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

  defp counted?(%Chores.Chore{unit_rate: unit_rate}), do: not is_nil(unit_rate)

  defp step_count(socket, kid_id, delta) do
    update_count(socket, kid_id, fn count, _chore -> count + delta end)
  end

  # `unit_max` is always read fresh from the DB, never trusted from the
  # client — the server-side clamp the stepper goes through.
  defp update_count(socket, kid_id, next_count) do
    case Map.fetch(socket.assigns.counting, kid_id) do
      {:ok, %{confirmed?: true}} ->
        socket.assigns.counting

      {:ok, %{chore_id: chore_id, count: count} = entry} ->
        case Chores.get_chore(chore_id) do
          nil ->
            socket.assigns.counting

          chore ->
            clamped = next_count.(count, chore) |> max(1) |> min(chore.unit_max)
            Map.put(socket.assigns.counting, kid_id, %{entry | count: clamped})
        end

      :error ->
        socket.assigns.counting
    end
  end

  # The kiosk's own undo comes back as this broadcast a moment after the
  # tap rendered it; this render still carries the rise marker (dropping
  # it here would strip the animation mid-play) and is where it is spent.
  @impl true
  def handle_info(:chores_changed, socket) do
    {:noreply, socket |> load(LocalTime.now()) |> assign(:just_risen, nil)}
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

  # A saved schedule can move the routine edge to now or take the next one
  # somewhere else: re-resolve the version in force and re-arm the one
  # boundary timer (D124), clearing the shop as a boundary does.
  def handle_info(:schedule_changed, socket) do
    now = LocalTime.now()

    socket =
      socket
      |> cancel_all_rewards_idle_timers()
      |> assign(:rewards, MapSet.new())
      |> assign(:counting, %{})
      |> load(now)
      |> schedule_boundary(now)

    {:noreply, socket}
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
      |> assign(:counting, %{})
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

  # Settle-delay (D106): the row may sink now. A stray message — the chore
  # was undone during the beat, or never tapped here — is a harmless
  # no-op. `just_sunk` names this one chore for this render only, so the
  # sink animation plays once for the kiosk's own tap and never replays
  # for a row that was already done — D106's "re-popping below the fold
  # is noise" rule. Only the tap animates: a completion arriving from
  # admin has no finger to answer.
  def handle_info({:settled, chore_id}, socket) do
    settling = MapSet.delete(socket.assigns.settling, chore_id)

    {:noreply,
     socket
     |> assign(:settling, settling)
     |> load(LocalTime.now(), just_sunk: chore_id)}
  end

  # The confirm beat is over (D117): the panel's entry goes and the row
  # lands in the done mass. A boundary or `load/2` clearing that already
  # removed the entry makes this a no-op.
  def handle_info({:confirm_landed, kid_id, chore_id}, socket) do
    case Map.get(socket.assigns.counting, kid_id) do
      %{chore_id: ^chore_id, confirmed?: true} ->
        counting = Map.delete(socket.assigns.counting, kid_id)
        {:noreply, socket |> assign(:counting, counting) |> load(LocalTime.now())}

      _ ->
        {:noreply, socket}
    end
  end

  defp settle_later(socket, chore_id) do
    Process.send_after(self(), {:settled, chore_id}, @settle_delay_ms)
    assign(socket, :settling, MapSet.put(socket.assigns.settling, chore_id))
  end

  defp load(socket, local_now, opts \\ []) do
    just_sunk = Keyword.get(opts, :just_sunk)

    # One history read per render: the version in force now prices the
    # stake (D123), the whole list prices what each routine-day incurred.
    versions = Schedules.versions()
    version = Routines.in_force(versions, local_now)

    {routine_state, auto} =
      Routines.current(local_now, Routines.day(version, DateTime.to_date(local_now)))

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
    # The failed-and-not-yet-redone row's own completion (Story 05):
    # `fail_chore/2` stamps `undone_at` alongside `failed_at`, so that row
    # is invisible to `current_completions/1` above — this is the only way
    # to read its `effort_count` for the kiosk's ×N and −N display.
    failed_completions = Chores.failed_completions(today)
    expanded = socket.assigns.expanded
    pending_collapse = socket.assigns.pending_collapse
    settling = socket.assigns.settling
    rewards = socket.assigns.rewards
    just_risen = socket.assigns.just_risen
    counting = socket.assigns.counting

    {columns, pending_collapse} =
      Enum.map_reduce(Chores.list_kids(), pending_collapse, fn kid, pending_collapse ->
        build_column(
          kid,
          auto,
          version,
          versions,
          night?,
          completions,
          old_completions,
          failed_ids,
          failed_completions,
          today,
          expanded,
          pending_collapse,
          settling,
          rewards,
          counting,
          just_sunk,
          just_risen
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

    # Count panel clearing (Story 04): a kid's entry survives only while
    # its chore is still an open pending counted extra for them — dropped
    # the moment it's archived from admin, completed from another surface,
    # or the window closes (extras render empty at night and outside the
    # band), all of which fall out of `tag_counting/5` already having said
    # so on that kid's own extras this pass.
    still_counting =
      counting
      |> Enum.filter(fn {kid_id, _entry} ->
        column = Enum.find(columns, &(&1.kid.id == kid_id))
        column != nil and Enum.any?(column.extras, & &1.counting?)
      end)
      |> Map.new()

    assign(socket,
      columns: columns,
      completions: completions,
      expanded: still_expanded,
      night?: night?,
      pending_collapse: pending_collapse,
      counting: still_counting,
      calendars_stale?: Calendars.any_stale?(local_now)
    )
  end

  defp build_column(
         kid,
         auto,
         version,
         versions,
         night?,
         completions,
         old_completions,
         failed_ids,
         failed_completions,
         today,
         expanded,
         pending_collapse,
         settling,
         rewards,
         counting,
         just_sunk,
         just_risen
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
    {slot, done} =
      chores
      |> build_rows(completions, failed_ids)
      |> sink_done(completions, settling, just_sunk, just_risen)

    # One entry per real chore — the stake bar draws a segment per entry,
    # so the sink and rise ghosts (see `sink_done/5`) stay out of it.
    chore_rows = Enum.reject(slot ++ done, & &1.ghost?)

    # The single capped penalty strip: failed-and-not-redone, rows state only.
    routine_penalty? = state == :rows and Enum.any?(chore_rows, & &1.failed?)

    # What the routine-day has incurred is priced at the instants it
    # happened (D123) and read only where a priced figure can render: the
    # badge and paid chip (complete) or the penalty strip. The early bird
    # (D100, D101) rides on the same read, so it costs nothing extra;
    # a fail forfeits it inside the predicate, like the badge.
    pricing =
      if complete? or routine_penalty?,
        do: Chores.routine_day_pricing(kid, Atom.to_string(auto), today, versions),
        else: %{r: 0, e: 0, early?: false, penalty: 0}

    early_bird? = reveal? and auto == :morning and pricing.early?

    extras =
      if state == :band and auto == :morning do
        Chores.list_extras(kid, today)
        |> build_rows(completions, failed_ids)
        |> Enum.map(&tag_counting(&1, kid.id, counting, completions, failed_completions))
        |> raise_done_extras(completions)
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
      # priced once the routine-day is paid, live while it is still at stake
      r: if(complete?, do: pricing.r, else: version.routine_bonus),
      e: pricing.e,
      penalty: pricing.penalty,
      chores: chore_rows,
      slot: slot,
      done: done,
      extras: extras,
      # The routine-penalty strip is a single capped indicator, modeled on
      # the boolean "any routine chore failed-and-not-redone" rather than a
      # per-chore loop (D45, D46) — only relevant in the expanded rows state.
      routine_penalty?: routine_penalty?,
      events: Calendars.today_events(kid.id, today),
      points: Points.total(kid, today),
      pending_request?: pending_request?,
      catalog: catalog
    }

    {column, pending_collapse}
  end

  # Done extras rise (D117): newest completion first, then the pending rows
  # in authored order. A row mid-confirm-beat is still the panel, so it
  # holds its authored place until it lands. `completed_at` is
  # second-resolution — the completion id breaks ties, as for `sink_done/5`.
  defp raise_done_extras(rows, completions) do
    {done, pending} = Enum.split_with(rows, &(&1.done? and not &1.counting?))

    done =
      Enum.sort_by(
        done,
        fn row ->
          completion = Map.fetch!(completions, row.chore.id)
          {DateTime.to_unix(completion.completed_at), completion.id}
        end,
        :desc
      )

    done ++ pending
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

  # Tags an extra row with this kid's open count panel, if any (Story 04),
  # and with its persisted count and earned/lost value once it has one
  # (Story 05). A done row is never tagged with a panel even when its
  # chore id still matches a stale `counting` entry — the panel belongs to
  # the pending tap only, never to a chore completed from elsewhere in the
  # meantime — which is also what `load/2`'s `still_counting` filter reads
  # back to drop that entry for good.
  defp tag_counting(%{done?: true} = row, kid_id, counting, completions, _failed_completions) do
    # ...except during the confirm beat (D117): the completion is already
    # written but the panel holds its pressed look until it lands.
    case Map.get(counting, kid_id) do
      %{chore_id: chore_id, count: count, confirmed?: true} when chore_id == row.chore.id ->
        Map.merge(row, %{
          counting?: true,
          confirmed?: true,
          count: count,
          effort_count: nil,
          value: nil
        })

      _ ->
        attach_effort(row, Map.fetch!(completions, row.chore.id))
    end
  end

  # A failed row is pending again (D45, D46): tapping it to redo opens the
  # panel like any pending counted extra, and the panel replaces the
  # failed look until it closes or confirms.
  defp tag_counting(%{failed?: true} = row, kid_id, counting, _completions, failed_completions) do
    case Map.get(counting, kid_id) do
      %{chore_id: chore_id, count: count} when chore_id == row.chore.id ->
        Map.merge(row, %{
          counting?: true,
          confirmed?: false,
          count: count,
          effort_count: nil,
          value: nil
        })

      _ ->
        attach_effort(row, Map.fetch!(failed_completions, row.chore.id))
    end
  end

  defp tag_counting(row, kid_id, counting, _completions, _failed_completions) do
    case Map.get(counting, kid_id) do
      %{chore_id: chore_id, count: count} when chore_id == row.chore.id ->
        Map.merge(row, %{
          counting?: true,
          confirmed?: false,
          count: count,
          effort_count: nil,
          value: nil
        })

      _ ->
        Map.merge(row, %{
          counting?: false,
          confirmed?: false,
          count: nil,
          effort_count: nil,
          value: nil
        })
    end
  end

  # The completed/failed row's own ×N and chip value (Story 05, D112):
  # `effort_count` is `nil` on a flat chore's completion, so ×N stays
  # unrendered and `value` reduces to plain `chore.points` — the same
  # figure the chip always showed, via the one formula every extras
  # contribution already goes through (design's "re-derivable forever").
  defp attach_effort(row, completion) do
    Map.merge(row, %{
      counting?: false,
      confirmed?: false,
      count: nil,
      effort_count: completion.effort_count,
      value: abs(Chores.extra_contribution(completion, row.chore))
    })
  end

  # The two stacks (D105): `{slot, done}` — the slot group's rows in
  # authored order, and the done stack's rows beneath, most recent
  # completion first. `completed_at` is second-resolution, so the
  # completion id breaks ties in the same second — a later tap is a later
  # row. A done row still settling (D106) is not yet sunk: it keeps its
  # authored place in the slot group for the beat, rendered done.
  #
  # Sink and rise animation (backlog: "Animate the sink of a settled chore
  # row"; D107): a row that moves between the stacks does so as two halves
  # on one clock — the real row `grow?`s open from nothing in its new
  # place while an inert `ghost?` copy holds its old place, collapsing to
  # nothing. `just_sunk` is the `:settled` message's chore id: that row
  # grows in `done` and ghosts in `slot`. `just_risen` is the completion an
  # undo just closed: its row grows back in `slot` and ghosts in `done`,
  # at the spot that completion's timestamp still sorts it to — unless
  # the row was still settling, in which case it never reached the done
  # stack and simply becomes a plain slot again. Each is nil otherwise,
  # so both halves are gone from the markup on the next render — once
  # only, never for a row that was already where it is: D106's
  # "re-popping below the fold is noise" rule, applied to the move.
  defp sink_done(rows, completions, settling, just_sunk, just_risen) do
    rows =
      for row <- rows do
        settling? = MapSet.member?(settling, row.chore.id)
        sunk? = row.done? and not settling?

        risen? =
          not row.done? and not settling? and just_risen != nil and
            row.chore.id == just_risen.chore_id

        Map.merge(row, %{
          sunk?: sunk?,
          just_sunk?: sunk? and row.chore.id == just_sunk,
          risen?: risen?
        })
      end

    slot =
      for row <- rows, not row.sunk? or row.just_sunk? do
        Map.merge(row, %{ghost?: row.just_sunk?, grow?: row.risen?})
      end

    rise_ghosts = for row <- rows, row.risen?, do: Map.merge(row, %{ghost?: true, grow?: false})

    done =
      rows
      |> Enum.filter(& &1.sunk?)
      |> Enum.map(&Map.merge(&1, %{ghost?: false, grow?: &1.just_sunk?}))
      |> Kernel.++(rise_ghosts)
      |> Enum.sort_by(
        fn row ->
          completion = if row.ghost?, do: just_risen, else: Map.fetch!(completions, row.chore.id)
          {DateTime.to_unix(completion.completed_at), completion.id}
        end,
        :desc
      )

    {slot, done}
  end

  # The one boundary chain (D124): every :boundary arms the next, so
  # anything that arms from elsewhere (a schedule save) must cancel the
  # timer it replaces or a second chain starts and never ends.
  defp schedule_boundary(socket, now) do
    if socket.assigns.boundary_timer, do: Process.cancel_timer(socket.assigns.boundary_timer)

    if connected?(socket) do
      entry = Schedules.day_entry(now)
      ms = DateTime.diff(Routines.next_boundary(now, entry), now, :millisecond)
      # floor guards against a timer that fires a hair early re-arming hot
      assign(socket, :boundary_timer, Process.send_after(self(), :boundary, max(ms, 1_000)))
    else
      socket
    end
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
        <.night_screen :if={@night?} />

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
              r: r,
              e: e,
              penalty: penalty,
              chores: chores,
              slot: slot,
              done: done,
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
          <.banner
            kid={kid}
            routine={routine}
            reveal?={reveal?}
            failed?={failed?}
            early_bird?={early_bird?}
            r={r}
            e={e}
            points={points}
            pending_request?={pending_request?}
          />

          <%!-- Renders only while `standing?` (already window- and
               delay-gated in `build_column/10`). It survives the reward
               shop below (D97: standing is a property of the child's day,
               not of which body view is open), which is why it sits above
               both branches rather than inside either. --%>
          <.standing_band :if={standing?} kid={kid} />

          <%!-- Column body: either the normal routine region (events,
               routine card, extras) or the reward shop (Story 05, D65) —
               the shop replaces the whole body, never sits beside it, so
               the 5-chore no-scroll budget (FR-6) is untouched by
               construction. The banner above is shared by both. --%>
          <div
            :if={state != :rewards}
            class="row-start-3 grid grid-rows-[auto_auto_1fr_auto] overflow-hidden"
          >
            <.events_strip kid={kid} events={events} />

            <.stake_bar
              kid={kid}
              routine={routine}
              chores={chores}
              complete?={complete?}
              failed?={failed?}
              r={r}
            />

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
                <.routine_penalty :if={routine_penalty?} kid={kid} penalty={penalty} />

                <%!-- Two stacks (D105): pending rows as dashed slots in a
                     padded group, done rows flush beneath as one kid-color
                     mass — `sink_done/4` has already built and ordered both
                     lists. Slot padding (10px) + border (3px) + row padding
                     (14px) = the done row's 27px, so the emoji column lines
                     up across both stacks. --%>
                <div
                  id={"chores-#{kid.id}"}
                  class="row-start-2 max-h-full self-start overflow-y-auto"
                >
                  <%!-- `space-y-2`, not `gap-2`: the spacing is each row's own
                       margin, so the sink ghost can animate it away along
                       with its height (a last-in-list ghost has none). --%>
                  <ul :if={slot != []} class="flex flex-col space-y-2 p-2.5">
                    <.chore_row
                      :for={
                        %{chore: chore, done?: done?, failed?: failed?, ghost?: ghost?, grow?: grow?} <-
                          slot
                      }
                      chore={chore}
                      done?={done?}
                      failed?={failed?}
                      kid={kid}
                      routine={routine}
                      slot?={true}
                      ghost?={ghost?}
                      grow?={grow?}
                    />
                  </ul>
                  <ul :if={done != []} class="flex flex-col">
                    <.chore_row
                      :for={%{chore: chore, ghost?: ghost?, grow?: grow?} <- done}
                      chore={chore}
                      done?={true}
                      kid={kid}
                      routine={routine}
                      ghost?={ghost?}
                      grow?={grow?}
                    />
                  </ul>
                </div>
              </div>

              <%!-- Collapse band (states 2/3, D33/D34): reveal gated by the
                   active window, not pure completion. --%>
              <.band :if={state == :band} kid={kid} routine={routine} />
            </div>

            <%!-- Extras: below the routine card, never tinted (invariant —
                 docs/design-language.org). Morning-only reveal, gated with
                 the band (D34 technical notes: extras are chores, so this is
                 the same tappable row, styled as a slot in the kid's own color). --%>
            <ul
              :if={state == :band and routine == :morning}
              id={"extras-#{kid.id}"}
              class="grid auto-rows-min gap-2 overflow-y-auto p-2.5"
            >
              <%!-- Done extras rise as one joined kid-color mass, newest
                   first (D117); pending rows follow in authored order. --%>
              <li
                :if={Enum.any?(extras, &(&1.done? and not &1.counting?))}
                id={"extras-done-#{kid.id}"}
              >
                <ul class="flex flex-col overflow-hidden rounded-xl">
                  <.chore_row
                    :for={
                      %{chore: chore, effort_count: effort_count, value: value} <-
                        Enum.filter(extras, &(&1.done? and not &1.counting?))
                    }
                    chore={chore}
                    done?={true}
                    kid={kid}
                    routine={routine}
                    extra?={true}
                    effort_count={effort_count}
                    value={value}
                  />
                </ul>
              </li>
              <.chore_row
                :for={
                  %{
                    chore: chore,
                    done?: done?,
                    failed?: failed?,
                    counting?: counting?,
                    confirmed?: confirmed?,
                    count: count,
                    effort_count: effort_count,
                    value: value
                  } <- Enum.reject(extras, &(&1.done? and not &1.counting?))
                }
                chore={chore}
                done?={done?}
                failed?={failed?}
                kid={kid}
                routine={routine}
                extra?={true}
                counting?={counting?}
                confirmed?={confirmed?}
                count={count}
                effort_count={effort_count}
                value={value}
              />
            </ul>
          </div>

          <%!-- Reward shop (Story 05/08, D65-D67, D75-D77): replaces the
               column body; each card's own state is the whole guard (see
               `KioskComponents.reward_card/1`). --%>
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
              <.reward_card
                :for={%{reward: reward, state: card_state} <- catalog}
                reward={reward}
                state={card_state}
                kid={kid}
              />
            </ul>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
