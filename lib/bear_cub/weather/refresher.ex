defmodule BearCub.Weather.Refresher do
  @moduledoc """
  Scheduler for `BearCub.Weather.refresh/1`: refresh on init, then every
  30 minutes. All fetch/derive/store/broadcast logic lives in
  `BearCub.Weather`. Starts nothing (`:ignore`) when the coordinates are
  unset; disabled in test by `:weather_refresher_enabled`.
  """

  use GenServer

  alias BearCub.LocalTime
  alias BearCub.Weather

  @interval_ms :timer.minutes(30)

  def start_link(_opts) do
    if Weather.configured?() do
      GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    else
      :ignore
    end
  end

  @impl true
  def init(:ok) do
    Weather.refresh(LocalTime.now())
    schedule_refresh()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:refresh, state) do
    Weather.refresh(LocalTime.now())
    schedule_refresh()
    {:noreply, state}
  end

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @interval_ms)
end
