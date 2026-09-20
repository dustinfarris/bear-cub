defmodule BearCub.Chores.Completion do
  use Ecto.Schema
  import Ecto.Changeset

  alias BearCub.Chores.Chore

  @sources ~w(kiosk admin)

  schema "completions" do
    field :local_date, :date
    field :completed_at, :utc_datetime
    field :undone_at, :utc_datetime
    field :failed_at, :utc_datetime
    field :source, :string
    # NULL on a flat chore's row, 1..chore.unit_max on a counted one —
    # the only new stored fact (Story 01 design): not the payout, not
    # the rate, not the max, since those re-derive from `chores`.
    field :effort_count, :integer

    belongs_to :chore, BearCub.Chores.Chore

    timestamps(type: :utc_datetime)
  end

  @doc """
  Bounds `effort_count` against `chore` (its rate/max never move once a
  chore exists, so validating live against the passed-in struct is
  always correct): required and within `1..chore.unit_max` when
  `chore.unit_rate` is set, required to be nil otherwise.
  """
  def changeset(completion, attrs, %Chore{} = chore) do
    completion
    |> cast(attrs, [:local_date, :completed_at, :undone_at, :source, :effort_count])
    |> validate_required([:local_date, :completed_at, :source])
    |> validate_inclusion(:source, @sources)
    |> validate_effort_count(chore)
    |> assoc_constraint(:chore)
    |> unique_constraint([:chore_id, :local_date],
      name: :completions_chore_id_local_date_index
    )
  end

  defp validate_effort_count(changeset, %Chore{unit_rate: nil}) do
    case get_field(changeset, :effort_count) do
      nil -> changeset
      _ -> add_error(changeset, :effort_count, "can't be set on a chore that isn't counted")
    end
  end

  defp validate_effort_count(changeset, %Chore{unit_max: max}) do
    changeset
    |> validate_required([:effort_count])
    |> validate_number(:effort_count,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: max
    )
  end
end
