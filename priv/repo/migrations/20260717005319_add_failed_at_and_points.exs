defmodule BearCub.Repo.Migrations.AddFailedAtAndPoints do
  use Ecto.Migration

  def change do
    alter table(:chores) do
      add :points, :integer, null: false, default: 5
    end

    alter table(:completions) do
      add :failed_at, :utc_datetime
    end
  end
end
