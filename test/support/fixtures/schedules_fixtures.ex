defmodule BearCub.SchedulesFixtures do
  @moduledoc """
  Test helpers for `BearCub.Schedules`. Domain tests pin every version to
  a fixed instant, so `version_fixture/2` inserts straight through
  `Repo.insert!/1` at a hand-chosen `effective_at` rather than through the
  context's "now"-stamped `change/1`.
  """

  alias BearCub.Repo
  alias BearCub.Schedules.ScheduleVersion

  @doc "One day entry (atom keys) with version 0's timings, overridable."
  def day_attrs(weekday, overrides \\ %{}) do
    Map.merge(
      %{
        weekday: weekday,
        morning_start: ~T[05:00:00],
        morning_end: ~T[17:00:00],
        evening_start: ~T[17:00:00],
        evening_end: ~T[23:00:00],
        early_bird_cutoff: ~T[07:45:00]
      },
      overrides
    )
  end

  @doc "Valid `Schedules.change/1` attrs: all seven days, R = 5, E = 2 unless overridden."
  def valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{routine_bonus: 5, early_bird_bonus: 2, days: Enum.map(1..7, &day_attrs/1)},
      overrides
    )
  end

  @doc "A copy of `valid_attrs/1` with `weekday`'s entry replaced by overrides."
  def attrs_with_day(weekday, day_overrides, overrides \\ %{}) do
    days =
      Enum.map(1..7, &if(&1 == weekday, do: day_attrs(&1, day_overrides), else: day_attrs(&1)))

    valid_attrs(Map.put(overrides, :days, days))
  end

  @doc "Inserts a version in force from `effective_at` (a fixed instant)."
  def version_fixture(effective_at, overrides \\ %{}) do
    %ScheduleVersion{}
    |> ScheduleVersion.changeset(valid_attrs(overrides))
    |> ScheduleVersion.effective_at(effective_at)
    |> Repo.insert!()
  end
end
