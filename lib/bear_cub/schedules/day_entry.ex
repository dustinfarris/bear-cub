defmodule BearCub.Schedules.DayEntry do
  @moduledoc """
  One weekday's timings inside a schedule version: the morning and evening
  windows and the early bird cutoff, all wall-clock `Time`s. Embedded as
  JSON in `schedule_versions.days`, so a single changeset validates the
  whole schedule.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :weekday, :integer
    field :morning_start, :time
    field :morning_end, :time
    field :evening_start, :time
    field :evening_end, :time
    field :early_bird_cutoff, :time
  end

  @fields [
    :weekday,
    :morning_start,
    :morning_end,
    :evening_start,
    :evening_end,
    :early_bird_cutoff
  ]

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> validate_inclusion(:weekday, 1..7)
    |> validate_window(:morning_start, :morning_end)
    |> validate_window(:evening_start, :evening_end)
    |> validate_morning_before_evening()
    |> validate_cutoff_inside_morning()
  end

  # No window spans midnight, so start must be strictly before end.
  defp validate_window(changeset, start_field, end_field) do
    with_times(changeset, [start_field, end_field], fn [starts, ends] ->
      if Time.compare(starts, ends) == :lt,
        do: changeset,
        else: add_error(changeset, end_field, "must be after the start")
    end)
  end

  defp validate_morning_before_evening(changeset) do
    with_times(changeset, [:morning_end, :evening_start], fn [morning_end, evening_start] ->
      if Time.compare(morning_end, evening_start) == :gt,
        do: add_error(changeset, :evening_start, "must not be before the morning ends"),
        else: changeset
    end)
  end

  defp validate_cutoff_inside_morning(changeset) do
    with_times(changeset, [:morning_start, :morning_end, :early_bird_cutoff], fn
      [starts, ends, cutoff] ->
        if Time.compare(cutoff, starts) == :gt and Time.compare(cutoff, ends) == :lt,
          do: changeset,
          else: add_error(changeset, :early_bird_cutoff, "must fall inside the morning window")
    end)
  end

  # Cross-field rules only run once every field they compare is present.
  defp with_times(changeset, fields, fun) do
    values = Enum.map(fields, &get_field(changeset, &1))
    if Enum.all?(values), do: fun.(values), else: changeset
  end
end
