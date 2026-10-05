defmodule BearCub.Schedules.DayEntry do
  @moduledoc """
  One weekday's timings inside a schedule version: the morning and evening
  windows, the early bird cutoff and each kid's Night Owl cutoff, all
  wall-clock `Time`s. Embedded as JSON in `schedule_versions.days`, so a
  single changeset validates the whole schedule.
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
    embeds_many :night_owl_cutoffs, BearCub.Schedules.NightOwlCutoff, on_replace: :delete
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
    |> cast_embed(:night_owl_cutoffs)
    |> validate_required(@fields)
    |> validate_inclusion(:weekday, 1..7)
    |> validate_window(:morning_start, :morning_end)
    |> validate_window(:evening_start, :evening_end)
    |> validate_morning_before_evening()
    |> validate_cutoff_inside_morning()
    |> validate_night_owl_cutoffs()
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

  # Each cutoff strictly inside this day's evening window, one per kid. The
  # errors land on the nested entries so the form can show them per kid.
  defp validate_night_owl_cutoffs(changeset) do
    with_times(changeset, [:evening_start, :evening_end], fn [starts, ends] ->
      {entries, _seen} =
        changeset
        |> get_embed(:night_owl_cutoffs, :changeset)
        |> Enum.map_reduce(MapSet.new(), fn entry, seen ->
          kid_id = get_field(entry, :kid_id)

          entry
          |> check_inside(starts, ends)
          |> check_unseen(kid_id, seen)
          |> then(&{&1, MapSet.put(seen, kid_id)})
        end)

      put_embed(changeset, :night_owl_cutoffs, entries)
    end)
  end

  # A cutoff that failed to cast already carries its own error.
  defp check_inside(entry, starts, ends) do
    case get_field(entry, :cutoff) do
      nil ->
        entry

      cutoff ->
        if Time.compare(cutoff, starts) == :gt and Time.compare(cutoff, ends) == :lt,
          do: entry,
          else: add_error(entry, :cutoff, "must fall inside the evening window")
    end
  end

  defp check_unseen(entry, kid_id, seen) do
    if MapSet.member?(seen, kid_id),
      do: add_error(entry, :kid_id, "already has a cutoff on this day"),
      else: entry
  end

  # Cross-field rules only run once every field they compare is present.
  defp with_times(changeset, fields, fun) do
    values = Enum.map(fields, &get_field(changeset, &1))
    if Enum.all?(values), do: fun.(values), else: changeset
  end
end
