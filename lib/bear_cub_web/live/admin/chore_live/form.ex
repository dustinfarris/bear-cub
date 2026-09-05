defmodule BearCubWeb.Admin.ChoreLive.Form do
  use BearCubWeb, :live_view

  alias BearCub.Chores
  alias BearCub.Chores.Chore
  alias BearCub.LocalTime

  @impl true
  def mount(params, _session, socket) do
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, params) do
    kid = Chores.get_kid!(params["kid"])
    routine = if params["routine"] in ~w(morning evening), do: params["routine"], else: nil
    chore = %Chore{kid_id: kid.id, routine: routine}

    socket
    |> assign(page_title: "New Chore", kid: kid, chore: chore, show_shows_in?: is_nil(routine))
    |> assign(:form, to_form(Chores.change_chore(chore)))
  end

  defp apply_action(socket, :edit, params) do
    chore = Chores.get_chore!(params["id"])
    kid = Chores.get_kid!(chore.kid_id)

    socket
    |> assign(page_title: "Edit Chore", kid: kid, chore: chore, show_shows_in?: true)
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

  def handle_event("archive", _params, socket) do
    {:ok, _} = Chores.archive_chore(socket.assigns.chore, LocalTime.now())

    {:noreply,
     socket
     |> put_flash(:info, "Chore archived")
     |> push_navigate(to: ~p"/admin/chores?kid=#{socket.assigns.kid.id}")}
  end

  defp save_chore(socket, :new, params) do
    # the select is hidden when a routine was forced by the URL param —
    # the bucket comes from that (socket.assigns.chore.routine), never
    # from the submitted form; drop any forged "shows_in" so it cannot
    # override the forced routine via the changeset's derivation
    params =
      case socket.assigns.chore.routine do
        nil -> params
        routine -> params |> Map.delete("shows_in") |> Map.put("routine", routine)
      end

    case Chores.create_chore(socket.assigns.kid, params, LocalTime.now()) do
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
    <Layouts.admin flash={@flash} active={:chores} static_reload_href={@static_reload_href}>
      <div id="admin-chore-form" class="mx-auto max-w-md px-4 py-6">
        <.header>
          {@page_title}
          <:subtitle>for {@kid.name}</:subtitle>
        </.header>

        <.form for={@form} id="chore-form" phx-change="validate" phx-submit="save" class="space-y-2">
          <.input field={@form[:name]} type="text" label="Name" />
          <.input field={@form[:icon]} type="text" label="Icon (emoji)" placeholder="🪥" />
          <.input field={@form[:points]} type="number" label="Points" />
          <.input
            :if={@show_shows_in?}
            field={@form[:shows_in]}
            type="select"
            label="Shows in"
            options={[
              {"Morning routine", "morning"},
              {"Evening routine", "evening"},
              {"After routines (extra)", "extra"},
              {"After routines (repeats daily)", "extra_daily"}
            ]}
          />

          <.button class="btn btn-primary w-full">Save Chore</.button>
        </.form>

        <button
          :if={@live_action == :edit}
          id="archive-chore"
          phx-click="archive"
          data-confirm={"Archive “#{@chore.name}”? It stays in the points history."}
          class="mt-10 w-full rounded-xl border border-error/40 py-3 font-semibold text-error transition active:scale-95"
        >
          Archive Chore
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
