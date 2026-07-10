defmodule BearCub.LocalTime do
  @moduledoc """
  The one place "now" enters the system.

  Domain code never reads the clock — every time-dependent function takes
  a local `%DateTime{}` argument (design §3), so edge cases test with
  plain values. Only the web layer (and future periodic processes) calls
  `now/0`.
  """

  def timezone, do: Application.fetch_env!(:bear_cub, :timezone)

  def now, do: DateTime.now!(timezone())
end
