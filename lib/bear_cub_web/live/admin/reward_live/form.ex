defmodule BearCubWeb.Admin.RewardLive.Form do
  use BearCubWeb, :live_view

  alias BearCub.Chores
  alias BearCub.Rewards
  alias BearCub.Rewards.Reward

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:kids, Chores.list_kids())
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    reward = %Reward{}

    socket
    |> assign(page_title: "New Reward", reward: reward, kid_id_param: "")
    |> assign(:form, to_form(Rewards.change_reward(reward)))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    reward = Rewards.get_reward!(id)

    socket
    |> assign(
      page_title: "Edit Reward",
      reward: reward,
      kid_id_param: kid_id_param(reward.kid_id)
    )
    |> assign(:form, to_form(Rewards.change_reward(reward)))
  end

  defp kid_id_param(nil), do: ""
  defp kid_id_param(id), do: Integer.to_string(id)

  @impl true
  def handle_event("validate", %{"reward" => params}, socket) do
    changeset = Rewards.change_reward(socket.assigns.reward, params)

    {:noreply,
     socket
     |> assign(:kid_id_param, params["kid_id"] || "")
     |> assign(:form, to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"reward" => params}, socket) do
    save_reward(socket, socket.assigns.live_action, params)
  end

  defp save_reward(socket, :new, params) do
    case Rewards.create_reward(resolve_kid(params["kid_id"]), params) do
      {:ok, _reward} ->
        {:noreply,
         socket
         |> put_flash(:info, "Reward created")
         |> push_navigate(to: ~p"/admin/rewards")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, action: :insert))}
    end
  end

  defp save_reward(socket, :edit, params) do
    case Rewards.update_reward(socket.assigns.reward, resolve_kid(params["kid_id"]), params) do
      {:ok, _reward} ->
        {:noreply,
         socket
         |> put_flash(:info, "Reward updated")
         |> push_navigate(to: ~p"/admin/rewards")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, action: :update))}
    end
  end

  # kid_id is set programmatically from this resolved selection, never
  # cast from attrs (D58) — matching Chores.create_chore/3's kid_id
  # treatment.
  defp resolve_kid(nil), do: nil
  defp resolve_kid(""), do: nil
  defp resolve_kid(id), do: Chores.get_kid!(id)

  defp kid_options(kids) do
    [{"Anyone", ""} | Enum.map(kids, &{&1.name, &1.id})]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} active={:rewards} static_reload_href={@static_reload_href}>
      <div id="admin-reward-form" class="mx-auto max-w-md px-4 py-6">
        <.header>{@page_title}</.header>

        <.form
          for={@form}
          id="reward-form"
          phx-change="validate"
          phx-submit="save"
          class="space-y-2"
        >
          <.input field={@form[:name]} type="text" label="Name" />
          <.input field={@form[:icon]} type="text" label="Icon (emoji)" />
          <.input field={@form[:points]} type="number" label="Price (points)" />
          <.input field={@form[:repeatable]} type="checkbox" label="Repeatable" />
          <.input
            type="select"
            id="reward_kid_id"
            name="reward[kid_id]"
            label="For"
            value={@kid_id_param}
            options={kid_options(@kids)}
          />

          <.button class="btn btn-primary w-full">Save Reward</.button>
        </.form>

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
end
