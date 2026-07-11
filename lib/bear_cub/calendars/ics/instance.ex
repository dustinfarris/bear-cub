defmodule BearCub.Calendars.ICS.Instance do
  @moduledoc "A single concrete calendar event occurrence."
  defstruct [:uid, :summary, :location, :starts_at, :ends_at, :all_day]
end
