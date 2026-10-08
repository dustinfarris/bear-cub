defmodule BearCub.WeatherTest do
  use ExUnit.Case, async: true

  alias BearCub.Weather
  alias BearCub.Weather.Reading

  @thresholds %{hot_at: 80, cold_below: 50, precip_chance_at: 40}
  @date "2026-10-08"

  # Builds a decoded Open-Meteo forecast (string keys). `hours` overrides
  # per-hour `{chance, code}` keyed by integer hour; every other hour
  # defaults to `{0, 0}`.
  defp forecast(opts \\ []) do
    high = Keyword.get(opts, :high, 65.0)
    hours = Keyword.get(opts, :hours, %{})

    times = for h <- 0..23, do: "#{@date}T#{String.pad_leading("#{h}", 2, "0")}:00"
    rows = for h <- 0..23, do: Map.get(hours, h, {0, 0})

    %{
      "daily" => %{
        "time" => [Keyword.get(opts, :date, @date)],
        "temperature_2m_max" => [high]
      },
      "hourly" => %{
        "time" => times,
        "precipitation_probability" => Enum.map(rows, &elem(&1, 0)),
        "weather_code" => Enum.map(rows, &elem(&1, 1))
      }
    }
  end

  defp derive(forecast), do: Weather.derive(forecast, @thresholds)

  describe "temp" do
    test "high at hot_at reads hot" do
      assert %Reading{temp: :hot} = derive(forecast(high: 80))
    end

    test "high just under hot_at reads normal" do
      assert %Reading{temp: :normal} = derive(forecast(high: 79.9))
    end

    test "high at cold_below reads normal" do
      assert %Reading{temp: :normal} = derive(forecast(high: 50))
    end

    test "one degree under cold_below reads cold" do
      assert %Reading{temp: :cold} = derive(forecast(high: 49))
    end
  end

  describe "precip" do
    test "all rows under the threshold read none" do
      f = forecast(hours: %{12 => {39, 61}})
      assert %Reading{precip: :none} = derive(f)
    end

    test "one row exactly at the threshold reads rain" do
      f = forecast(hours: %{12 => {40, 61}})
      assert %Reading{precip: :rain} = derive(f)
    end

    test "a 5% row with a rain code reads none" do
      f = forecast(hours: %{12 => {5, 63}})
      assert %Reading{precip: :none} = derive(f)
    end

    test "a qualifying row with a snow code reads snow" do
      for code <- [71, 73, 75, 77, 85, 86] do
        f = forecast(hours: %{12 => {60, code}})
        assert %Reading{precip: :snow} = derive(f), "code #{code}"
      end
    end

    test "rain and snow rows both qualifying read snow" do
      f = forecast(hours: %{10 => {60, 61}, 13 => {60, 73}})
      assert %Reading{precip: :snow} = derive(f)
    end

    test "a snow code only in a non-qualifying row is not snow" do
      f = forecast(hours: %{10 => {60, 61}, 13 => {10, 73}})
      assert %Reading{precip: :rain} = derive(f)
    end

    test "a qualifying row whose code shows no precipitation still reads rain" do
      f = forecast(hours: %{12 => {60, 3}})
      assert %Reading{precip: :rain} = derive(f)
    end

    test "the 09:00 and 15:00 rows are inside the window" do
      assert %Reading{precip: :rain} = derive(forecast(hours: %{9 => {60, 61}}))
      assert %Reading{precip: :rain} = derive(forecast(hours: %{15 => {60, 61}}))
    end

    test "qualifying rows stamped 08:00 or 16:00 are ignored" do
      f = forecast(hours: %{8 => {90, 73}, 16 => {90, 73}})
      assert %Reading{precip: :none} = derive(f)
    end

    test "window rows are selected by stamped hour, not list position" do
      f = forecast(hours: %{12 => {60, 61}})
      hourly = f["hourly"]

      reversed =
        put_in(f["hourly"], Map.new(hourly, fn {k, v} -> {k, Enum.reverse(v)} end))

      assert %Reading{precip: :rain} = derive(reversed)
    end
  end

  describe "missing data" do
    test "a missing high gives nil" do
      assert derive(forecast(high: nil)) == nil
    end

    test "a missing chance in a window row gives nil" do
      f = forecast()
      f = update_in(f["hourly"]["precipitation_probability"], &List.replace_at(&1, 11, nil))
      assert derive(f) == nil
    end

    test "a missing code in a window row gives nil" do
      f = forecast()
      f = update_in(f["hourly"]["weather_code"], &List.replace_at(&1, 15, nil))
      assert derive(f) == nil
    end

    test "fewer than seven window rows gives nil" do
      f = forecast()

      f =
        update_in(f["hourly"], fn h ->
          Map.new(h, fn {k, v} -> {k, Enum.take(v, 15)} end)
        end)

      assert derive(f) == nil
    end

    test "missing nils outside the window do not matter" do
      f = forecast()
      f = update_in(f["hourly"]["weather_code"], &List.replace_at(&1, 3, nil))
      assert %Reading{} = derive(f)
    end
  end

  test "the reading's date comes from daily.time and carries only date, temp, precip" do
    reading = derive(forecast(date: "2031-01-02"))
    assert reading == %Reading{date: ~D[2031-01-02], temp: :normal, precip: :none}
  end
end
