defmodule BearCub.Chores.ChoreLifecycleMigrationTest do
  # The `add_chore_lifecycle` migration and its backfill (D80, D82).
  #
  # The columns are already in place by the time this suite runs — the
  # test DB is migrated. What is still observable, and what carries the
  # risk, is the backfill: these tests put rows back into the state the
  # `ADD COLUMN` leaves them in (`active_from` at the epoch floor) and
  # run the migration's own SQL over them, so the assertions are about
  # the shipped statement rather than a paraphrase of it.
  use BearCub.DataCase

  alias BearCub.Chores
  alias BearCub.Chores.Chore
  alias BearCub.Chores.Completion
  alias BearCub.Points

  import BearCub.ChoresFixtures

  @tz "America/Los_Angeles"

  # Per `docs/learnings.org` [2026-07-17]: pin the windows rather than
  # inheriting whichever routine the real wall clock happens to land in.
  setup do
    original_windows = Application.fetch_env!(:bear_cub, :routine_windows)
    on_exit(fn -> Application.put_env(:bear_cub, :routine_windows, original_windows) end)

    Application.put_env(:bear_cub, :routine_windows,
      morning: {~T[05:00:00], ~T[17:00:00]},
      evening: {~T[17:00:00], ~T[23:00:00]}
    )

    :ok
  end

  defp la(date, time), do: DateTime.new!(date, time, @tz)

  # The migration's own backfill, loaded from the migration file itself
  # so this suite can never drift from what shipped.
  defp run_backfill do
    # resolved at runtime: the migration lives in priv/, so it is not on
    # the compile path and a literal reference would warn
    migration = Module.concat([BearCub.Repo.Migrations, :AddChoreLifecycle])

    # on a fresh database the migrator has already compiled it into this
    # VM; requiring it again would warn about redefining the module
    unless Code.ensure_loaded?(migration) do
      [path] =
        :bear_cub
        |> Application.app_dir("priv/repo/migrations")
        |> Path.join("*_add_chore_lifecycle.exs")
        |> Path.wildcard()

      Code.require_file(path)
    end

    migration.backfill(Repo)
  end

  # Puts a chore back into the state `ADD COLUMN` leaves a pre-existing
  # row in: created on `created_on` (UTC, as `timestamps/1` writes it),
  # `active_from` at the epoch floor the constant default supplies.
  defp pre_migration_chore(kid, created_on, attrs \\ %{}) do
    chore = chore_fixture(kid, attrs)

    Repo.query!(
      "UPDATE chores SET active_from = '1970-01-01', inserted_at = ?, updated_at = ? WHERE id = ?",
      [created_on, created_on, chore.id]
    )

    Repo.reload!(chore)
  end

  defp dates, do: Date.range(~D[2026-07-08], ~D[2026-07-12]) |> Enum.to_list()

  defp chores_columns do
    %{rows: rows} = Repo.query!("PRAGMA table_info(chores)")

    Map.new(rows, fn [_, name, type, notnull, default, _] -> {name, {type, notnull, default}} end)
  end

  defp complete_on(chore, local_date) do
    {:ok, completion} = Chores.complete_chore(chore, la(local_date, ~T[08:00:00]), "kiosk")
    completion
  end

  describe "backfill (D80)" do
    test "a chore never completed becomes live on the local date it was created" do
      kid = kid_fixture()
      chore = pre_migration_chore(kid, ~U[2026-07-10 15:00:00Z])

      run_backfill()

      assert Repo.reload!(chore).active_from == ~D[2026-07-10]
    end

    test "a chore completed before its created date becomes live on that earlier day" do
      kid = kid_fixture()
      chore = pre_migration_chore(kid, ~U[2026-07-10 15:00:00Z])
      complete_on(chore, ~D[2026-07-08])
      complete_on(chore, ~D[2026-07-09])

      run_backfill()

      assert Repo.reload!(chore).active_from == ~D[2026-07-08]
    end

    test "a chore completed only after its created date keeps the created date" do
      kid = kid_fixture()
      chore = pre_migration_chore(kid, ~U[2026-07-10 15:00:00Z])
      complete_on(chore, ~D[2026-07-12])

      run_backfill()

      assert Repo.reload!(chore).active_from == ~D[2026-07-10]
    end

    test "an evening-created chore completed the same local day absorbs the UTC skew" do
      # 2026-07-10 19:00 local is 2026-07-11 in UTC: DATE(inserted_at)
      # alone would place the chore live a day after it was worked.
      kid = kid_fixture()
      chore = pre_migration_chore(kid, ~U[2026-07-11 02:00:00Z])
      complete_on(chore, ~D[2026-07-10])

      run_backfill()

      assert Repo.reload!(chore).active_from == ~D[2026-07-10]
    end

    test "an evening-created chore never completed is live from its local creation day" do
      # 2026-07-10 19:00 local is 2026-07-11 in UTC. With no completion
      # to take the MIN against, only a real conversion into the
      # configured timezone recovers the day the chore was created.
      kid = kid_fixture()
      chore = pre_migration_chore(kid, ~U[2026-07-11 02:00:00Z])

      run_backfill()

      assert Repo.reload!(chore).active_from == ~D[2026-07-10]
    end

    test "a chore already carrying a stamped active_from is left alone" do
      kid = kid_fixture()
      chore = chore_fixture(kid, %{}, la(~D[2026-08-01], ~T[19:00:00]))

      run_backfill()

      assert Repo.reload!(chore).active_from == ~D[2026-08-01]
    end

    test "the local creation day is recovered across offsets, DST and inserted_at spellings" do
      kid = kid_fixture()

      cases = [
        {"pst-evening", "2026-01-16T02:00:00Z", ~D[2026-01-15]},
        {"spring-forward-pst-side", "2026-03-08T09:30:00Z", ~D[2026-03-08]},
        {"spring-forward-pdt-side", "2026-03-08T10:30:00Z", ~D[2026-03-08]},
        {"fall-back-first-0130", "2026-11-01T08:30:00Z", ~D[2026-11-01]},
        {"fall-back-repeated-0130", "2026-11-01T09:30:00Z", ~D[2026-11-01]},
        {"year-boundary", "2026-01-01T01:00:00Z", ~D[2025-12-31]},
        {"space-separated", "2026-07-11 02:00:00", ~D[2026-07-10]},
        {"microseconds", "2026-07-11T02:00:00.123456Z", ~D[2026-07-10]}
      ]

      chores =
        for {label, inserted_at, expected} <- cases do
          {label, pre_migration_chore(kid, inserted_at, %{name: label}), expected}
        end

      run_backfill()

      for {label, chore, expected} <- chores do
        assert Repo.reload!(chore).active_from == expected,
               "#{label} became live on the wrong day"
      end
    end

    test "every backfilled chore is still live and still one-off (D82)" do
      kid = kid_fixture()
      chore = pre_migration_chore(kid, ~U[2026-07-10 15:00:00Z])
      extra = pre_migration_chore(kid, ~U[2026-07-10 15:00:00Z], %{name: "Extra", routine: nil})
      complete_on(extra, ~D[2026-07-09])

      run_backfill()

      for %Chore{} = c <- [Repo.reload!(chore), Repo.reload!(extra)] do
        assert c.archived_on == nil
        assert c.recurring? == false
      end
    end

    test "no kid's derived points move when the backfill runs" do
      kid = kid_fixture()
      morning = pre_migration_chore(kid, ~U[2026-07-08 15:00:00Z], %{name: "Teeth"})

      evening =
        pre_migration_chore(kid, ~U[2026-07-08 15:00:00Z], %{name: "Pajamas", routine: "evening"})

      extra =
        pre_migration_chore(kid, ~U[2026-07-12 15:00:00Z], %{
          name: "Extra",
          routine: nil,
          points: 7
        })

      complete_on(morning, ~D[2026-07-08])
      complete_on(evening, ~D[2026-07-08])
      complete_on(morning, ~D[2026-07-09])
      complete_on(extra, ~D[2026-07-10])

      before = Enum.map(dates(), &{&1, Points.balance(kid, &1), Points.total(kid, &1)})

      run_backfill()

      assert Enum.map(dates(), &{&1, Points.balance(kid, &1), Points.total(kid, &1)}) == before
    end
  end

  describe "columns (D80, D82)" do
    test "archived_on takes a local date and is_recurring a boolean" do
      chore = chore_fixture()

      updated =
        chore
        |> Ecto.Changeset.change(archived_on: ~D[2026-07-20], recurring?: true)
        |> Repo.update!()
        |> Repo.reload!()

      assert updated.archived_on == ~D[2026-07-20]
      assert updated.recurring? == true
    end

    test "recurring? reads and writes the is_recurring column" do
      chore = chore_fixture()

      Repo.query!("UPDATE chores SET is_recurring = 1 WHERE id = ?", [chore.id])

      assert Repo.reload!(chore).recurring? == true
    end

    test "the lifecycle columns land with the declared types, nullability and defaults" do
      # a genuinely pre-lifecycle row never wrote these, so the column
      # defaults are the only thing standing behind "still live, still
      # one-off" (D80, D82) — a row inserted through the schema always
      # spells is_recurring out and so cannot pin it
      columns = chores_columns()

      assert columns["active_from"] == {"TEXT", 1, "'1970-01-01'"}
      assert columns["archived_on"] == {"TEXT", 0, nil}
      assert columns["is_recurring"] == {"INTEGER", 1, "false"}
    end

    test "no pre-existing chores column is altered" do
      columns = chores_columns()

      assert columns["routine"] == {"TEXT", 0, nil}
      assert columns["name"] == {"TEXT", 1, nil}
      assert columns["icon"] == {"TEXT", 1, nil}
      assert columns["position"] == {"INTEGER", 1, nil}
      assert columns["points"] == {"INTEGER", 1, "5"}
      assert columns["kid_id"] == {"INTEGER", 1, nil}
    end

    test "completions is untouched — same columns, same partial unique index" do
      %{rows: [[index_sql]]} =
        Repo.query!(
          "SELECT sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'completions' AND sql LIKE '%UNIQUE%'"
        )

      assert index_sql =~ "chore_id"
      assert index_sql =~ "local_date"
      assert index_sql =~ "undone_at IS NULL"

      %{rows: rows} = Repo.query!("PRAGMA table_info(completions)")
      names = Enum.map(rows, fn [_, name | _] -> name end) |> Enum.sort()

      assert names ==
               ~w(chore_id completed_at failed_at id inserted_at local_date source undone_at updated_at)

      # and a completion still round-trips through the untouched schema
      chore = chore_fixture()
      {:ok, completion} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[08:00:00]), "kiosk")

      assert %Completion{local_date: ~D[2026-07-10], undone_at: nil} = Repo.reload!(completion)
    end
  end
end
