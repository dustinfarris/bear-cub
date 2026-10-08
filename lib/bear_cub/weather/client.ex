defmodule BearCub.Weather.Client do
  @moduledoc """
  One Open-Meteo request for today's forecast (D138). Returns the decoded
  body or a failure kind. Coordinates ride in the URL, so errors name the
  failure (status, reason) and never the request.
  """

  @url "https://api.open-meteo.com/v1/forecast"

  @spec fetch(%{latitude: number(), longitude: number(), timezone: String.t()}) ::
          {:ok, map()} | {:error, term()}
  def fetch(%{latitude: lat, longitude: lon, timezone: timezone}) do
    params = [
      latitude: Float.round(lat * 1.0, 2),
      longitude: Float.round(lon * 1.0, 2),
      daily: "temperature_2m_max",
      hourly: "precipitation_probability,weather_code",
      temperature_unit: "fahrenheit",
      timezone: timezone,
      forecast_days: 1
    ]

    case Req.get(@url, [params: params, decode_body: false] ++ req_options()) do
      {:ok, %Req.Response{status: 200, body: body}} -> decode(body)
      {:ok, %Req.Response{status: status}} -> {:error, {:status, status}}
      {:error, exception} -> {:error, {:transport, Exception.message(exception)}}
    end
  end

  defp decode(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, %{} = forecast} -> {:ok, forecast}
      _ -> {:error, :malformed_json}
    end
  end

  # No retry: the next 30-minute tick is the retry.
  defp req_options do
    Keyword.merge(
      [receive_timeout: 10_000, retry: false],
      Application.get_env(:bear_cub, :weather_req_options, [])
    )
  end
end
