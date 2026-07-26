defmodule BearCubWeb.Admin.TodayLive do
  use BearCubWeb, :live_view

  alias BearCub.Chores
  alias BearCub.LocalTime
  alias BearCub.Points
  alias BearCub.Rewards
  alias BearCub.Routines

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Chores.subscribe()
      Rewards.subscribe()
    end

    socket = load(socket, LocalTime.now())

    # each kid starts with the active routine open (glance state up top);
    # the set survives reloads, so a parent's expands stick around
    expanded =
      MapSet.new(for %{kid: kid} <- socket.assigns.cards, do: {kid.id, socket.assigns.active})

    {:ok, assign(socket, :expanded, expanded)}
  end

  @impl true
  def handle_event("toggle-chore", %{"chore-id" => id}, socket) do
    now = LocalTime.now()

    case Chores.get_chore(id) do
      # deleted elsewhere after this render — drop the tap, refresh
      nil ->
        {:noreply, load(socket, now)}

      chore ->
        # a racing duplicate complete is {:error, changeset} = already done
        Chores.toggle_completion(chore, now, "admin")
        {:noreply, load(socket, now)}
    end
  end

  def handle_event("fail-chore", %{"chore-id" => id}, socket) do
    now = LocalTime.now()

    case Chores.get_chore(id) do
      # deleted elsewhere after this render — drop the tap, refresh
      nil ->
        {:noreply, load(socket, now)}

      chore ->
        # no live completion to fail (e.g. undone elsewhere first) — no-op
        Chores.fail_chore(chore, now)
        {:noreply, load(socket, now)}
    end
  end

  def handle_event("toggle-section", %{"kid-id" => kid_id, "routine" => routine}, socket) do
    key = {String.to_integer(kid_id), String.to_existing_atom(routine)}

    expanded =
      if MapSet.member?(socket.assigns.expanded, key),
        do: MapSet.delete(socket.assigns.expanded, key),
        else: MapSet.put(socket.assigns.expanded, key)

    {:noreply, assign(socket, :expanded, expanded)}
  end

  # Approve re-validates audience, availability, and affordability (D63,
  # D69) — any may have moved between ask and answer, including the
  # same-kid interleaving a direct-redeem creates (D62). A failed
  # re-check names which check failed rather than silently no-opping,
  # and leaves the request pending (Rewards.approve_redemption/3 stamps
  # no marker on refusal).
  def handle_event("approve-request", %{"request-id" => id}, socket) do
    now = LocalTime.now()
    redemption = Rewards.get_redemption!(id)
    kid = Chores.get_kid!(redemption.kid_id)
    reward = Rewards.get_reward!(redemption.reward_id)
    balance = Points.balance(kid, DateTime.to_date(now))

    case Rewards.approve_redemption(redemption, balance, now) do
      {:ok, _} ->
        {:noreply, load(socket, now)}

      {:error, :unaffordable} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "#{kid.name} can't afford “#{reward.name}” (#{redemption.points} pts)"
         )
         |> load(now)}

      {:error, :unavailable} ->
        {:noreply,
         socket
         |> put_flash(:error, "#{kid.name} has already claimed “#{reward.name}”")
         |> load(now)}

      {:error, :not_offered} ->
        {:noreply,
         socket
         |> put_flash(:error, "“#{reward.name}” isn't offered to #{kid.name}")
         |> load(now)}

      {:error, :not_open} ->
        # lapsed or already answered elsewhere between render and tap — the
        # reload drops the row (D73)
        {:noreply, load(socket, now)}
    end
  end

  # No confirmation (design §Requests): costs nothing, contributes 0.
  def handle_event("decline-request", %{"request-id" => id}, socket) do
    now = LocalTime.now()
    Rewards.decline_redemption(Rewards.get_redemption!(id), now)
    {:noreply, load(socket, now)}
  end

  # Restores points and availability for free (D62, SC-8) — the row is
  # retained forever as the trail, never deleted.
  def handle_event("reverse-redemption", %{"redemption-id" => id}, socket) do
    now = LocalTime.now()
    Rewards.reverse_redemption(Rewards.get_redemption!(id), now)
    {:noreply, load(socket, now)}
  end

  @impl true
  def handle_info(:chores_changed, socket) do
    {:noreply, load(socket, LocalTime.now())}
  end

  # BearCub.Rewards owns its own payload-free "rewards" topic (D71) —
  # re-fetch, never patch from a payload.
  def handle_info(:rewards_changed, socket) do
    {:noreply, load(socket, LocalTime.now())}
  end

  defp load(socket, local_now) do
    {_state, active} = Routines.current(local_now)
    today = DateTime.to_date(local_now)

    # done today? — derived, never stored (design §2)
    completions = Chores.current_completions(today)
    failed_ids = Chores.failed_chore_ids(today)

    cards =
      for kid <- Chores.list_kids() do
        sections =
          for routine <- [active, Routines.other(active)] do
            chores =
              for chore <- Chores.list_chores(kid, Atom.to_string(routine)) do
                build_row(chore, completions, failed_ids)
              end

            %{
              routine: routine,
              chores: chores,
              done: Enum.count(chores, & &1.done?),
              total: length(chores)
            }
          end

        extras =
          for extra <- Chores.list_extras(kid, today) do
            build_row(extra, completions, failed_ids)
          end

        %{
          kid: kid,
          sections: sections,
          extras: extras,
          balance: Points.balance(kid, today),
          requests: Rewards.list_pending_redemptions(kid.id, today),
          redemptions: Rewards.list_redemptions_today(kid.id, today)
        }
      end

    assign(socket, cards: cards, active: active)
  end

  # Unlike the kiosk's failed-and-not-redone derivation (Story 06/D45),
  # admin's `failed?` is day-scoped only (D53): once failed, the solid
  # flag stands for the rest of the day even after a redo — the actionable
  # control never returns to a chore already failed today.
  defp build_row(chore, completions, failed_ids) do
    %{
      chore: chore,
      done?: Map.has_key?(completions, chore.id),
      failed?: MapSet.member?(failed_ids, chore.id)
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} active={:today} static_reload_href={@static_reload_href}>
      <div id="admin-today" class="mx-auto max-w-md space-y-6 px-4 py-6">
        <.header>Today</.header>

        <section
          :for={
            %{
              kid: kid,
              sections: sections,
              extras: extras,
              balance: balance,
              requests: requests,
              redemptions: redemptions
            } <- @cards
          }
          id={"today-kid-#{kid.id}"}
          class="overflow-hidden rounded-2xl bg-base-100 shadow-sm"
        >
          <header
            class="flex items-center justify-between px-5 py-3"
            style={"background-color: #{kid.color}"}
          >
            <h2 class="text-xl font-bold text-white drop-shadow-sm">{kid.name}</h2>
            <%!-- true signed balance, always visible, negative included (D64, the
                 [2026-07-25 Sat 20:41] balance-placement advisory) --%>
            <span
              id={"today-balance-#{kid.id}"}
              class="text-lg font-bold tabular-nums text-white drop-shadow-sm"
            >
              ★ {balance}
            </span>
          </header>

          <div :for={section <- sections} class="border-t border-base-200 first:border-t-0">
            <button
              id={"section-#{kid.id}-#{section.routine}"}
              phx-click="toggle-section"
              phx-value-kid-id={kid.id}
              phx-value-routine={section.routine}
              class="flex w-full items-center justify-between px-5 py-3"
            >
              <span class="font-semibold">{routine_label(section.routine)}</span>
              <span
                id={"progress-#{kid.id}-#{section.routine}"}
                class="text-sm tabular-nums text-base-content/60"
              >
                {section.done}/{section.total}
              </span>
            </button>

            <ul
              :if={MapSet.member?(@expanded, {kid.id, section.routine})}
              id={"today-chores-#{kid.id}-#{section.routine}"}
              class="divide-y divide-base-200 border-t border-base-200"
            >
              <.chore_row :for={row <- section.chores} row={row} kid={kid} />
              <li :if={section.chores == []} class="px-5 py-3 text-sm text-base-content/40">
                No chores
              </li>
            </ul>
          </div>

          <div class="border-t border-base-200">
            <h3 class="px-5 py-3 font-semibold">Extras</h3>

            <ul
              id={"today-extras-#{kid.id}"}
              class="divide-y divide-base-200 border-t border-base-200"
            >
              <.chore_row :for={row <- extras} row={row} kid={kid} />
              <li :if={extras == []} class="px-5 py-3 text-sm text-base-content/40">
                No extras
              </li>
            </ul>
          </div>

          <div class="border-t border-base-200">
            <h3 class="px-5 py-3 font-semibold">Requests</h3>

            <ul
              id={"requests-#{kid.id}"}
              class="divide-y divide-base-200 border-t border-base-200"
            >
              <.request_row :for={request <- requests} request={request} />
              <li :if={requests == []} class="px-5 py-3 text-sm text-base-content/40">
                No requests
              </li>
            </ul>
          </div>

          <div class="border-t border-base-200">
            <h3 class="px-5 py-3 font-semibold">Redemptions</h3>

            <ul
              id={"redemptions-#{kid.id}"}
              class="divide-y divide-base-200 border-t border-base-200"
            >
              <.redemption_row :for={redemption <- redemptions} redemption={redemption} />
              <li :if={redemptions == []} class="px-5 py-3 text-sm text-base-content/40">
                No redemptions today
              </li>
            </ul>
          </div>
        </section>
      </div>
    </Layouts.admin>
    """
  end

  attr :row, :map, required: true
  attr :kid, :map, required: true

  # Reused for morning/evening chores and extras alike (extras are chores
  # with routine = nil — same on-behalf toggle, same #today-chore-{id} row).
  defp chore_row(assigns) do
    ~H"""
    <li
      id={"today-chore-#{@row.chore.id}"}
      data-done={@row.done?}
      phx-click="toggle-chore"
      phx-value-chore-id={@row.chore.id}
      class="flex cursor-pointer select-none items-center gap-3 px-5 py-3 transition-colors"
      style={@row.done? && "background-color: #{@kid.color}"}
    >
      <span class="text-2xl leading-none">{@row.chore.icon}</span>
      <span class={[
        "min-w-0 flex-1 truncate font-medium",
        @row.done? && "text-white drop-shadow-sm"
      ]}>
        {@row.chore.name}
      </span>
      <button
        :if={@row.done? and not @row.failed?}
        id={"fail-chore-#{@row.chore.id}"}
        phx-click="fail-chore"
        phx-value-chore-id={@row.chore.id}
        data-confirm={"Fail “#{@row.chore.name}”? This can't be undone."}
        title="Fail — reverts and deducts points"
        class="rounded-full p-1 text-white/80 hover:text-white"
      >
        <.icon name="hero-flag" class="size-5 drop-shadow-sm" />
      </button>
      <span
        :if={@row.failed?}
        id={"failed-flag-#{@row.chore.id}"}
        title="Failed today"
        class={[
          "rounded-full p-1",
          if(@row.done?, do: "text-white drop-shadow-sm", else: "text-error")
        ]}
      >
        <.icon name="hero-flag-solid" class="size-5" />
      </span>
      <.icon :if={@row.done?} name="hero-check" class="size-6 text-white drop-shadow-sm" />
    </li>
    """
  end

  attr :request, :map, required: true

  # Requests section (Story 06, D69): approve re-checks affordability and
  # availability server-side and is data-confirm guarded (points-affecting,
  # permanent from tomorrow since reversal is day-scoped, D53); decline
  # carries no confirmation — it costs nothing and its own day-scoping is
  # the undo. The kid's balance rides the header band, not this row (D64,
  # the [2026-07-25 Sat 20:41] balance-placement advisory).
  defp request_row(assigns) do
    ~H"""
    <li id={"request-#{@request.id}"} class="flex items-center gap-3 px-5 py-3">
      <span class="text-2xl leading-none">{@request.reward.icon}</span>
      <div class="min-w-0 flex-1">
        <p class="truncate font-medium">{@request.reward.name}</p>
        <p class="text-sm text-base-content/60">
          {@request.points} pts
        </p>
      </div>
      <button
        id={"decline-request-#{@request.id}"}
        phx-click="decline-request"
        phx-value-request-id={@request.id}
        class="rounded-lg px-3 py-1.5 text-sm font-semibold text-base-content/60"
      >
        Decline
      </button>
      <button
        id={"approve-request-#{@request.id}"}
        phx-click="approve-request"
        phx-value-request-id={@request.id}
        data-confirm={"Redeem “#{@request.reward.name}” for #{@request.points} points?"}
        class="rounded-lg bg-primary px-3 py-1.5 text-sm font-semibold text-primary-content"
      >
        Approve
      </button>
    </li>
    """
  end

  attr :redemption, :map, required: true

  # Reverse (Story 06, D69, D62): restores points and availability for
  # free, offered only on today's redemptions (D55 day-scoping) — an
  # earlier day's spend has no reverse control here at all.
  defp redemption_row(assigns) do
    ~H"""
    <li id={"redemption-#{@redemption.id}"} class="flex items-center gap-3 px-5 py-3">
      <span class="text-2xl leading-none">{@redemption.reward.icon}</span>
      <div class="min-w-0 flex-1">
        <p class="truncate font-medium">{@redemption.reward.name}</p>
        <p class="text-sm text-base-content/60">
          {@redemption.points} pts <span :if={Rewards.reversed?(@redemption)}>· reversed</span>
        </p>
      </div>
      <button
        :if={Rewards.approved?(@redemption)}
        id={"reverse-redemption-#{@redemption.id}"}
        phx-click="reverse-redemption"
        phx-value-redemption-id={@redemption.id}
        data-confirm={"Reverse “#{@redemption.reward.name}”? This returns the points."}
        class="rounded-lg px-3 py-1.5 text-sm font-semibold text-base-content/60"
      >
        Reverse
      </button>
    </li>
    """
  end
end
