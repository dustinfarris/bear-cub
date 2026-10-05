defmodule BearCub.Repo.Migrations.AddNightOwlBonusToScheduleVersions do
  use Ecto.Migration

  # Every existing version prices with N = 0 and, with no `night_owl_cutoffs`
  # key in its `days` JSON, loads with no cutoffs: history is untouched.
  def change do
    alter table(:schedule_versions) do
      add :night_owl_bonus, :integer, null: false, default: 0
    end
  end
end
