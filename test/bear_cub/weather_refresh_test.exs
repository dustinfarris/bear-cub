defmodule BearCub.WeatherRefreshTest do
  # The held reading is global state (persistent_term), so this file is
  # synchronous and resets the store around every test.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias BearCub.Weather
  alias BearCub.Weather.Reading

  @lat 47.60621
  @lon -122.33207
  @date "2026-10-08"

  setup context do
    Req.Test.set_req_test_to_shared(context)

    env = [
      weather_latitude: @lat,
      weather_longitude: @lon,
      weather_hot_at: 80,
      weather_cold_below: 50,
      weather_precip_chance_at: 40
    ]

    old = for {k, _} <- env, do: {k, Application.get_env(:bear_cub, k)}
    for {k, v} <- env, do: Application.put_env(:bear_cub, k, v)
    Weather.reset()
    Weather.subscribe()

    on_exit(fn ->
      for {k, v} <- old do
        if v == nil,
          do: Application.delete_env(:bear_cub, k),
          else: Application.put_env(:bear_cub, k, v)
      end

      Weather.reset()
    end)

    :ok
  end

  defp now, do: DateTime.new!(~D[2026-10-08], ~T[07:00:00], "America/Los_Angeles")
  defp today, do: ~D[2026-10-08]

  defp forecast(high \\ 65.0, date \\ @date) do
    times = for h <- 0..23, do: "#{date}T#{String.pad_leading("#{h}", 2, "0")}:00"

    %{
      "daily" => %{"time" => [date], "temperature_2m_max" => [high]},
      "hourly" => %{
        "time" => times,
        "precipitation_probability" => List.duplicate(0, 24),
        "weather_code" => List.duplicate(0, 24)
      }
    }
  end

  defp stub_forecast(forecast), do: Req.Test.stub(Weather, &Req.Test.json(&1, forecast))

  test "success stores the reading and broadcasts" do
    stub_forecast(forecast(90))
    Weather.refresh(now())

    assert %Reading{temp: :hot, precip: :none, date: ~D[2026-10-08]} = Weather.current(today())
    assert_receive :weather_changed
  end

  test "the request carries rounded coordinates, the timezone and one day" do
    test_pid = self()

    Req.Test.stub(Weather, fn conn ->
      send(test_pid, {:query, conn.query_params})
      Req.Test.json(conn, forecast())
    end)

    Weather.refresh(now())

    assert_receive {:query, q}
    assert q["latitude"] == "47.61"
    assert q["longitude"] == "-122.33"
    assert q["timezone"] == "America/Los_Angeles"
    assert q["forecast_days"] == "1"
    assert q["temperature_unit"] == "fahrenheit"
    assert q["daily"] == "temperature_2m_max"
    assert q["hourly"] == "precipitation_probability,weather_code"
  end

  test "an unchanged reading does not broadcast again" do
    stub_forecast(forecast(90))
    Weather.refresh(now())
    assert_receive :weather_changed

    Weather.refresh(now())
    refute_receive :weather_changed, 50
  end

  test "a changed reading broadcasts again" do
    stub_forecast(forecast(90))
    Weather.refresh(now())
    assert_receive :weather_changed

    stub_forecast(forecast(30))
    Weather.refresh(now())
    assert_receive :weather_changed
    assert %Reading{temp: :cold} = Weather.current(today())
  end

  test "current/1 offers a reading only for its own date" do
    stub_forecast(forecast())
    Weather.refresh(now())

    assert %Reading{} = Weather.current(today())
    assert Weather.current(Date.add(today(), 1)) == nil
    assert Weather.current(Date.add(today(), -1)) == nil
  end

  test "current/1 is nil before any fetch" do
    assert Weather.current(today()) == nil
  end

  describe "failures" do
    setup do
      stub_forecast(forecast(90))
      Weather.refresh(now())
      assert_receive :weather_changed
      :ok
    end

    defp failing(:http_500, conn), do: Plug.Conn.send_resp(conn, 500, "boom")
    defp failing(:transport, conn), do: Req.Test.transport_error(conn, :timeout)
    defp failing(:bad_json, conn), do: Plug.Conn.send_resp(conn, 200, "{nope")
    defp failing(:missing, conn), do: Req.Test.json(conn, %{"daily" => %{}})

    for kind <- [:http_500, :transport, :bad_json, :missing] do
      test "#{kind} keeps today's reading and does not broadcast" do
        Req.Test.stub(Weather, &failing(unquote(kind), &1))

        log = capture_log(fn -> Weather.refresh(now()) end)

        assert log =~ "[warning]"
        assert %Reading{temp: :hot} = Weather.current(today())
        refute_receive :weather_changed, 50
      end
    end

    test "a failure on the next day drops yesterday's reading" do
      Req.Test.stub(Weather, &Plug.Conn.send_resp(&1, 500, "boom"))
      tomorrow = DateTime.add(now(), 86_400)

      capture_log(fn -> Weather.refresh(tomorrow) end)

      assert Weather.current(Date.add(today(), 1)) == nil
      assert Weather.current(today()) == nil
    end

    test "a failure never logs the coordinates" do
      for stub <- [
            &Plug.Conn.send_resp(&1, 500, "boom"),
            &Req.Test.transport_error(&1, :timeout),
            &Plug.Conn.send_resp(&1, 200, "{nope")
          ] do
        Req.Test.stub(Weather, stub)
        log = capture_log(fn -> Weather.refresh(now()) end)

        for needle <- ["47.60621", "-122.33207", "47.61", "-122.33"] do
          refute log =~ needle
        end
      end
    end
  end

  test "a failure with nothing held leaves no reading" do
    Req.Test.stub(Weather, &Plug.Conn.send_resp(&1, 503, "down"))
    capture_log(fn -> Weather.refresh(now()) end)
    assert Weather.current(today()) == nil
  end
end
