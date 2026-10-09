defmodule BearCubWeb.Admin.ScheduleLive do
  @moduledoc """
  The phone-admin Schedule page (D125): one form over
  `Schedules.change_version/1` whose Save inserts a new schedule version in
  force at once. Shaped by hand rather than scaffolded — there is no
  resource to create, edit or delete, only a history that grows.

  The unsaved form is kept as a params map (`:params`) beside the form
  itself, because "Copy to" is a click, and a click carries none of the
  form's values. Copying rewrites those params and re-validates; it never
  reaches `Schedules.change/1`, so nothing is recorded until Save.
  """
  use BearCubWeb, :live_view

  alias BearCub.Chores
  alias BearCub.Schedules

  @weekdays ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)
  @time_fields ~w(morning_start morning_end evening_start evening_end early_bird_cutoff)a
  @copy_targets %{"weekdays" => 1..5, "weekend" => 6..7, "all" => 1..7}

  @impl true
  def mount(_params, _session, socket) do
    current = Schedules.current()
    kids = Chores.list_kids()
    params = params_for(current, kids)

    {:ok,
     socket
     |> assign(page_title: "Schedule", current_id: current.id, kids: kids)
     |> assign_form(Schedules.change_version(params), params)}
  end

  @impl true
  def handle_event("validate", %{"schedule" => params}, socket) do
    {:noreply, assign_form(socket, Schedules.change_version(params), params, :validate)}
  end

  def handle_event("save", %{"schedule" => params}, socket) do
    case Schedules.change(params) do
      {:ok, version} ->
        {:noreply, saved(socket, version)}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset, params, changeset.action || :validate)}
    end
  end

  def handle_event("copy", %{"from" => from, "to" => group}, socket) do
    params = copy_day(socket.assigns.params, from, Map.fetch!(@copy_targets, group))
    {:noreply, assign_form(socket, Schedules.change_version(params), params, :validate)}
  end

  defp saved(socket, %{id: id} = version) do
    if id == socket.assigns.current_id do
      put_flash(socket, :info, "No changes to save")
    else
      params = params_for(version, socket.assigns.kids)

      socket
      |> assign(:current_id, id)
      |> assign_form(Schedules.change_version(params), params)
      |> put_flash(:info, "Saved — in effect now")
    end
  end

  defp assign_form(socket, changeset, params, action \\ nil) do
    form = to_form(changeset, as: :schedule, action: action)
    days = Ecto.Changeset.get_field(changeset, :days) || []
    monday = Enum.find(days, &(&1.weekday == 1))

    assign(socket, form: form, params: params, monday: monday)
  end

  # The form params for a saved version: Monday to Sunday, so card `i`
  # always holds weekday `i + 1`, with times as the "HH:MM" a time input
  # shows and sends. Each card also carries one Night Owl cutoff per kid, in
  # kid order and keyed by that position, blank when the kid has none saved
  # (D137): `Schedules` never queries kids, so the page supplies the list.
  defp params_for(version, kids) do
    days =
      version.days
      |> Enum.sort_by(& &1.weekday)
      |> Enum.with_index()
      |> Map.new(fn {day, index} ->
        times = Map.new(@time_fields, &{to_string(&1), format_time(Map.fetch!(day, &1))})

        cutoffs = Map.new(day.night_owl_cutoffs, &{&1.kid_id, &1.cutoff})

        night_owl =
          kids
          |> Enum.with_index()
          |> Map.new(fn {kid, kid_index} ->
            cutoff = if time = cutoffs[kid.id], do: format_time(time), else: ""
            {to_string(kid_index), %{"kid_id" => to_string(kid.id), "cutoff" => cutoff}}
          end)

        {to_string(index),
         times
         |> Map.put("weekday", to_string(day.weekday))
         |> Map.put("night_owl_cutoffs", night_owl)}
      end)

    %{
      "routine_bonus" => to_string(version.routine_bonus),
      "early_bird_bonus" => to_string(version.early_bird_bonus),
      "night_owl_bonus" => to_string(version.night_owl_bonus),
      "days" => days
    }
  end

  defp format_time(time), do: Calendar.strftime(time, "%H:%M")

  # A time input shows minutes; the changeset hands back a `Time` for a
  # cast value and the typed "HH:MM" string otherwise, so settle both on
  # "HH:MM" and a card never flips between the two spellings.
  defp time_value(%Time{} = time), do: format_time(time)
  defp time_value(<<hhmm::binary-size(5), ":", _seconds::binary-size(2)>>), do: hhmm
  defp time_value(value), do: value

  defp copy_day(params, from, targets) do
    days = params["days"]
    {_, source} = Enum.find(days, fn {_, day} -> day["weekday"] == from end)
    timings = Map.take(source, ["night_owl_cutoffs" | Enum.map(@time_fields, &to_string/1)])

    days =
      Map.new(days, fn {index, day} ->
        if day["weekday"] != from and String.to_integer(day["weekday"]) in targets,
          do: {index, Map.merge(day, timings)},
          else: {index, day}
      end)

    Map.put(params, "days", days)
  end

  # A card is "custom" when any of its five times, or any kid's Night Owl
  # cutoff, differs from Monday's in the current, possibly unsaved, form
  # state.
  defp custom?(_day, nil), do: false

  defp custom?(day, %{} = monday) do
    entry = Ecto.Changeset.apply_changes(day.source)

    Enum.any?(@time_fields, &(Map.fetch!(entry, &1) != Map.fetch!(monday, &1))) or
      sorted_cutoffs(entry) != sorted_cutoffs(monday)
  end

  defp sorted_cutoffs(entry),
    do: entry.night_owl_cutoffs |> Enum.map(&{&1.kid_id, &1.cutoff}) |> Enum.sort()

  # The typed "HH:MM" for one kid's field in one card, from the unsaved form.
  defp cutoff_value(params, day_index, kid_index) do
    params
    |> get_in(["days", to_string(day_index), "night_owl_cutoffs", to_string(kid_index), "cutoff"])
    |> time_value()
    |> case do
      "" -> nil
      value -> value
    end
  end

  # The error on one kid's cutoff, once the form has been acted on. Errors
  # sit on the nested entries, which only exist for kids with a cutoff typed.
  defp cutoff_errors(%{source: %{action: nil}}, _kid), do: []

  defp cutoff_errors(day, kid) do
    day.source
    |> Ecto.Changeset.get_embed(:night_owl_cutoffs, :changeset)
    |> Enum.filter(&(Ecto.Changeset.get_field(&1, :kid_id) == kid.id))
    |> Enum.flat_map(& &1.errors)
    |> Enum.map(fn {_field, error} -> translate_error(error) end)
  end

  defp weekday_name(weekday), do: Enum.at(@weekdays, weekday - 1)

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true

  # A time input in a wrapper carrying the field name, so a test (and the
  # eye) can find the error that belongs to this field of this card.
  defp time_input(assigns) do
    ~H"""
    <div data-field={@field.field}>
      <.input field={@field} type="time" label={@label} value={time_value(@field.value)} />
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} active={:schedule} static_reload_href={@static_reload_href}>
      <div id="admin-schedule" class="mx-auto max-w-md px-4 py-6">
        <.header>Schedule</.header>

        <.form
          for={@form}
          id="schedule-form"
          phx-change="validate"
          phx-submit="save"
          class="space-y-4"
        >
          <p
            :for={{message, _} <- @form[:effective_at].errors}
            id="schedule-collision"
            role="alert"
            class="rounded-lg bg-error/10 px-3 py-2 text-sm text-error"
          >
            Another save landed in the same second — {message}; please try again.
          </p>

          <section id="bonuses" class="grid grid-cols-2 gap-3 rounded-box bg-base-100 p-4 shadow-sm">
            <.input field={@form[:routine_bonus]} type="number" min="0" label="Routine bonus" />
            <div>
              <.input field={@form[:early_bird_bonus]} type="number" min="0" label="Early bird bonus" />
              <p class="-mt-1 text-xs text-base-content/60">0 turns it off</p>
            </div>
            <div>
              <.input field={@form[:night_owl_bonus]} type="number" min="0" label="Sleepy bear bonus" />
              <p class="-mt-1 text-xs text-base-content/60">0 turns it off</p>
            </div>
          </section>

          <.inputs_for :let={day} field={@form[:days]}>
            <% weekday = day.index + 1 %>
            <section
              id={"day-card-#{weekday}"}
              class="rounded-box bg-base-100 p-4 shadow-sm"
            >
              <input type="hidden" name={day[:weekday].name} value={weekday} />

              <div class="mb-2 flex items-center justify-between gap-2">
                <h2 class="font-semibold">{weekday_name(weekday)}</h2>
                <span
                  :if={custom?(day, @monday)}
                  data-custom
                  class="text-xs font-medium text-base-content/50"
                >
                  custom
                </span>
              </div>

              <div class="grid grid-cols-2 gap-x-3">
                <.time_input field={day[:morning_start]} label="Morning start" />
                <.time_input field={day[:morning_end]} label="Morning end" />
                <.time_input field={day[:evening_start]} label="Evening start" />
                <.time_input field={day[:evening_end]} label="Evening end" />
                <.time_input field={day[:early_bird_cutoff]} label="Early bird cutoff" />
              </div>

              <fieldset class="mt-1">
                <legend class="label mb-1">Sleepy bear (blank = no Sleepy Bear)</legend>
                <div class="grid grid-cols-2 gap-x-3">
                  <div
                    :for={{kid, kid_index} <- Enum.with_index(@kids)}
                    data-kid={kid.id}
                    class="fieldset mb-2"
                  >
                    <input
                      type="hidden"
                      name={"#{day.name}[night_owl_cutoffs][#{kid_index}][kid_id]"}
                      value={kid.id}
                    />
                    <label for={"#{day.id}_night_owl_#{kid.id}"}>
                      <span class="label mb-1 gap-1.5">
                        <span
                          data-dot
                          class="inline-block size-2.5 rounded-full"
                          style={"background-color: #{kid.color}"}
                        ></span>
                        {kid.name}
                      </span>
                      <input
                        type="time"
                        id={"#{day.id}_night_owl_#{kid.id}"}
                        name={"#{day.name}[night_owl_cutoffs][#{kid_index}][cutoff]"}
                        value={cutoff_value(@params, day.index, kid_index)}
                        class={[
                          "w-full input",
                          cutoff_errors(day, kid) != [] && "input-error"
                        ]}
                      />
                    </label>
                    <p
                      :for={message <- cutoff_errors(day, kid)}
                      class="mt-1.5 flex items-center gap-2 text-sm text-error"
                    >
                      <.icon name="hero-exclamation-circle" class="size-5" />
                      {message}
                    </p>
                  </div>
                </div>
              </fieldset>

              <div class="mt-2 flex flex-wrap items-center gap-2 text-xs">
                <span class="text-base-content/60">Copy to</span>
                <button
                  :for={
                    {group, label} <- [
                      {"weekdays", "weekdays"},
                      {"weekend", "weekend"},
                      {"all", "all days"}
                    ]
                  }
                  type="button"
                  id={"copy-#{weekday}-#{group}"}
                  phx-click="copy"
                  phx-value-from={weekday}
                  phx-value-to={group}
                  class="btn btn-xs btn-ghost"
                >
                  {label}
                </button>
              </div>
            </section>
          </.inputs_for>

          <.button class="btn btn-primary w-full" phx-disable-with="Saving...">Save</.button>
        </.form>
      </div>
    </Layouts.admin>
    """
  end
end
