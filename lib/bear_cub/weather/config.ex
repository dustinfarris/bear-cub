defmodule BearCub.Weather.Config do
  @moduledoc """
  Reads and validates the weather runtime config (SC-2, D139) from
  environment variables. `config/runtime.exs` calls `from_env/1`, so bad
  values stop boot. Errors name the variable, never its value: coordinates
  are household data and are never logged.
  """

  @defaults [hot_at: 80, cold_below: 60, precip_chance_at: 40]

  @doc """
  Returns `[latitude:, longitude:, hot_at:, cold_below:, precip_chance_at:]`
  from an env map. Unset coordinates are `nil` (weather off). Raises
  `ArgumentError` on a non-numeric value, `cold_below > hot_at`, or a
  chance outside 0-100.
  """
  @spec from_env(%{optional(String.t()) => String.t()}) :: keyword()
  def from_env(env) do
    config = [
      latitude: number(env, "BEAR_CUB_WEATHER_LATITUDE", nil),
      longitude: number(env, "BEAR_CUB_WEATHER_LONGITUDE", nil),
      hot_at: number(env, "BEAR_CUB_WEATHER_HOT_AT", @defaults[:hot_at]),
      cold_below: number(env, "BEAR_CUB_WEATHER_COLD_BELOW", @defaults[:cold_below]),
      precip_chance_at:
        number(env, "BEAR_CUB_WEATHER_PRECIP_CHANCE_AT", @defaults[:precip_chance_at])
    ]

    validate!(config)
  end

  defp validate!(config) do
    if config[:cold_below] > config[:hot_at] do
      raise ArgumentError, "weather cold_below must not exceed hot_at"
    end

    unless config[:precip_chance_at] >= 0 and config[:precip_chance_at] <= 100 do
      raise ArgumentError, "weather precip_chance_at must be within 0-100"
    end

    config
  end

  defp number(env, var, default) do
    case Map.fetch(env, var) do
      :error -> default
      {:ok, raw} -> parse!(var, raw)
    end
  end

  defp parse!(var, raw) do
    case Integer.parse(raw) do
      {int, ""} -> int
      _ -> parse_float!(var, raw)
    end
  end

  defp parse_float!(var, raw) do
    case Float.parse(raw) do
      {float, ""} -> float
      _ -> raise ArgumentError, "#{var} must be a number"
    end
  end
end
