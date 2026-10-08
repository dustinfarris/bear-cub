defmodule BearCub.Weather.RefresherTest do
  use ExUnit.Case, async: false

  alias BearCub.Weather
  alias BearCub.Weather.Refresher

  setup context do
    Req.Test.set_req_test_to_shared(context)

    old =
      for k <- [:weather_latitude, :weather_longitude], do: {k, Application.get_env(:bear_cub, k)}

    on_exit(fn ->
      for {k, v} <- old do
        if v == nil,
          do: Application.delete_env(:bear_cub, k),
          else: Application.put_env(:bear_cub, k, v)
      end

      Weather.reset()
    end)

    Weather.reset()
    :ok
  end

  defp today, do: BearCub.LocalTime.now() |> DateTime.to_date()

  defp stub_forecast(high) do
    date = Date.to_iso8601(today())
    times = for h <- 0..23, do: "#{date}T#{String.pad_leading("#{h}", 2, "0")}:00"

    forecast = %{
      "daily" => %{"time" => [date], "temperature_2m_max" => [high]},
      "hourly" => %{
        "time" => times,
        "precipitation_probability" => List.duplicate(0, 24),
        "weather_code" => List.duplicate(0, 24)
      }
    }

    Req.Test.stub(Weather, &Req.Test.json(&1, forecast))
  end

  test "refreshes on init and again on :refresh" do
    Application.put_env(:bear_cub, :weather_latitude, 47.6)
    Application.put_env(:bear_cub, :weather_longitude, -122.3)
    Weather.subscribe()
    stub_forecast(95)

    pid = start_supervised!(Refresher)
    assert_receive :weather_changed
    assert %{temp: :hot} = Weather.current(today())

    stub_forecast(20)
    send(pid, :refresh)
    assert_receive :weather_changed, 500
    assert %{temp: :cold} = Weather.current(today())
  end

  test "does not start when the coordinates are unset" do
    Application.delete_env(:bear_cub, :weather_latitude)
    Application.delete_env(:bear_cub, :weather_longitude)

    assert start_supervised(Refresher) == {:ok, :undefined}
    assert Process.whereis(Refresher) == nil
  end
end
