defmodule BearCubWeb.Admin.RewardLive.History do
  use BearCubWeb, :live_view

  alias BearCub.LocalTime
  alias BearCub.Rewards

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Rewards.subscribe()

    {:ok, load(socket)}
  end

  @impl true
  def handle_info(:rewards_changed, socket), do: {:noreply, load(socket)}

  defp load(socket), do: assign(socket, :redemptions, Rewards.list_redemption_history())

  # The row's one date: the verdict date (approved or declined) —
  # requested_at plays no display role here (D70), matching
  # list_redemption_history/1's own ordering key.
  defp verdict_at(%{approved_at: at}) when not is_nil(at), do: at
  defp verdict_at(%{declined_at: at}), do: at

  defp state_label(redemption) do
    cond do
      Rewards.reversed?(redemption) -> "Reversed"
      Rewards.declined?(redemption) -> "Declined"
      Rewards.approved?(redemption) -> "Approved"
    end
  end

  defp format_date(%DateTime{} = utc_time) do
    utc_time
    |> DateTime.shift_zone!(LocalTime.timezone())
    |> Calendar.strftime("%b %-d, %Y")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} active={:rewards}>
      <div id="admin-rewards-history" class="mx-auto max-w-md px-4 py-6">
        <.header>
          History
          <:subtitle>Showing the last 50 redemptions — no pagination</:subtitle>
        </.header>

        <ul
          id="history"
          class="mt-4 divide-y divide-base-200 overflow-hidden rounded-2xl bg-base-100 shadow-sm"
        >
          <.history_row :for={redemption <- @redemptions} redemption={redemption} />
          <li :if={@redemptions == []} class="px-4 py-3 text-sm text-base-content/40">
            No redemptions yet
          </li>
        </ul>

        <.link
          navigate={~p"/admin/rewards"}
          class="mt-6 block text-center text-sm text-base-content/60"
        >
          Back to rewards
        </.link>
      </div>
    </Layouts.admin>
    """
  end

  attr :redemption, :map, required: true

  defp history_row(assigns) do
    ~H"""
    <li id={"history-#{@redemption.id}"} class="flex items-center gap-3 px-4 py-3">
      <span
        class="size-2.5 shrink-0 rounded-full"
        style={"background-color: #{@redemption.kid.color}"}
      ></span>
      <span class="text-2xl leading-none">{@redemption.reward.icon}</span>
      <div class="min-w-0 flex-1">
        <p class="truncate font-medium">
          {@redemption.kid.name} · {@redemption.reward.name}
        </p>
        <p class="text-sm text-base-content/60">
          {format_date(verdict_at(@redemption))} ·
          <span class={Rewards.reversed?(@redemption) && "line-through"}>
            {@redemption.points} pts
          </span>
          · {state_label(@redemption)}
        </p>
        <p :if={Rewards.reversed?(@redemption)} class="text-sm text-base-content/40">
          reversed {format_date(@redemption.reversed_at)}
        </p>
      </div>
    </li>
    """
  end
end
