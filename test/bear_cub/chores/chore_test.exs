defmodule BearCub.Chores.ChoreTest do
  use BearCub.DataCase

  import BearCub.ChoresFixtures

  alias BearCub.Chores

  describe "shows_weather" do
    setup do
      %{kid: kid_fixture(%{name: "Kid A", color: "#f59e0b", position: 0})}
    end

    test "casts on a morning chore", %{kid: kid} do
      chore = chore_fixture(kid, %{shows_in: "morning", shows_weather: true})

      assert chore.shows_weather == true
    end

    test "defaults to false", %{kid: kid} do
      assert chore_fixture(kid, %{}).shows_weather == false
    end

    test "is cleared, without an error, on a move to evening", %{kid: kid} do
      chore = chore_fixture(kid, %{shows_in: "morning", shows_weather: true})

      assert {:ok, moved} = Chores.update_chore(chore, %{shows_in: "evening"})
      assert moved.shows_weather == false
    end

    test "is cleared on a move to extras", %{kid: kid} do
      chore = chore_fixture(kid, %{shows_in: "morning", shows_weather: true})

      assert {:ok, moved} = Chores.update_chore(chore, %{shows_in: "extra"})
      assert moved.shows_weather == false
    end

    test "is cleared when set on an evening chore", %{kid: kid} do
      chore = chore_fixture(kid, %{routine: "evening", shows_weather: true})

      assert chore.shows_weather == false
    end

    test "is cleared when set on an extra", %{kid: kid} do
      chore = chore_fixture(kid, %{routine: nil, shows_weather: true})

      assert chore.shows_weather == false
    end

    test "can be set and cleared on a chore with completions without changing points",
         %{kid: kid} do
      chore = chore_fixture(kid, %{shows_in: "morning"})
      now = BearCub.LocalTime.now()
      {:ok, _} = Chores.complete_chore(chore, now, "admin")
      today = DateTime.to_date(now)
      before = BearCub.Points.total(kid, today)

      assert {:ok, flagged} = Chores.update_chore(chore, %{shows_weather: true})
      assert flagged.shows_weather == true
      assert BearCub.Points.total(kid, today) == before

      assert {:ok, cleared} = Chores.update_chore(flagged, %{shows_weather: false})
      assert cleared.shows_weather == false
      assert BearCub.Points.total(kid, today) == before
    end
  end
end
