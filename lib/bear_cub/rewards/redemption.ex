defmodule BearCub.Rewards.Redemption do
  use Ecto.Schema
  import Ecto.Changeset

  @sources ~w(kiosk admin)

  schema "redemptions" do
    field :points, :integer
    field :local_date, :date
    field :requested_at, :utc_datetime
    field :approved_at, :utc_datetime
    field :declined_at, :utc_datetime
    field :reversed_at, :utc_datetime
    field :source, :string

    belongs_to :kid, BearCub.Chores.Kid
    belongs_to :reward, BearCub.Rewards.Reward

    timestamps(type: :utc_datetime)
  end

  @doc """
  The row-creation changeset — the kid leg sets `requested_at`, the
  parent-direct leg sets `approved_at` (D60); `declined_at`/`reversed_at`
  are never cast here, matching `Completion`'s `undone_at`/`failed_at`
  treatment — those markers are stamped directly by the write paths that
  own them.
  """
  def changeset(redemption, attrs) do
    redemption
    |> cast(attrs, [:points, :local_date, :requested_at, :approved_at, :source])
    |> validate_required([:points, :local_date, :source])
    |> validate_inclusion(:source, @sources)
    |> assoc_constraint(:kid)
    |> assoc_constraint(:reward)
    # SQLite's own UNIQUE-violation message carries only the column list,
    # never the real index name (`redemptions_one_pending_per_kid`) —
    # ecto_sqlite3's `to_constraints/2` always resynthesizes the ecto
    # naming-convention name from those columns to match against, so the
    # constraint name here must equal that convention rather than the
    # migration's DDL name (the same shape `Completion`'s own
    # `unique_constraint/2` already relies on).
    |> unique_constraint([:kid_id, :local_date], name: :redemptions_kid_id_local_date_index)
  end
end
