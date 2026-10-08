defmodule BearCub.Weather.Reading do
  @moduledoc """
  The day's weather as the kiosk may show it (D138): a temperature band
  and a precipitation type, no degrees and no percentages, so the kiosk
  structurally cannot display more than the PRD allows.
  """

  @enforce_keys [:date, :temp, :precip]
  defstruct [:date, :temp, :precip]

  @type t :: %__MODULE__{
          date: Date.t(),
          temp: :hot | :normal | :cold,
          precip: :none | :rain | :snow
        }
end
