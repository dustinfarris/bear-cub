defmodule BearCub.Chores.Chore do
  use Ecto.Schema
  import Ecto.Changeset

  @routines ~w(morning evening)

  schema "chores" do
    field :routine, :string
    field :name, :string
    field :icon, :string
    field :position, :integer

    belongs_to :kid, BearCub.Chores.Kid

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(chore, attrs) do
    chore
    |> cast(attrs, [:routine, :name, :icon, :position])
    |> validate_required([:routine, :name, :icon, :position])
    |> validate_inclusion(:routine, @routines)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> assoc_constraint(:kid)
  end
end
