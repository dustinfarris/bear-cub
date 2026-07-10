defmodule BearCub.Repo.Migrations.CreateCompletions do
  use Ecto.Migration

  def change do
    create table(:completions) do
      add :chore_id, references(:chores, on_delete: :delete_all), null: false
      add :local_date, :date, null: false
      add :completed_at, :utc_datetime, null: false
      add :undone_at, :utc_datetime
      add :source, :string, null: false

      timestamps(type: :utc_datetime)
    end

    # At most one *current* completion per chore per day (design §1):
    # double-taps cannot double-complete. Undone rows fall out of the
    # index, so tap-again inserts a fresh row (FR-8 AC).
    create unique_index(:completions, [:chore_id, :local_date], where: "undone_at IS NULL")
    create index(:completions, [:chore_id])
  end
end
