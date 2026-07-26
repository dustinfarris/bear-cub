defmodule BearCubWeb.Admin.RewardLive.Index do
  use BearCubWeb, :live_view

  alias BearCub.Chores
  alias BearCub.LocalTime
  alias BearCub.Points
  alias BearCub.Rewards

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Rewards.subscribe()
      Chores.subscribe()
    end

    {:ok, socket |> assign(:redeeming, nil) |> assign(:kids, Chores.list_kids()) |> load()}
  end

  @impl true
  def handle_event("move", %{"reward-id" => id, "dir" => dir}, socket) when dir in ~w(up down) do
    case Rewards.get_reward(id) do
      nil ->
        {:noreply, load(socket)}

      reward ->
        {:ok, _} = Rewards.move_reward(reward, String.to_existing_atom(dir))
        {:noreply, load(socket)}
    end
  end

  def handle_event("archive", %{"reward-id" => id}, socket) do
    case Rewards.get_reward(id) do
      nil ->
        {:noreply, load(socket)}

      reward ->
        {:ok, _} = Rewards.archive_reward(reward, LocalTime.now())
        {:noreply, socket |> assign(:redeeming, nil) |> load()}
    end
  end

  def handle_event("toggle-redeem", %{"reward-id" => id}, socket) do
    id = String.to_integer(id)
    redeeming = if socket.assigns.redeeming == id, do: nil, else: id

    {:noreply, socket |> assign(:redeeming, redeeming) |> load()}
  end

  def handle_event("redeem", %{"reward-id" => reward_id, "kid-id" => kid_id}, socket) do
    now = LocalTime.now()
    today = DateTime.to_date(now)

    with reward when not is_nil(reward) <- Rewards.get_reward(reward_id),
         kid when not is_nil(kid) <- Chores.get_kid(kid_id) do
      balance = Points.balance(kid, today)

      case Rewards.direct_redeem(kid, reward, balance, now) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(:redeeming, nil)
           # worded Redeem, not Give — a direct-redeem spends the kid's own
           # points on their behalf, it isn't a gift (D64, D68)
           |> put_flash(:info, "Redeemed “#{reward.name}” for #{kid.name}")
           |> load()}

        {:error, :unaffordable} ->
          {:noreply,
           socket
           |> put_flash(
             :error,
             "#{kid.name} can't afford “#{reward.name}” (#{reward.points} pts)"
           )
           |> load()}

        {:error, :unavailable} ->
          {:noreply,
           socket
           |> put_flash(:error, "#{kid.name} has already claimed “#{reward.name}”")
           |> load()}

        {:error, :not_offered} ->
          {:noreply,
           socket
           |> put_flash(:error, "“#{reward.name}” isn't offered to #{kid.name}")
           |> load()}
      end
    else
      # deleted from another surface after this render — the reload drops the row
      nil -> {:noreply, load(socket)}
    end
  end

  @impl true
  def handle_info(:rewards_changed, socket), do: {:noreply, load(socket)}
  def handle_info(:chores_changed, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    today = DateTime.to_date(LocalTime.now())

    assign(socket,
      rewards: Rewards.list_all_rewards(),
      balances: Points.balances(today)
    )
  end

  defp audience_label(nil), do: "Anyone"
  defp audience_label(%Chores.Kid{name: name}), do: name

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} active={:rewards} static_reload_href={@static_reload_href}>
      <div id="admin-rewards" class="mx-auto max-w-md px-4 py-6">
        <.header>
          Rewards
          <:actions>
            <div class="flex items-center gap-4">
              <.link
                id="view-history"
                navigate={~p"/admin/rewards/history"}
                class="text-sm font-semibold text-base-content/60"
              >
                History
              </.link>
              <.link
                id="new-reward"
                navigate={~p"/admin/rewards/new"}
                class="text-sm font-semibold text-primary"
              >
                + Add
              </.link>
            </div>
          </:actions>
        </.header>

        <ul
          id="rewards"
          class="mt-4 divide-y divide-base-200 overflow-hidden rounded-2xl bg-base-100 shadow-sm"
        >
          <.reward_row
            :for={reward <- @rewards}
            reward={reward}
            kids={@kids}
            balances={@balances}
            redeeming={@redeeming}
          />
          <li :if={@rewards == []} class="px-4 py-3 text-sm text-base-content/40">
            No rewards yet
          </li>
        </ul>
      </div>
    </Layouts.admin>
    """
  end

  attr :reward, :map, required: true
  attr :kids, :list, required: true
  attr :balances, :map, required: true
  attr :redeeming, :integer, default: nil

  defp reward_row(assigns) do
    ~H"""
    <li id={"reward-#{@reward.id}"}>
      <div class="flex items-center gap-3 px-4 py-3">
        <span class="text-2xl leading-none">{@reward.icon}</span>
        <div class="min-w-0 flex-1">
          <p class="truncate font-medium">{@reward.name}</p>
          <p class="text-sm text-base-content/60">
            {@reward.points} pts · {if @reward.repeatable, do: "Repeatable", else: "One-time"} · {audience_label(
              @reward.kid
            )}
          </p>
        </div>

        <button
          id={"move-reward-up-#{@reward.id}"}
          phx-click="move"
          phx-value-reward-id={@reward.id}
          phx-value-dir="up"
          aria-label={"Move #{@reward.name} up"}
          class="rounded-lg p-2 text-base-content/60 transition active:scale-95"
        >
          <.icon name="hero-chevron-up" class="size-5" />
        </button>
        <button
          id={"move-reward-down-#{@reward.id}"}
          phx-click="move"
          phx-value-reward-id={@reward.id}
          phx-value-dir="down"
          aria-label={"Move #{@reward.name} down"}
          class="rounded-lg p-2 text-base-content/60 transition active:scale-95"
        >
          <.icon name="hero-chevron-down" class="size-5" />
        </button>

        <.link
          id={"edit-reward-#{@reward.id}"}
          navigate={~p"/admin/rewards/#{@reward}/edit"}
          class="text-sm font-semibold text-primary"
        >
          Edit
        </.link>

        <button
          id={"archive-reward-#{@reward.id}"}
          phx-click="archive"
          phx-value-reward-id={@reward.id}
          data-confirm={"Archive “#{@reward.name}”? It stays in the redemption history."}
          class="rounded-lg p-2 text-base-content/60 transition active:scale-95"
          title="Archive"
        >
          <.icon name="hero-archive-box" class="size-5" />
        </button>

        <button
          id={"redeem-reward-#{@reward.id}"}
          phx-click="toggle-redeem"
          phx-value-reward-id={@reward.id}
          class="rounded-lg p-2 text-base-content/60 transition active:scale-95"
          title="Direct-redeem"
        >
          <.icon name="hero-gift" class="size-5" />
        </button>
      </div>

      <div
        :if={@redeeming == @reward.id}
        id={"redeem-picker-#{@reward.id}"}
        class="divide-y divide-base-200 border-t border-base-200 bg-base-200/40"
      >
        <div
          :for={kid <- Enum.filter(@kids, &Rewards.offered?(@reward, &1.id))}
          id={"redeem-reward-#{@reward.id}-kid-#{kid.id}"}
          class="flex items-center justify-between gap-3 px-4 py-2"
        >
          <%!-- labeled as a balance, never a bare number beside a price (D64, D68) --%>
          <span class="min-w-0 flex-1 truncate">
            {kid.name} —
            <span id={"redeem-balance-#{@reward.id}-#{kid.id}"}>
              balance {Map.get(@balances, kid.id, 0)} ★
            </span>
          </span>
          <button
            id={"confirm-redeem-#{@reward.id}-#{kid.id}"}
            phx-click="redeem"
            phx-value-reward-id={@reward.id}
            phx-value-kid-id={kid.id}
            data-confirm={"Redeem “#{@reward.name}” (#{@reward.points} pts) for #{kid.name}?"}
            class="rounded-lg bg-primary px-3 py-1.5 text-sm font-semibold text-primary-content transition active:scale-95"
          >
            Redeem
          </button>
        </div>
      </div>
    </li>
    """
  end
end
