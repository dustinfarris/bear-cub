defmodule BearCub.Calendars.Refresher do
  @moduledoc """
  The app's only periodic process (design §6): on boot, hydrates the
  events store from each calendar's cached payload (so a restart serves
  last-known-good events before any network call), then performs a live
  fetch of every calendar and reschedules itself at
  `Calendars.refresh_interval_ms/0`. All the fetch/parse/store/broadcast
  logic lives in `BearCub.Calendars` — this module is just the scheduler.

  Disabled in test (`config :bear_cub, :calendar_refresher_enabled`);
  specs call `BearCub.Calendars` directly instead.
  """

  use GenServer

  alias BearCub.Calendars
  alias BearCub.LocalTime

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    local_now = LocalTime.now()
    Calendars.hydrate_cache(local_now)
    Calendars.refresh_all(local_now)
    schedule_refresh()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:refresh, state) do
    Calendars.refresh_all(LocalTime.now())
    schedule_refresh()
    {:noreply, state}
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, Calendars.refresh_interval_ms())
  end
end
