defmodule BearCubWeb.Admin.TodayLive do
  use BearCubWeb, :live_view

  alias BearCub.Chores
  alias BearCub.LocalTime
  alias BearCub.Routines

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Chores.subscribe()

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

  @impl true
  def handle_info(:chores_changed, socket) do
    {:noreply, load(socket, LocalTime.now())}
  end

  defp load(socket, local_now) do
    {_state, active} = Routines.current(local_now)
    today = DateTime.to_date(local_now)

    # done today? — derived, never stored (design §2)
    completions = Chores.current_completions(today)

    cards =
      for kid <- Chores.list_kids() do
        sections =
          for routine <- [active, Routines.other(active)] do
            chores =
              for chore <- Chores.list_chores(kid, Atom.to_string(routine)) do
                %{chore: chore, done?: Map.has_key?(completions, chore.id)}
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
            %{chore: extra, done?: Map.has_key?(completions, extra.id)}
          end

        %{kid: kid, sections: sections, extras: extras}
      end

    assign(socket, cards: cards, active: active)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} active={:today}>
      <div id="admin-today" class="mx-auto max-w-md space-y-6 px-4 py-6">
        <.header>Today</.header>

        <section
          :for={%{kid: kid, sections: sections, extras: extras} <- @cards}
          id={"today-kid-#{kid.id}"}
          class="overflow-hidden rounded-2xl bg-base-100 shadow-sm"
        >
          <header
            class="flex items-center justify-between px-5 py-3"
            style={"background-color: #{kid.color}"}
          >
            <h2 class="text-xl font-bold text-white drop-shadow-sm">{kid.name}</h2>
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
        :if={@row.done?}
        id={"fail-chore-#{@row.chore.id}"}
        phx-click="fail-chore"
        phx-value-chore-id={@row.chore.id}
        title="Fail — reverts and deducts points"
        class="rounded-full p-1 text-white/80 hover:text-white"
      >
        <.icon name="hero-flag" class="size-5 drop-shadow-sm" />
      </button>
      <.icon :if={@row.done?} name="hero-check" class="size-6 text-white drop-shadow-sm" />
    </li>
    """
  end
end
