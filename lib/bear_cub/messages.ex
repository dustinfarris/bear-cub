defmodule BearCub.Messages do
  @moduledoc """
  Static kiosk copy, changed in code — no schema, no config ceremony
  (mirrors how routine windows are app constants). Good Night mode
  renders `good_night/0`, never `evening_complete/0`: the two are
  distinct states with distinct copy (D37, D38).
  """

  @doc "The morning-routine-complete affirmation."
  def morning_complete, do: "Today is going to be a wonderful day"

  @doc "The evening-routine-complete affirmation."
  def evening_complete, do: "You did great today!"

  @doc "The post-23:00 Good Night lockdown line."
  def good_night, do: "Good night"
end
