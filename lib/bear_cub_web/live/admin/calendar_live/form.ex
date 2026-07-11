defmodule BearCubWeb.Admin.CalendarLive.Form do
  use BearCubWeb, :live_view

  alias BearCub.Calendars
  alias BearCub.Calendars.Calendar
  alias BearCub.Chores

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:kids, Chores.list_kids())
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    calendar = %Calendar{}

    socket
    |> assign(page_title: "New Calendar", calendar: calendar)
    |> assign(:form, to_form(Calendars.change_calendar(calendar)))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    calendar = Calendars.get_calendar!(id)

    socket
    |> assign(page_title: "Edit Calendar", calendar: calendar)
    |> assign(:form, to_form(Calendars.change_calendar(calendar)))
  end

  @impl true
  def handle_event("validate", %{"calendar" => params}, socket) do
    changeset = Calendars.change_calendar(socket.assigns.calendar, params)
    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"calendar" => params}, socket) do
    save_calendar(socket, socket.assigns.live_action, params)
  end

  def handle_event("delete", _params, socket) do
    {:ok, _} = Calendars.delete_calendar(socket.assigns.calendar)

    {:noreply,
     socket
     |> put_flash(:info, "Calendar deleted")
     |> push_navigate(to: ~p"/admin/calendars")}
  end

  defp save_calendar(socket, :new, params) do
    case Calendars.create_calendar(params) do
      {:ok, _calendar} ->
        {:noreply,
         socket
         |> put_flash(:info, "Calendar created")
         |> push_navigate(to: ~p"/admin/calendars")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, action: :insert))}
    end
  end

  defp save_calendar(socket, :edit, params) do
    case Calendars.update_calendar(socket.assigns.calendar, params) do
      {:ok, _calendar} ->
        {:noreply,
         socket
         |> put_flash(:info, "Calendar updated")
         |> push_navigate(to: ~p"/admin/calendars")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, action: :update))}
    end
  end

  defp kid_options(kids) do
    [{"Family (both columns)", ""} | Enum.map(kids, &{&1.name, &1.id})]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} active={:calendars}>
      <div id="admin-calendar-form" class="mx-auto max-w-md px-4 py-6">
        <.header>{@page_title}</.header>

        <.form
          for={@form}
          id="calendar-form"
          phx-change="validate"
          phx-submit="save"
          class="space-y-4"
        >
          <.input field={@form[:label]} type="text" label="Label" />
          <.input field={@form[:ics_url]} type="text" label="ICS URL" />
          <.input
            field={@form[:kid_id]}
            type="select"
            label="Owner"
            options={kid_options(@kids)}
          />

          <.button class="btn btn-primary w-full">Save Calendar</.button>
        </.form>

        <button
          :if={@live_action == :edit}
          id="delete-calendar"
          phx-click="delete"
          data-confirm={"Delete “#{@calendar.label}”?"}
          class="mt-10 w-full rounded-xl border border-error/40 py-3 font-semibold text-error transition active:scale-95"
        >
          Delete Calendar
        </button>

        <.link
          navigate={~p"/admin/calendars"}
          class="mt-6 block text-center text-sm text-base-content/60"
        >
          Back to calendars
        </.link>
      </div>
    </Layouts.admin>
    """
  end
end
