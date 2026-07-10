defmodule BearCub.Chores.Kid do
  use Ecto.Schema
  import Ecto.Changeset

  schema "kids" do
    field :name, :string
    field :color, :string
    field :position, :integer

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(kid, attrs) do
    kid
    |> cast(attrs, [:name, :color, :position])
    |> validate_required([:name, :color, :position])
    |> validate_format(:color, ~r/^#[0-9a-fA-F]{6}$/, message: "must be a hex color like #f59e0b")
    |> validate_number(:position, greater_than_or_equal_to: 0)
  end
end
