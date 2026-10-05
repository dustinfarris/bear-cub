defmodule BearCub.Schedules.ScheduleVersion do
  @moduledoc """
  One immutable schedule: the routine bonus `R`, the early bird bonus `E`,
  the Night Owl bonus `N` and a `DayEntry` for each ISO weekday, in force
  from `effective_at` until a later version takes over (D120). Rows are
  only ever inserted.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias BearCub.Schedules.DayEntry

  schema "schedule_versions" do
    field :effective_at, :utc_datetime
    field :routine_bonus, :integer
    field :early_bird_bonus, :integer
    field :night_owl_bonus, :integer, default: 0
    embeds_many :days, DayEntry, on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  @doc """
  The schedule's content: bonuses and the seven days. `effective_at` is
  never cast — the context stamps it at the save boundary with
  `effective_at/2`.
  """
  def changeset(version, attrs) do
    version
    |> cast(attrs, [:routine_bonus, :early_bird_bonus, :night_owl_bonus])
    |> cast_embed(:days, required: true)
    |> validate_required([:routine_bonus, :early_bird_bonus, :night_owl_bonus])
    |> validate_number(:routine_bonus, greater_than_or_equal_to: 0)
    |> validate_number(:early_bird_bonus, greater_than_or_equal_to: 0)
    |> validate_number(:night_owl_bonus, greater_than_or_equal_to: 0)
    |> validate_weekdays()
  end

  @doc "Stamps the instant this version takes over; a same-second collision is a changeset error."
  def effective_at(changeset, %DateTime{} = instant) do
    changeset
    |> put_change(:effective_at, DateTime.truncate(instant, :second))
    |> unique_constraint(:effective_at)
  end

  defp validate_weekdays(changeset) do
    days = get_field(changeset, :days) || []

    if Enum.sort(Enum.map(days, & &1.weekday)) == Enum.to_list(1..7),
      do: changeset,
      else: add_error(changeset, :days, "must have exactly one entry for each weekday 1-7")
  end
end
