defmodule BearCub.Weather do
  @moduledoc """
  Weather indicator (D138). `derive/2` boils an Open-Meteo forecast down
  to a `BearCub.Weather.Reading`. This context must never depend on
  `BearCub.Chores` or `BearCub.Calendars`, nor they on it.
  """

  alias BearCub.Weather.Reading

  # `precipitation_probability` describes the preceding hour, so the
  # 09:00 row covers 8-9 AM and the 15:00 row 2-3 PM: together exactly
  # 8 AM-3 PM (PRD).
  @window_hours 9..15
  @snow_codes [71, 73, 75, 77, 85, 86]

  @type thresholds :: %{
          hot_at: number(),
          cold_below: number(),
          precip_chance_at: number()
        }

  @doc """
  Derives a reading from a decoded Open-Meteo forecast (string keys,
  `forecast_days=1`). Returns `nil` when the high or any window-row
  field is missing: absent, never a guess (D140).
  """
  @spec derive(map(), thresholds()) :: Reading.t() | nil
  def derive(forecast, thresholds) do
    with {:ok, date} <- date(forecast),
         {:ok, high} <- high(forecast),
         {:ok, rows} <- window_rows(forecast) do
      %Reading{
        date: date,
        temp: temp(high, thresholds),
        precip: precip(rows, thresholds.precip_chance_at)
      }
    else
      :error -> nil
    end
  end

  defp date(%{"daily" => %{"time" => [iso | _]}}) when is_binary(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp date(_), do: :error

  defp high(%{"daily" => %{"temperature_2m_max" => [high | _]}}) when is_number(high),
    do: {:ok, high}

  defp high(_), do: :error

  defp temp(high, %{hot_at: hot_at}) when high >= hot_at, do: :hot
  defp temp(high, %{cold_below: cold_below}) when high < cold_below, do: :cold
  defp temp(_high, _thresholds), do: :normal

  defp window_rows(%{"hourly" => %{"time" => times} = hourly}) do
    chances = Map.get(hourly, "precipitation_probability", [])
    codes = Map.get(hourly, "weather_code", [])

    rows =
      [times, chances, codes]
      |> Enum.zip()
      |> Enum.flat_map(fn {time, chance, code} ->
        case hour(time) do
          hour when hour in @window_hours -> [{hour, chance, code}]
          _ -> []
        end
      end)

    if length(rows) == Enum.count(@window_hours) and
         Enum.all?(rows, fn {_, chance, code} -> is_number(chance) and is_number(code) end) do
      {:ok, Enum.map(rows, fn {_, chance, code} -> {chance, code} end)}
    else
      :error
    end
  end

  defp window_rows(_), do: :error

  defp hour(<<_date::binary-size(10), "T", hh::binary-size(2), _rest::binary>>) do
    case Integer.parse(hh) do
      {hour, ""} -> hour
      _ -> nil
    end
  end

  defp hour(_), do: nil

  # The chance gates; the code only types (D140).
  defp precip(rows, chance_at) do
    case Enum.filter(rows, fn {chance, _code} -> chance >= chance_at end) do
      [] -> :none
      kept -> if Enum.any?(kept, fn {_, code} -> code in @snow_codes end), do: :snow, else: :rain
    end
  end
end
