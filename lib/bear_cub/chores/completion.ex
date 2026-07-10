defmodule BearCub.Chores.Completion do
  use Ecto.Schema
  import Ecto.Changeset

  @sources ~w(kiosk admin)

  schema "completions" do
    field :local_date, :date
    field :completed_at, :utc_datetime
    field :undone_at, :utc_datetime
    field :source, :string

    belongs_to :chore, BearCub.Chores.Chore

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(completion, attrs) do
    completion
    |> cast(attrs, [:local_date, :completed_at, :undone_at, :source])
    |> validate_required([:local_date, :completed_at, :source])
    |> validate_inclusion(:source, @sources)
    |> assoc_constraint(:chore)
    |> unique_constraint([:chore_id, :local_date],
      name: :completions_chore_id_local_date_index
    )
  end
end
