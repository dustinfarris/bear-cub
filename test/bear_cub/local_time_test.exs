defmodule BearCub.LocalTimeTest do
  use ExUnit.Case, async: true

  alias BearCub.LocalTime

  test "timezone/0 returns the configured zone" do
    assert LocalTime.timezone() == "America/Los_Angeles"
  end

  test "now/0 returns the current instant in the configured zone" do
    now = LocalTime.now()

    assert %DateTime{time_zone: "America/Los_Angeles"} = now
    assert abs(DateTime.diff(DateTime.utc_now(), now, :second)) < 5
  end

  test "routine windows default to the D1 edges" do
    assert Application.fetch_env!(:bear_cub, :routine_windows) == [
             morning: {~T[05:00:00], ~T[17:00:00]},
             evening: {~T[17:00:00], ~T[23:00:00]}
           ]
  end
end
