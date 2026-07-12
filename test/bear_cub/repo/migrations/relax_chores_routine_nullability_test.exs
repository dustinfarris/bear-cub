defmodule BearCub.Repo.Migrations.RelaxChoresRoutineNullabilityTest do
  @moduledoc """
  Runs the real migration files against a scratch SQLite database to
  prove the `chores` table rebuild (create-new/copy-rows/drop-old/rename)
  preserves `completions` history through the `chores.routine` FK — the
  concern the story's AC3 calls out (NOT NULL relaxation on SQLite is not
  an in-place ALTER).
  """
  use ExUnit.Case, async: true

  alias BearCub.MigrationTestRepo, as: Repo

  @migrations_path Application.app_dir(:bear_cub, "priv/repo/migrations")
  @migration_version 20_260_712_180_527

  setup do
    db_path =
      Path.join(
        System.tmp_dir!(),
        "bear_cub_migration_test_#{System.unique_integer([:positive])}.db"
      )

    on_exit(fn -> File.rm(db_path) end)

    start_supervised!({Repo, database: db_path})

    :ok
  end

  # Runs at the default (multi-connection) pool size on purpose: the
  # migration's DDL runs outside a wrapping transaction (needed so the
  # `PRAGMA foreign_keys = OFF` isn't a no-op), which without pinning a
  # single connection risks a later statement in the rebuild observing a
  # stale pre-drop schema on a different pooled connection.
  test "completion history survives the chores.routine nullability rebuild (AC3)" do
    Ecto.Migrator.run(Repo, @migrations_path, :up, to_exclusive: @migration_version, log: false)

    Ecto.Adapters.SQL.query!(
      Repo,
      "INSERT INTO kids (name, color, position, inserted_at, updated_at) VALUES ('Kid', '#f59e0b', 0, datetime('now'), datetime('now'))"
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      "INSERT INTO chores (kid_id, routine, name, icon, position, inserted_at, updated_at) VALUES (1, 'morning', 'Brush Teeth', '🪥', 0, datetime('now'), datetime('now'))"
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      "INSERT INTO completions (chore_id, local_date, completed_at, source, inserted_at, updated_at) VALUES (1, '2026-07-12', datetime('now'), 'kiosk', datetime('now'), datetime('now'))"
    )

    Ecto.Migrator.run(Repo, @migrations_path, :up, all: true, log: false)

    assert %{rows: [[1]]} =
             Ecto.Adapters.SQL.query!(Repo, "SELECT chore_id FROM completions WHERE id = 1")

    assert {:error, %Exqlite.Error{message: message}} =
             Ecto.Adapters.SQL.query(
               Repo,
               "INSERT INTO completions (chore_id, local_date, completed_at, source, inserted_at, updated_at) VALUES (999999, '2026-07-12', datetime('now'), 'kiosk', datetime('now'), datetime('now'))"
             )

    assert message =~ "FOREIGN KEY constraint failed"

    assert {:ok, _} =
             Ecto.Adapters.SQL.query(
               Repo,
               "INSERT INTO chores (kid_id, routine, name, icon, position, inserted_at, updated_at) VALUES (1, NULL, 'Wash Car', '🚗', 0, datetime('now'), datetime('now'))"
             )
  end
end
