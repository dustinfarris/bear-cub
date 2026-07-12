defmodule BearCub.Repo.Migrations.RelaxChoresRoutineNullability do
  use Ecto.Migration

  # SQLite has no ALTER COLUMN — ecto_sqlite3 raises on `modify/3` — so
  # dropping NOT NULL on chores.routine is a create-new/copy-rows/drop-old/
  # rename table rebuild. The rebuild's DROP TABLE would otherwise let FK
  # enforcement (completions.chore_id, ON DELETE CASCADE) fire an implicit
  # cascade delete of every completion as it drops the parent — foreign_keys
  # must be OFF first, and that pragma is a silent no-op inside a
  # transaction, hence disabling the DDL transaction here.
  #
  # Ecto.Migration's `execute`/`create table`/`drop table` macros dispatch
  # through Ecto.Migration.Runner, a *separate* Agent process — so with the
  # DDL transaction disabled, each dispatched command is its own
  # `repo.query` and a pooled (non-Sandbox) connection can schedule it on a
  # different physical SQLite connection, letting a later statement observe
  # a stale pre-drop schema. `repo().checkout/1` only pins a connection for
  # the calling process, which the Runner's Agent is not — so every
  # statement here is issued directly via `Ecto.Adapters.SQL.query!/3` from
  # inside the checkout block instead of through the Runner macros, keeping
  # the whole rebuild on one physical connection regardless of pool size.
  @disable_ddl_transaction true

  def up do
    repo().checkout(fn ->
      run!("PRAGMA foreign_keys = OFF")

      run!("""
      CREATE TABLE "chores_new" (
        "id" INTEGER PRIMARY KEY AUTOINCREMENT,
        "kid_id" INTEGER NOT NULL CONSTRAINT "chores_kid_id_fkey" REFERENCES "kids"("id") ON DELETE CASCADE,
        "routine" TEXT,
        "name" TEXT NOT NULL,
        "icon" TEXT NOT NULL,
        "position" INTEGER NOT NULL,
        "inserted_at" TEXT NOT NULL,
        "updated_at" TEXT NOT NULL
      )
      """)

      run!("""
      INSERT INTO chores_new (id, kid_id, routine, name, icon, position, inserted_at, updated_at)
      SELECT id, kid_id, routine, name, icon, position, inserted_at, updated_at FROM chores
      """)

      run!("DROP TABLE \"chores\"")
      run!("ALTER TABLE \"chores_new\" RENAME TO \"chores\"")

      run!(
        "CREATE INDEX \"chores_kid_id_routine_position_index\" ON \"chores\" (\"kid_id\", \"routine\", \"position\")"
      )

      run!("PRAGMA foreign_key_check")
      run!("PRAGMA foreign_keys = ON")
    end)
  end

  def down do
    repo().checkout(fn ->
      run!("PRAGMA foreign_keys = OFF")

      run!("""
      CREATE TABLE "chores_old" (
        "id" INTEGER PRIMARY KEY AUTOINCREMENT,
        "kid_id" INTEGER NOT NULL CONSTRAINT "chores_kid_id_fkey" REFERENCES "kids"("id") ON DELETE CASCADE,
        "routine" TEXT NOT NULL,
        "name" TEXT NOT NULL,
        "icon" TEXT NOT NULL,
        "position" INTEGER NOT NULL,
        "inserted_at" TEXT NOT NULL,
        "updated_at" TEXT NOT NULL
      )
      """)

      run!("""
      INSERT INTO chores_old (id, kid_id, routine, name, icon, position, inserted_at, updated_at)
      SELECT id, kid_id, routine, name, icon, position, inserted_at, updated_at FROM chores
      """)

      run!("DROP TABLE \"chores\"")
      run!("ALTER TABLE \"chores_old\" RENAME TO \"chores\"")

      run!(
        "CREATE INDEX \"chores_kid_id_routine_position_index\" ON \"chores\" (\"kid_id\", \"routine\", \"position\")"
      )

      run!("PRAGMA foreign_key_check")
      run!("PRAGMA foreign_keys = ON")
    end)
  end

  defp run!(sql) do
    Ecto.Adapters.SQL.query!(repo(), sql, [])
  end
end
