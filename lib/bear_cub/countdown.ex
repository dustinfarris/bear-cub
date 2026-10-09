defmodule BearCub.Countdown do
  @moduledoc """
  The bonus countdown's state, as a pure function of a cutoff and "now".

  No clock, no config, no database: `local_now`, the lead time and the
  seconds switch all arrive as arguments. Every edge is measured back from
  the cutoff, so ticks never drift.

  Above `switch_ms` the countdown is in `:minutes` mode (whole minutes,
  draining over `lead_ms`); at or below it, `:seconds` mode (`m:ss`,
  draining over `switch_ms`). At the cutoff the state is `nil` — the
  strict verdict test (D133) means a tap during the last second still
  earns, and from the cutoff on there is nothing to show.
  """

  @type state :: %{
          mode: :minutes | :seconds,
          remaining_ms: pos_integer(),
          fraction: float()
        }

  @spec state(DateTime.t() | nil, boolean(), DateTime.t(), pos_integer(), pos_integer()) ::
          nil | state()
  def state(nil, _eligible?, _local_now, _lead_ms, _switch_ms), do: nil
  def state(_cutoff, false, _local_now, _lead_ms, _switch_ms), do: nil

  def state(cutoff, true, local_now, lead_ms, switch_ms) do
    remaining = DateTime.diff(cutoff, local_now, :millisecond)

    cond do
      remaining <= 0 or remaining > lead_ms ->
        nil

      remaining <= switch_ms ->
        %{mode: :seconds, remaining_ms: remaining, fraction: remaining / switch_ms}

      true ->
        %{mode: :minutes, remaining_ms: remaining, fraction: remaining / lead_ms}
    end
  end

  @doc """
  The text of the countdown: whole minutes (`"30"`..`"5"`, never `"0"`) in
  minutes mode, `m:ss` (`"5:00"`..`"0:01"`, never `"0:00"`) in seconds mode.
  """
  @spec display(state()) :: String.t()
  def display(%{mode: :minutes, remaining_ms: ms}) do
    ms |> div(1000) |> div(60) |> Integer.to_string()
  end

  def display(%{mode: :seconds, remaining_ms: ms}) do
    seconds = div(ms + 999, 1000)

    "#{div(seconds, 60)}:#{seconds |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  @doc """
  The next instant the display changes, or `nil` once the cutoff has
  passed: the appearance (`cutoff - lead`), each whole minute, the switch,
  each whole second, and the cutoff itself.
  """
  @spec next_edge(DateTime.t() | nil, DateTime.t(), pos_integer(), pos_integer()) ::
          DateTime.t() | nil
  def next_edge(nil, _local_now, _lead_ms, _switch_ms), do: nil

  def next_edge(cutoff, local_now, lead_ms, switch_ms) do
    remaining = DateTime.diff(cutoff, local_now, :millisecond)

    target =
      cond do
        remaining <= 0 -> nil
        remaining > lead_ms -> lead_ms
        remaining > switch_ms -> max(previous_multiple(remaining, 60_000), switch_ms)
        true -> previous_multiple(remaining, 1000)
      end

    target && DateTime.add(cutoff, -target, :millisecond)
  end

  @doc """
  Reads `[lead_minutes:, seconds_minutes:]` from an env map (defaults 30 and
  5) and validates it, for `config/runtime.exs`. Raises `ArgumentError` on
  a non-integer value, so the app refuses to start rather than falling back.
  """
  @spec config_from_env(%{optional(String.t()) => String.t()}) :: keyword()
  def config_from_env(env) do
    validate_config!(
      lead_minutes: minutes!(env, "BEAR_CUB_COUNTDOWN_LEAD_MINUTES", 30),
      seconds_minutes: minutes!(env, "BEAR_CUB_COUNTDOWN_SECONDS_MINUTES", 5)
    )
  end

  @doc """
  Checks the countdown config: both values positive integers, and the lead
  strictly greater than the seconds switch. Returns the config or raises
  `ArgumentError`.
  """
  @spec validate_config!(keyword()) :: keyword()
  def validate_config!(config) do
    lead = config[:lead_minutes]
    switch = config[:seconds_minutes]

    for {key, value} <- [lead_minutes: lead, seconds_minutes: switch],
        not (is_integer(value) and value > 0) do
      raise ArgumentError, "countdown #{key} must be a positive integer"
    end

    if switch >= lead do
      raise ArgumentError, "countdown seconds_minutes must be less than lead_minutes"
    end

    config
  end

  defp minutes!(env, var, default) do
    case Map.fetch(env, var) do
      :error ->
        default

      {:ok, raw} ->
        case Integer.parse(raw) do
          {int, ""} -> int
          _ -> raise ArgumentError, "#{var} must be a whole number"
        end
    end
  end

  # The largest multiple of `step` strictly below `remaining`.
  defp previous_multiple(remaining, step), do: div(remaining - 1, step) * step
end
