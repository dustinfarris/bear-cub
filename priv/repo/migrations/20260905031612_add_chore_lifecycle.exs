defmodule BearCub.Repo.Migrations.AddChoreLifecycle do
  use Ecto.Migration

  @epoch_floor "1970-01-01"

  def up do
    alter table(:chores) do
      # extras only: comes back every day instead of retiring after one
      # completion (D82). Named `is_recurring` in the database and
      # `recurring?` in the schema, bridged by `field/3`'s `:source`.
      add :is_recurring, :boolean, null: false, default: false
      # local date the chore was archived; nil means live. One-way (D80)
      add :archived_on, :date
      # SQLite can add a NOT NULL column only with a constant default, so
      # this arrives as an epoch floor — the conservative direction,
      # since "live since forever" can only grow a historical roster,
      # never shrink one. `backfill/1` below replaces it with the truth.
      add :active_from, :date, null: false, default: @epoch_floor
    end

    flush()

    backfill(repo())
  end

  def down do
    alter table(:chores) do
      remove :is_recurring
      remove :archived_on
      remove :active_from
    end
  end

  @doc """
  Stamps each pre-lifecycle chore with the earliest of the local date it
  was created and the earliest local date it was ever completed on (D80).

  The MIN is load-bearing: an `active_from` landing after a day the chore
  was already being completed would shrink that day's historical roster
  and hand out a +R nobody earned.

  `inserted_at` is UTC, so the created half is converted into the
  configured timezone per row rather than truncated with SQLite's
  `DATE()` — an evening-created chore's UTC date is the *following* day,
  and for one never completed there is no earlier completion for the MIN
  to rescue it with. Only rows still sitting at the epoch floor are
  touched, so re-running this leaves alone every date
  `Chores.create_chore/3` has stamped since — the floor doubles as the
  "not yet backfilled" sentinel, which holds because no caller passes an
  epoch-dated local datetime.

  Public, and taking its repo, so the migration test can run the shipped
  backfill rather than a paraphrase of it.
  """
  def backfill(repo) do
    # a migration runs with the app unstarted, so the configured time
    # zone database has to be brought up before any conversion — without
    # this, shift_zone!/2 raises :time_zone_not_found
    {:ok, _} = Application.ensure_all_started(:tzdata)

    timezone = BearCub.LocalTime.timezone()

    # strftime normalizes whatever spelling of the timestamp is on disk
    %{rows: rows} =
      repo.query!(
        """
        SELECT c.id,
               strftime('%Y-%m-%dT%H:%M:%SZ', c.inserted_at),
               (SELECT MIN(local_date) FROM completions WHERE chore_id = c.id)
          FROM chores c
         WHERE c.active_from = ?
        """,
        [@epoch_floor]
      )

    for [id, inserted_at, first_completed_on] <- rows do
      active_from =
        inserted_at
        |> local_date_of(timezone)
        |> earlier_of(first_completed_on)

      repo.query!("UPDATE chores SET active_from = ? WHERE id = ?", [
        Date.to_iso8601(active_from),
        id
      ])
    end
  end

  defp local_date_of(utc_iso8601, timezone) do
    {:ok, utc, 0} = DateTime.from_iso8601(utc_iso8601)

    utc |> DateTime.shift_zone!(timezone) |> DateTime.to_date()
  end

  defp earlier_of(created_on, nil), do: created_on

  defp earlier_of(created_on, first_completed_on) do
    Enum.min([created_on, Date.from_iso8601!(first_completed_on)], Date)
  end
end
