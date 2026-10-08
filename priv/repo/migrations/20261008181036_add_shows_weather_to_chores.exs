defmodule BearCub.Repo.Migrations.AddShowsWeatherToChores do
  use Ecto.Migration

  def change do
    alter table(:chores) do
      add :shows_weather, :boolean, null: false, default: false
    end
  end
end
