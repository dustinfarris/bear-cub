defmodule BearCubWeb.Admin.ChoreLive.Form do
  use BearCubWeb, :live_view

  alias BearCub.Chores
  alias BearCub.Chores.Chore

  @impl true
  def mount(params, _session, socket) do
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, params) do
    kid = Chores.get_kid!(params["kid"])
    routine = if params["routine"] in ~w(morning evening), do: params["routine"], else: "morning"
    chore = %Chore{kid_id: kid.id, routine: routine}

    socket
    |> assign(page_title: "New Chore", kid: kid, chore: chore)
    |> assign(:form, to_form(Chores.change_chore(chore)))
  end

  defp apply_action(socket, :edit, params) do
    chore = Chores.get_chore!(params["id"])
    kid = Chores.get_kid!(chore.kid_id)

    socket
    |> assign(page_title: "Edit Chore", kid: kid, chore: chore)
    |> assign(:form, to_form(Chores.change_chore(chore)))
  end

  @impl true
  def handle_event("validate", %{"chore" => params}, socket) do
    changeset = Chores.change_chore(socket.assigns.chore, params)
    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"chore" => params}, socket) do
    save_chore(socket, socket.assigns.live_action, params)
  end

  def handle_event("delete", _params, socket) do
    # deleting cascades the chore's completions — an explicit parent
    # choice, distinct from FR-17's "undo never deletes" (design §1)
    {:ok, _} = Chores.delete_chore(socket.assigns.chore)

    {:noreply,
     socket
     |> put_flash(:info, "Chore deleted")
     |> push_navigate(to: ~p"/admin/chores?kid=#{socket.assigns.kid.id}")}
  end

  defp save_chore(socket, :new, params) do
    case Chores.create_chore(socket.assigns.kid, params) do
      {:ok, _chore} ->
        {:noreply,
         socket
         |> put_flash(:info, "Chore created")
         |> push_navigate(to: ~p"/admin/chores?kid=#{socket.assigns.kid.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, action: :insert))}
    end
  end

  defp save_chore(socket, :edit, params) do
    case Chores.update_chore(socket.assigns.chore, params) do
      {:ok, _chore} ->
        {:noreply,
         socket
         |> put_flash(:info, "Chore updated")
         |> push_navigate(to: ~p"/admin/chores?kid=#{socket.assigns.kid.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, action: :update))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} active={:chores}>
      <div id="admin-chore-form" class="mx-auto max-w-md px-4 py-6">
        <.header>
          {@page_title}
          <:subtitle>for {@kid.name}</:subtitle>
        </.header>

        <.form for={@form} id="chore-form" phx-change="validate" phx-submit="save" class="space-y-2">
          <.input field={@form[:name]} type="text" label="Name" />
          <.input field={@form[:icon]} type="text" label="Icon (emoji)" placeholder="🪥" />
          <.input
            field={@form[:routine]}
            type="select"
            label="Routine"
            options={[{"Morning", "morning"}, {"Evening", "evening"}]}
          />

          <.button class="btn btn-primary w-full">Save Chore</.button>
        </.form>

        <button
          :if={@live_action == :edit}
          id="delete-chore"
          phx-click="delete"
          data-confirm={"Delete “#{@chore.name}”? Its completion history is deleted with it."}
          class="mt-10 w-full rounded-xl border border-error/40 py-3 font-semibold text-error transition active:scale-95"
        >
          Delete Chore
        </button>

        <.link
          navigate={~p"/admin/chores?kid=#{@kid.id}"}
          class="mt-6 block text-center text-sm text-base-content/60"
        >
          Back to chores
        </.link>
      </div>
    </Layouts.admin>
    """
  end
end
