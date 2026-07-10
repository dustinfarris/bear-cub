defmodule BearCub.Repo.Migrations.CreateCalendars do
  use Ecto.Migration

  def change do
    create table(:calendars) do
      # nil = family calendar, rendered in both columns (D9)
      add :kid_id, references(:kids, on_delete: :delete_all)
      add :label, :string, null: false
      add :ics_url, :string, null: false
      add :last_payload, :text
      add :last_fetched_at, :utc_datetime
      add :last_error, :string

      timestamps(type: :utc_datetime)
    end

    create index(:calendars, [:kid_id])
  end
end
