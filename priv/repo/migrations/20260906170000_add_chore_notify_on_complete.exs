defmodule BearCub.Repo.Migrations.AddChoreNotifyOnComplete do
  use Ecto.Migration

  def change do
    alter table(:chores) do
      # per-chore opt-in to a parent push when it is completed. Named
      # `notify_on_complete` in the database and `notify_on_complete?`
      # in the schema, bridged by `field/3`'s `:source` (D82's pattern).
      add :notify_on_complete, :boolean, null: false, default: false
    end
  end
end
