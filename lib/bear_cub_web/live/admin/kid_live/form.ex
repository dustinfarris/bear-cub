defmodule BearCubWeb.Admin.KidLive.Form do
  use BearCubWeb, :live_view

  alias BearCub.Chores

  # Curated identity palette (D23): every swatch keeps the white header
  # text legible in both themes. UI-only — the schema accepts any hex,
  # and a current color outside the palette shows as an extra swatch.
  @palette ~w(#dc2626 #ea580c #d97706 #16a34a #059669 #0d9488 #0284c7 #2563eb #7c3aed #db2777)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    kid = Chores.get_kid!(id)

    {:ok,
     socket
     |> assign(page_title: "Edit Kid", kid: kid, swatches: swatches(kid))
     |> assign(:form, to_form(Chores.change_kid(kid)))}
  end

  @impl true
  def handle_event("validate", %{"kid" => params}, socket) do
    changeset = Chores.change_kid(socket.assigns.kid, params)
    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"kid" => params}, socket) do
    case Chores.update_kid(socket.assigns.kid, params) do
      {:ok, _kid} ->
        {:noreply,
         socket
         |> put_flash(:info, "Kid updated")
         |> push_navigate(to: ~p"/admin/kids")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, action: :update))}
    end
  end

  defp swatches(kid) do
    if kid.color in @palette, do: @palette, else: @palette ++ [kid.color]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} active={:kids}>
      <div id="admin-kid-form" class="mx-auto max-w-md px-4 py-6">
        <.header>{@page_title}</.header>

        <.form for={@form} id="kid-form" phx-change="validate" phx-submit="save" class="space-y-4">
          <.input field={@form[:name]} type="text" label="Name" />

          <fieldset>
            <legend class="mb-2 text-sm font-medium">Color</legend>
            <%!-- Raw radios on purpose: <.input> has no radio type, and the
                 swatch look needs bespoke peer-checked styling. --%>
            <div id="color-swatches" class="flex flex-wrap gap-3">
              <label
                :for={color <- @swatches}
                id={"swatch-#{String.trim_leading(color, "#")}"}
                class="cursor-pointer"
              >
                <input
                  type="radio"
                  name={@form[:color].name}
                  value={color}
                  checked={@form[:color].value == color}
                  class="peer sr-only"
                />
                <span
                  class="block size-10 rounded-full ring-base-content ring-offset-2 ring-offset-base-100 transition peer-checked:ring-2"
                  style={"background-color: #{color}"}
                ></span>
              </label>
            </div>
          </fieldset>

          <.button class="btn btn-primary w-full">Save Kid</.button>
        </.form>

        <.link navigate={~p"/admin/kids"} class="mt-6 block text-center text-sm text-base-content/60">
          Back to kids
        </.link>
      </div>
    </Layouts.admin>
    """
  end
end
