defmodule BearCub.Repo.Migrations.CreateChores do
  use Ecto.Migration

  def change do
    create table(:chores) do
      add :kid_id, references(:kids, on_delete: :delete_all), null: false
      add :routine, :string, null: false
      add :name, :string, null: false
      add :icon, :string, null: false
      add :position, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:chores, [:kid_id, :routine, :position])
  end
end
