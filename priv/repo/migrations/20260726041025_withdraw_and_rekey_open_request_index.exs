defmodule BearCub.Repo.Migrations.WithdrawAndRekeyOpenRequestIndex do
  use Ecto.Migration

  def change do
    alter table(:redemptions) do
      # the kid-side withdraw marker (D76) — the undone_at/failed_at/
      # declined_at pattern, never a row deletion
      add :withdrawn_at, :utc_datetime
    end

    # D61's one-open-request-per-kid-per-day index is superseded (D77): a
    # kid may hold several pending requests at once, so the index must
    # only ever forbid a *duplicate* ask for the *same* reward on the same
    # day. SQLite cannot alter an index in place — drop and recreate.
    drop index(:redemptions, [:kid_id, :local_date], name: :redemptions_one_pending_per_kid)

    create unique_index(:redemptions, [:kid_id, :reward_id, :local_date],
             where: """
             requested_at IS NOT NULL AND approved_at IS NULL AND declined_at IS NULL
               AND withdrawn_at IS NULL
             """,
             name: :redemptions_one_open_per_kid_reward
           )
  end
end
