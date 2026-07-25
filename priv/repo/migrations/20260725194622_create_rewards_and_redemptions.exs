defmodule BearCub.Repo.Migrations.CreateRewardsAndRedemptions do
  use Ecto.Migration

  def change do
    create table(:rewards) do
      # nil = offered to any kid, set = offered to that kid only (D58,
      # audience only — carries no scarcity meaning).
      add :kid_id, references(:kids, on_delete: :delete_all)
      add :name, :string, null: false
      add :icon, :string, null: false
      add :points, :integer, null: false
      add :repeatable, :boolean, null: false, default: true
      add :position, :integer, null: false
      # soft archive (D68): reward rows and their redemptions are never deleted
      add :retired_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:rewards, [:kid_id])

    create table(:redemptions) do
      add :kid_id, references(:kids, on_delete: :delete_all), null: false
      add :reward_id, references(:rewards, on_delete: :delete_all), null: false
      # price snapshot taken at row creation (D60) — never re-read from rewards.points
      add :points, :integer, null: false
      add :local_date, :date, null: false
      add :requested_at, :utc_datetime
      add :approved_at, :utc_datetime
      add :declined_at, :utc_datetime
      add :reversed_at, :utc_datetime
      add :source, :string, null: false

      timestamps(type: :utc_datetime)
    end

    # One open request per kid per local day (D61). Including local_date
    # in the key is what makes lapse free: yesterday's unanswered request
    # cannot block today's, with no job and no cleanup.
    create unique_index(:redemptions, [:kid_id, :local_date],
             where: "requested_at IS NOT NULL AND approved_at IS NULL AND declined_at IS NULL",
             name: :redemptions_one_pending_per_kid
           )

    create index(:redemptions, [:reward_id])
    create index(:redemptions, [:kid_id, :local_date])
  end
end
