defmodule BearCub.Chores.Chore do
  use Ecto.Schema
  import Ecto.Changeset

  @routines ~w(morning evening)

  schema "chores" do
    field :routine, :string
    field :name, :string
    field :icon, :string
    field :position, :integer
    field :points, :integer, default: 5
    # chore lifetime, in local dates so they compare cleanly against
    # completions.local_date (D80). `archived_on` nil means live.
    field :active_from, :date
    field :archived_on, :date
    # `is_recurring` in the database, `recurring?` in the schema (D82).
    # A raw fragment(...) bypasses this mapping and must spell the
    # column name — `extras_by_kid/1` already contains such a fragment.
    field :recurring?, :boolean, source: :is_recurring, default: false

    belongs_to :kid, BearCub.Chores.Kid

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(chore, attrs) do
    chore
    |> cast(attrs, [:routine, :name, :icon, :points])
    |> validate_required([:name, :icon])
    |> validate_inclusion(:routine, @routines)
    |> assoc_constraint(:kid)
  end
end
