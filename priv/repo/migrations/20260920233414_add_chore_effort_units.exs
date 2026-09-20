defmodule BearCub.Repo.Migrations.AddChoreEffortUnits do
  use Ecto.Migration

  def change do
    alter table(:chores) do
      # points per unit; NULL means an ordinary flat chore. Counting is
      # legal only on extras — the changeset refuses it on a routine
      # chore, and both columns are immutable once the chore exists.
      add :unit_rate, :integer
      # ceiling on the count; NULL iff unit_rate is NULL.
      add :unit_max, :integer
    end

    alter table(:completions) do
      # NULL on every flat-chore row, 1..chore.unit_max on a counted one.
      # Named effort_count, not count, since count collides with the SQL
      # aggregate in a schema that already carries raw fragments.
      add :effort_count, :integer
    end
  end
end
