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

  def handle_event("toggle-section", %{"kid-id" => kid_id, "routine" => routine}, socket) do
    key = {String.to_integer(kid_id), String.to_existing_atom(routine)}

    expanded =
      if MapSet.member?(socket.assigns.expanded, key),
        do: MapSet.delete(socket.assigns.expanded, key),
        else: MapSet.put(socket.assigns.expanded, key)

    {:noreply, assign(socket, :expanded, expanded)}
  end

  def handle_event("reset-kid", %{"kid-id" => id}, socket) do
    now = LocalTime.now()
    {:ok, _count} = Chores.reset_kid_day(Chores.get_kid!(id), now)

    {:noreply, load(socket, now)}
  end

  def handle_event("reset-day", _params, socket) do
    now = LocalTime.now()
    {:ok, _count} = Chores.reset_day(now)

    {:noreply, load(socket, now)}
  end

  @impl true
  def handle_info(:chores_changed, socket) do
    {:noreply, load(socket, LocalTime.now())}
  end

  defp load(socket, local_now) do
    {_state, active} = Routines.current(local_now)

    # done today? — derived, never stored (design §2)
    completions = Chores.current_completions(DateTime.to_date(local_now))

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

        %{kid: kid, sections: sections}
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
          :for={%{kid: kid, sections: sections} <- @cards}
          id={"today-kid-#{kid.id}"}
          class="overflow-hidden rounded-2xl bg-base-100 shadow-sm"
        >
          <header
            class="flex items-center justify-between px-5 py-3"
            style={"background-color: #{kid.color}"}
          >
            <h2 class="text-xl font-bold text-white drop-shadow-sm">{kid.name}</h2>
            <button
              id={"reset-kid-#{kid.id}"}
              phx-click="reset-kid"
              phx-value-kid-id={kid.id}
              data-confirm={"Reset #{kid.name}'s day? Every chore goes back to not done."}
              class="rounded-full bg-white/20 px-3 py-1 text-sm font-semibold text-white transition active:scale-95"
            >
              Reset day
            </button>
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
              <li
                :for={%{chore: chore, done?: done?} <- section.chores}
                id={"today-chore-#{chore.id}"}
                data-done={done?}
                phx-click="toggle-chore"
                phx-value-chore-id={chore.id}
                class="flex cursor-pointer select-none items-center gap-3 px-5 py-3 transition-colors"
                style={done? && "background-color: #{kid.color}"}
              >
                <span class="text-2xl leading-none">{chore.icon}</span>
                <span class={[
                  "min-w-0 flex-1 truncate font-medium",
                  done? && "text-white drop-shadow-sm"
                ]}>
                  {chore.name}
                </span>
                <.icon :if={done?} name="hero-check" class="size-6 text-white drop-shadow-sm" />
              </li>
              <li :if={section.chores == []} class="px-5 py-3 text-sm text-base-content/40">
                No chores
              </li>
            </ul>
          </div>
        </section>

        <button
          id="reset-day"
          phx-click="reset-day"
          data-confirm="Reset the whole day for everyone?"
          class="w-full rounded-xl border border-base-300 py-3 font-semibold text-base-content/70 transition active:scale-95"
        >
          Reset whole day
        </button>
      </div>
    </Layouts.admin>
    """
  end
end
