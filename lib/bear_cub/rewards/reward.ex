defmodule BearCub.Rewards.Reward do
  use Ecto.Schema
  import Ecto.Changeset

  schema "rewards" do
    field :name, :string
    field :icon, :string
    field :points, :integer
    field :repeatable, :boolean, default: true
    field :position, :integer
    field :retired_at, :utc_datetime

    belongs_to :kid, BearCub.Chores.Kid

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(reward, attrs) do
    reward
    |> cast(attrs, [:name, :icon, :points, :repeatable])
    |> validate_required([:name, :icon, :points, :repeatable])
    |> assoc_constraint(:kid)
  end
end
