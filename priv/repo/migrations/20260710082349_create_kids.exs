defmodule BearCub.Repo.Migrations.CreateKids do
  use Ecto.Migration

  def change do
    create table(:kids) do
      add :name, :string, null: false
      add :color, :string, null: false
      add :position, :integer, null: false

      timestamps(type: :utc_datetime)
    end
  end
end
