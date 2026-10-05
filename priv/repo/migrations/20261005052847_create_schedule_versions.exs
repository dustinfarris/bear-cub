defmodule BearCub.Repo.Migrations.CreateScheduleVersions do
  use Ecto.Migration

  def up do
    create table(:schedule_versions) do
      add :effective_at, :utc_datetime, null: false
      add :routine_bonus, :integer, null: false
      add :early_bird_bonus, :integer, null: false
      # Exactly seven entries, one per ISO weekday; validated by the
      # ScheduleVersion changeset, never by the database.
      add :days, :map, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:schedule_versions, [:effective_at])

    # DDL is queued until the migration finishes; the insert needs the table now.
    flush()

    # Version 0 (SC-5): production's actual values, in force from the epoch
    # so every historical term prices exactly as it does today. Written on
    # the table name with plain maps — never through the schema module — so
    # a later schema change cannot break this migration on a fresh database.
    day = fn weekday ->
      %{
        "weekday" => weekday,
        "morning_start" => "05:00:00",
        "morning_end" => "17:00:00",
        "evening_start" => "17:00:00",
        "evening_end" => "23:00:00",
        "early_bird_cutoff" => "07:45:00"
      }
    end

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    repo().insert_all("schedule_versions", [
      %{
        effective_at: ~U[1970-01-01 00:00:00Z],
        routine_bonus: 5,
        early_bird_bonus: 2,
        # schemaless insert_all has no type to encode a list: hand it JSON text
        days: Jason.encode!(Enum.map(1..7, day)),
        inserted_at: now,
        updated_at: now
      }
    ])
  end

  def down do
    drop table(:schedule_versions)
  end
end
