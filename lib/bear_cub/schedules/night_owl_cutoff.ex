defmodule BearCub.Schedules.NightOwlCutoff do
  @moduledoc """
  One kid's Night Owl cutoff on one weekday: the wall-clock `Time` their
  evening must be finished before. Embedded in `DayEntry`, so it lives in
  the schedule version's `days` JSON. A cutoff submitted blank is no entry
  and is dropped rather than refused.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :kid_id, :integer
    field :cutoff, :time
  end

  def changeset(entry, attrs) do
    changeset = cast(entry, attrs, [:kid_id, :cutoff])

    if is_nil(get_field(changeset, :cutoff)) and not Keyword.has_key?(changeset.errors, :cutoff) do
      %{changeset | action: :ignore}
    else
      validate_required(changeset, [:kid_id, :cutoff])
    end
  end
end
