defmodule BearCub.Chores.StandingTest do
  use BearCub.DataCase

  import BearCub.ChoresFixtures

  alias BearCub.Chores
  alias BearCub.Chores.Completion

  @tz "America/Los_Angeles"

  defp la(date, time), do: DateTime.new!(date, time, @tz)

  defp fail_completion(%Completion{} = completion, at) do
    completion
    |> Ecto.Changeset.change(undone_at: at, failed_at: at)
    |> Repo.update!()
  end

  defp stamp(chore, attrs), do: chore |> Ecto.Changeset.change(attrs) |> Repo.update!()

  describe "standing/2 (Story 02, D91, D92, D94)" do
    test "both halves clean is standing" do
      kid = kid_fixture()
      morning = chore_fixture(kid, %{name: "Brush", routine: "morning"})
      evening = chore_fixture(kid, %{name: "Bath", routine: "evening"})

      {:ok, _} = Chores.complete_chore(evening, la(~D[2026-09-04], ~T[19:00:00]), "kiosk")
      {:ok, _} = Chores.complete_chore(morning, la(~D[2026-09-05], ~T[07:00:00]), "kiosk")

      assert %{
               standing?: true,
               morning: %{empty?: false, complete?: true, failed?: false},
               evening: %{empty?: false, complete?: true, failed?: false}
             } = Chores.standing(kid, ~D[2026-09-05])
    end

    test "morning incomplete denies standing" do
      kid = kid_fixture()
      _morning = chore_fixture(kid, %{name: "Brush", routine: "morning"})
      evening = chore_fixture(kid, %{name: "Bath", routine: "evening"})

      {:ok, _} = Chores.complete_chore(evening, la(~D[2026-09-04], ~T[19:00:00]), "kiosk")

      result = Chores.standing(kid, ~D[2026-09-05])
      assert result.standing? == false
      assert %{empty?: false, complete?: false, failed?: false} = result.morning
    end

    test "last night incomplete denies standing" do
      kid = kid_fixture()
      morning = chore_fixture(kid, %{name: "Brush", routine: "morning"})
      _evening = chore_fixture(kid, %{name: "Bath", routine: "evening"})

      {:ok, _} = Chores.complete_chore(morning, la(~D[2026-09-05], ~T[07:00:00]), "kiosk")

      result = Chores.standing(kid, ~D[2026-09-05])
      assert result.standing? == false
      assert %{empty?: false, complete?: false, failed?: false} = result.evening
    end

    test "morning failed-then-redone denies standing" do
      kid = kid_fixture()
      morning = chore_fixture(kid, %{name: "Brush", routine: "morning"})
      evening = chore_fixture(kid, %{name: "Bath", routine: "evening"})

      {:ok, _} = Chores.complete_chore(evening, la(~D[2026-09-04], ~T[19:00:00]), "kiosk")

      {:ok, cm} = Chores.complete_chore(morning, la(~D[2026-09-05], ~T[07:00:00]), "kiosk")
      fail_completion(cm, ~U[2026-09-05 15:00:00Z])
      {:ok, _redo} = Chores.complete_chore(morning, la(~D[2026-09-05], ~T[08:00:00]), "kiosk")

      result = Chores.standing(kid, ~D[2026-09-05])
      assert result.standing? == false
      assert %{empty?: false, complete?: true, failed?: true} = result.morning
    end

    test "last night failed-then-redone denies standing" do
      kid = kid_fixture()
      morning = chore_fixture(kid, %{name: "Brush", routine: "morning"})
      evening = chore_fixture(kid, %{name: "Bath", routine: "evening"})

      {:ok, ce} = Chores.complete_chore(evening, la(~D[2026-09-04], ~T[19:00:00]), "kiosk")
      fail_completion(ce, ~U[2026-09-04 23:00:00Z])
      {:ok, _redo} = Chores.complete_chore(evening, la(~D[2026-09-04], ~T[20:00:00]), "kiosk")

      {:ok, _} = Chores.complete_chore(morning, la(~D[2026-09-05], ~T[07:00:00]), "kiosk")

      result = Chores.standing(kid, ~D[2026-09-05])
      assert result.standing? == false
      assert %{empty?: false, complete?: true, failed?: true} = result.evening
    end

    test "empty morning roster with a clean evening is standing" do
      kid = kid_fixture()
      evening = chore_fixture(kid, %{name: "Bath", routine: "evening"})

      {:ok, _} = Chores.complete_chore(evening, la(~D[2026-09-04], ~T[19:00:00]), "kiosk")

      assert %{
               standing?: true,
               morning: %{empty?: true, complete?: true, failed?: false},
               evening: %{empty?: false, complete?: true, failed?: false}
             } = Chores.standing(kid, ~D[2026-09-05])
    end

    test "empty evening roster with a clean morning is standing" do
      kid = kid_fixture()
      morning = chore_fixture(kid, %{name: "Brush", routine: "morning"})

      {:ok, _} = Chores.complete_chore(morning, la(~D[2026-09-05], ~T[07:00:00]), "kiosk")

      assert %{
               standing?: true,
               morning: %{empty?: false, complete?: true, failed?: false},
               evening: %{empty?: true, complete?: true, failed?: false}
             } = Chores.standing(kid, ~D[2026-09-05])
    end

    test "both rosters empty is standing" do
      kid = kid_fixture()

      assert %{
               standing?: true,
               morning: %{empty?: true, complete?: true, failed?: false},
               evening: %{empty?: true, complete?: true, failed?: false}
             } = Chores.standing(kid, ~D[2026-09-05])
    end

    test "an undone completion does not count as live for either half" do
      kid = kid_fixture()
      morning = chore_fixture(kid, %{name: "Brush", routine: "morning"})
      evening = chore_fixture(kid, %{name: "Bath", routine: "evening"})

      {:ok, ce} = Chores.complete_chore(evening, la(~D[2026-09-04], ~T[19:00:00]), "kiosk")
      {:ok, _} = Chores.undo_chore(evening, la(~D[2026-09-04], ~T[19:05:00]))
      {:ok, _} = Chores.complete_chore(morning, la(~D[2026-09-05], ~T[07:00:00]), "kiosk")

      refute is_nil(ce)

      result = Chores.standing(kid, ~D[2026-09-05])
      assert result.standing? == false
      assert %{empty?: false, complete?: false, failed?: false} = result.evening
    end

    test "date-leak guard: yesterday's morning does not satisfy today's morning" do
      kid = kid_fixture()
      morning = chore_fixture(kid, %{name: "Brush", routine: "morning"})
      evening = chore_fixture(kid, %{name: "Bath", routine: "evening"})

      {:ok, _} = Chores.complete_chore(evening, la(~D[2026-09-04], ~T[19:00:00]), "kiosk")
      {:ok, _} = Chores.complete_chore(morning, la(~D[2026-09-04], ~T[07:00:00]), "kiosk")

      result = Chores.standing(kid, ~D[2026-09-05])
      assert result.standing? == false
      assert %{empty?: false, complete?: false, failed?: false} = result.morning
    end

    test "date-leak guard: two nights ago does not satisfy last night" do
      kid = kid_fixture()
      morning = chore_fixture(kid, %{name: "Brush", routine: "morning"})
      evening = chore_fixture(kid, %{name: "Bath", routine: "evening"})

      {:ok, _} = Chores.complete_chore(evening, la(~D[2026-09-03], ~T[19:00:00]), "kiosk")
      {:ok, _} = Chores.complete_chore(morning, la(~D[2026-09-05], ~T[07:00:00]), "kiosk")

      result = Chores.standing(kid, ~D[2026-09-05])
      assert result.standing? == false
      assert %{empty?: false, complete?: false, failed?: false} = result.evening
    end

    test "roster-history guard: a chore archived today still counts toward last night" do
      kid = kid_fixture()
      morning = chore_fixture(kid, %{name: "Brush", routine: "morning"})

      early =
        chore_fixture(kid, %{name: "Bath", routine: "evening"}, la(~D[2026-09-01], ~T[08:00:00]))

      late =
        chore_fixture(kid, %{name: "Floss", routine: "evening"}, la(~D[2026-09-01], ~T[08:01:00]))

      {:ok, _} = Chores.complete_chore(early, la(~D[2026-09-04], ~T[19:00:00]), "kiosk")
      # late was left undone last night, then archived this morning
      stamp(late, archived_on: ~D[2026-09-05])
      {:ok, _} = Chores.complete_chore(morning, la(~D[2026-09-05], ~T[07:00:00]), "kiosk")

      result = Chores.standing(kid, ~D[2026-09-05])
      assert result.standing? == false
      assert %{empty?: false, complete?: false, failed?: false} = result.evening
    end

    test "roster-history guard: a chore created today does not count toward last night" do
      kid = kid_fixture()
      morning = chore_fixture(kid, %{name: "Brush", routine: "morning"})
      evening = chore_fixture(kid, %{name: "Bath", routine: "evening"})

      {:ok, _} = Chores.complete_chore(evening, la(~D[2026-09-04], ~T[19:00:00]), "kiosk")
      {:ok, _} = Chores.complete_chore(morning, la(~D[2026-09-05], ~T[07:00:00]), "kiosk")

      # a chore created this morning was not live last night, so it can't
      # be missing from last night's roster
      _new_tonight =
        chore_fixture(kid, %{name: "Floss", routine: "evening"}, la(~D[2026-09-05], ~T[07:30:00]))

      assert %{
               standing?: true,
               morning: %{empty?: false, complete?: true, failed?: false},
               evening: %{empty?: false, complete?: true, failed?: false}
             } = Chores.standing(kid, ~D[2026-09-05])
    end
  end
end
