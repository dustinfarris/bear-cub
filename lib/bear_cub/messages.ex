defmodule BearCub.Messages do
  @moduledoc """
  Static kiosk copy, changed in code — no schema, no config ceremony
  (mirrors how routine windows are app constants). The night screen
  (D56) carries no copy at all, so `evening_complete/0` is the only
  end-of-day line (the D37/D38 `good_night/0` message retired with it).
  """

  @doc "The morning-routine-complete affirmation."
  def morning_complete, do: "Today is going to be a wonderful day"

  @doc "The evening-routine-complete affirmation."
  def evening_complete, do: "You did great today!"
end
