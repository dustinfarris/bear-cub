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
