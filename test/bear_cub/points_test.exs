defmodule BearCub.PointsTest do
  # The pinning suite for the points derivation (Story 01, D57, D72).
  #
  # These tests capture the *shipped* per-kid derivation's outputs so the
  # Story 02 aggregate rewrite can be proven behavior-preserving: they must
  # pass unmodified there. The roster-drift block pins the derivation as it
  # is, not as it ought to be — see the comment there.

  use BearCub.DataCase

  alias BearCub.Chores
  alias BearCub.Chores.Completion
  alias BearCub.Points
  alias BearCub.Routines

  import BearCub.ChoresFixtures

  @tz "America/Los_Angeles"

  # Per `docs/learnings.org` [2026-07-17]: pin the windows rather than
  # inheriting whichever routine the real wall clock happens to land in.
  # Nothing here reads the clock — every derivation takes a local date —
  # but the pin keeps that true by construction rather than by accident.
  setup do
    original_windows = Application.fetch_env!(:bear_cub, :routine_windows)
    on_exit(fn -> Application.put_env(:bear_cub, :routine_windows, original_windows) end)

    Application.put_env(:bear_cub, :routine_windows,
      morning: {~T[05:00:00], ~T[17:00:00]},
      evening: {~T[17:00:00], ~T[23:00:00]}
    )

    :ok
  end

  defp la(date, time), do: DateTime.new!(date, time, @tz)

  defp fail_completion(%Completion{} = completion, at) do
    completion
    |> Ecto.Changeset.change(undone_at: at, failed_at: at)
    |> Repo.update!()
  end

  describe "extras contributions (D39, D40)" do
    test "a live extra completion adds its own points value" do
      kid = kid_fixture()
      chore = chore_fixture(kid, %{name: "Extra", routine: nil, points: 7})
      {:ok, _} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[08:00:00]), "kiosk")

      assert Points.balance(kid, ~D[2026-07-10]) == 7
      assert Points.total(kid, ~D[2026-07-10]) == 7
    end

    test "an undone extra completion contributes nothing" do
      kid = kid_fixture()
      chore = chore_fixture(kid, %{name: "Extra", routine: nil, points: 7})
      {:ok, _} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[08:00:00]), "kiosk")
      {:ok, _} = Chores.undo_chore(chore, la(~D[2026-07-10], ~T[08:05:00]))

      assert Points.balance(kid, ~D[2026-07-10]) == 0
    end

    test "a failed extra completion subtracts its own points value" do
      kid = kid_fixture()
      base = chore_fixture(kid, %{name: "Base", routine: nil, points: 20})
      chore = chore_fixture(kid, %{name: "Extra", routine: nil, points: 7})

      {:ok, _} = Chores.complete_chore(base, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")
      {:ok, completion} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[08:00:00]), "kiosk")
      fail_completion(completion, ~U[2026-07-10 15:00:00Z])

      assert Points.balance(kid, ~D[2026-07-10]) == 13
    end

    test "a failed extra redone the same day nets back to the earned value" do
      kid = kid_fixture()
      chore = chore_fixture(kid, %{name: "Extra", routine: nil, points: 7})

      {:ok, completion} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[08:00:00]), "kiosk")
      fail_completion(completion, ~U[2026-07-10 15:00:00Z])
      {:ok, _redo} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[16:00:00]), "kiosk")

      # the -7 penalty row persists alongside the new +7 live row
      assert Points.balance(kid, ~D[2026-07-10]) == 0
    end
  end

  describe "routine-day contributions (D40, D41)" do
    test "a fully-complete routine-day adds exactly R regardless of chore count" do
      kid = kid_fixture()
      chores = for n <- 1..4, do: chore_fixture(kid, %{name: "Chore #{n}", routine: "morning"})

      for chore <- chores do
        {:ok, _} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")
      end

      assert Points.balance(kid, ~D[2026-07-10]) == Routines.bonus()
    end

    test "an incomplete routine-day adds nothing" do
      kid = kid_fixture()
      a = chore_fixture(kid, %{name: "A", routine: "morning"})
      _b = chore_fixture(kid, %{name: "B", routine: "morning"})
      {:ok, _} = Chores.complete_chore(a, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")

      assert Points.balance(kid, ~D[2026-07-10]) == 0
    end

    test "two fails in one routine-day still cost a single -R (the penalty is capped)" do
      kid = kid_fixture()
      base = chore_fixture(kid, %{name: "Base", routine: nil, points: 20})
      a = chore_fixture(kid, %{name: "A", routine: "morning"})
      b = chore_fixture(kid, %{name: "B", routine: "morning"})

      {:ok, _} = Chores.complete_chore(base, la(~D[2026-07-10], ~T[06:00:00]), "kiosk")
      {:ok, ca} = Chores.complete_chore(a, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")
      {:ok, cb} = Chores.complete_chore(b, la(~D[2026-07-10], ~T[07:01:00]), "kiosk")

      fail_completion(ca, ~U[2026-07-10 15:00:00Z])
      fail_completion(cb, ~U[2026-07-10 15:01:00Z])

      assert Points.balance(kid, ~D[2026-07-10]) == 20 - Routines.bonus()
    end

    test "morning and evening are separate routine-days on the same date" do
      kid = kid_fixture()
      morning = chore_fixture(kid, %{name: "Morning", routine: "morning"})
      evening = chore_fixture(kid, %{name: "Evening", routine: "evening"})

      {:ok, _} = Chores.complete_chore(morning, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")
      {:ok, _} = Chores.complete_chore(evening, la(~D[2026-07-10], ~T[19:00:00]), "kiosk")

      assert Points.balance(kid, ~D[2026-07-10]) == 2 * Routines.bonus()
    end
  end

  describe "cumulative all-time accumulation (D41)" do
    test "routine-days accumulate across dates, and only up to the given local date" do
      kid = kid_fixture()
      chore = chore_fixture(kid, %{name: "A", routine: "morning"})

      for day <- [~D[2026-07-01], ~D[2026-07-02], ~D[2026-07-03]] do
        {:ok, _} = Chores.complete_chore(chore, la(day, ~T[07:00:00]), "kiosk")
      end

      # day-rollover behavior is exercised by passing a different local
      # date, never by mocking a clock
      assert Points.balance(kid, ~D[2026-06-30]) == 0
      assert Points.balance(kid, ~D[2026-07-01]) == Routines.bonus()
      assert Points.balance(kid, ~D[2026-07-02]) == 2 * Routines.bonus()
      assert Points.balance(kid, ~D[2026-07-03]) == 3 * Routines.bonus()
      assert Points.balance(kid, ~D[2026-07-31]) == 3 * Routines.bonus()
    end

    test "extras accumulate across dates alongside routine-days" do
      kid = kid_fixture()
      routine = chore_fixture(kid, %{name: "Routine", routine: "morning"})

      extras =
        for n <- 1..3, do: chore_fixture(kid, %{name: "Extra #{n}", routine: nil, points: 4})

      {:ok, _} = Chores.complete_chore(routine, la(~D[2026-07-01], ~T[07:00:00]), "kiosk")

      for {chore, day} <- Enum.zip(extras, [~D[2026-07-01], ~D[2026-07-02], ~D[2026-07-03]]) do
        {:ok, _} = Chores.complete_chore(chore, la(day, ~T[08:00:00]), "kiosk")
      end

      assert Points.balance(kid, ~D[2026-07-01]) == Routines.bonus() + 4
      assert Points.balance(kid, ~D[2026-07-10]) == Routines.bonus() + 12
    end

    test "one kid's completions never leak into another kid's balance" do
      kid = kid_fixture(%{name: "Kid A", position: 0})
      other = kid_fixture(%{name: "Kid B", position: 1})
      chore = chore_fixture(kid, %{name: "Extra", routine: nil, points: 9})
      {:ok, _} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[08:00:00]), "kiosk")

      assert Points.balance(kid, ~D[2026-07-10]) == 9
      assert Points.balance(other, ~D[2026-07-10]) == 0
    end
  end

  describe "the aggregate floor at zero (D41)" do
    test "total/2 floors a negative balance at zero while balance/2 stays signed" do
      kid = kid_fixture()
      small = chore_fixture(kid, %{name: "Small", routine: nil, points: 2})
      big = chore_fixture(kid, %{name: "Big", routine: nil, points: 5})

      {:ok, cs} = Chores.complete_chore(small, la(~D[2026-07-10], ~T[08:00:00]), "kiosk")
      {:ok, cb} = Chores.complete_chore(big, la(~D[2026-07-10], ~T[08:01:00]), "kiosk")
      fail_completion(cs, ~U[2026-07-10 15:00:00Z])
      fail_completion(cb, ~U[2026-07-10 15:01:00Z])

      assert Points.balance(kid, ~D[2026-07-10]) == -7
      assert Points.total(kid, ~D[2026-07-10]) == 0
    end

    test "a kid with no completions scores zero — nothing is stored, it is all derived" do
      kid = kid_fixture()
      _chore = chore_fixture(kid, %{name: "Extra", routine: nil, points: 5})

      assert Points.balance(kid, ~D[2026-07-10]) == 0
      assert Points.total(kid, ~D[2026-07-10]) == 0
    end
  end

  describe "roster drift (D72) — pinned as shipped, not as it ought to be" do
    # These two tests pin a *known defect*: `routine_day_contribution/3`
    # evaluates historical routine-days against the kid's CURRENT roster,
    # so a roster edit retroactively moves past routine-day points. The
    # expected values below are what the shipped code produces, not what
    # is right. Do not "fix" this here or in Story 02 — a refactor that
    # silently repaired drift would be an unruled semantic change smuggled
    # in under a performance story. Roster drift is its own backlog entry.
    #
    # Every assertion is made through BOTH `balance/2` and `balances/1`:
    # the design's §Testing excerpt requires the *aggregate* pinned on the
    # drift path, and Story 02 rewrites `balances/1` as the grouped query
    # with `balance/2` delegating to it. Pinning only the singular form
    # would leave the grouped query's drift behavior unproven — exactly
    # the weird path D72 says must be covered.

    test "adding a routine chore today retroactively wipes a past routine-day's +R" do
      kid = kid_fixture()
      a = chore_fixture(kid, %{name: "A", routine: "morning"})
      b = chore_fixture(kid, %{name: "B", routine: "morning"})
      {:ok, _} = Chores.complete_chore(a, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")
      {:ok, _} = Chores.complete_chore(b, la(~D[2026-07-10], ~T[07:01:00]), "kiosk")

      assert Points.balance(kid, ~D[2026-07-20]) == Routines.bonus()
      assert Points.balances(~D[2026-07-20]) == %{kid.id => Routines.bonus()}

      _c = chore_fixture(kid, %{name: "C (added later)", routine: "morning"})

      # DRIFT: 2026-07-10 was fully complete when it happened, but it is
      # re-evaluated against today's three-chore roster and now scores 0.
      assert Points.balance(kid, ~D[2026-07-20]) == 0
      assert Points.balances(~D[2026-07-20]) == %{kid.id => 0}
    end

    test "deleting a routine chore retroactively completes a past routine-day, granting +R" do
      kid = kid_fixture()
      a = chore_fixture(kid, %{name: "A", routine: "morning"})
      b = chore_fixture(kid, %{name: "B", routine: "morning"})
      {:ok, _} = Chores.complete_chore(a, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")

      assert Points.balance(kid, ~D[2026-07-20]) == 0
      assert Points.balances(~D[2026-07-20]) == %{kid.id => 0}

      {:ok, _} = Chores.delete_chore(b)

      # DRIFT: 2026-07-10 was never fully complete, but the only chore
      # left on the roster has a live completion that day, so it scores +R.
      assert Points.balance(kid, ~D[2026-07-20]) == Routines.bonus()
      assert Points.balances(~D[2026-07-20]) == %{kid.id => Routines.bonus()}
    end
  end

  describe "whole-render map forms (D57)" do
    test "balances/1 returns every kid's raw signed balance keyed by kid id" do
      kid_a = kid_fixture(%{name: "Kid A", position: 0})
      kid_b = kid_fixture(%{name: "Kid B", position: 1})
      kid_c = kid_fixture(%{name: "Kid C", position: 2})

      earner = chore_fixture(kid_a, %{name: "Extra", routine: nil, points: 9})
      {:ok, _} = Chores.complete_chore(earner, la(~D[2026-07-10], ~T[08:00:00]), "kiosk")

      debtor = chore_fixture(kid_b, %{name: "Extra", routine: nil, points: 4})
      {:ok, completion} = Chores.complete_chore(debtor, la(~D[2026-07-10], ~T[08:00:00]), "kiosk")
      fail_completion(completion, ~U[2026-07-10 15:00:00Z])

      assert Points.balances(~D[2026-07-10]) == %{
               kid_a.id => 9,
               kid_b.id => -4,
               kid_c.id => 0
             }
    end

    test "totals/1 is balances/1 with the D41 floor applied per kid" do
      kid_a = kid_fixture(%{name: "Kid A", position: 0})
      kid_b = kid_fixture(%{name: "Kid B", position: 1})

      earner = chore_fixture(kid_a, %{name: "Extra", routine: nil, points: 9})
      {:ok, _} = Chores.complete_chore(earner, la(~D[2026-07-10], ~T[08:00:00]), "kiosk")

      debtor = chore_fixture(kid_b, %{name: "Extra", routine: nil, points: 4})
      {:ok, completion} = Chores.complete_chore(debtor, la(~D[2026-07-10], ~T[08:00:00]), "kiosk")
      fail_completion(completion, ~U[2026-07-10 15:00:00Z])

      assert Points.totals(~D[2026-07-10]) == %{kid_a.id => 9, kid_b.id => 0}
    end

    test "the map forms agree with the per-kid forms" do
      kid = kid_fixture()
      chore = chore_fixture(kid, %{name: "A", routine: "morning"})
      {:ok, _} = Chores.complete_chore(chore, la(~D[2026-07-09], ~T[07:00:00]), "kiosk")
      {:ok, _} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")

      for date <- [~D[2026-07-09], ~D[2026-07-10]] do
        assert Points.balances(date)[kid.id] == Points.balance(kid, date)
        assert Points.totals(date)[kid.id] == Points.total(kid, date)
      end
    end

    test "with no kids the map forms are empty" do
      assert Points.balances(~D[2026-07-10]) == %{}
      assert Points.totals(~D[2026-07-10]) == %{}
    end
  end

  describe "the shipped worked examples, re-pointed at Points.total/2 (D41)" do
    # Moved here verbatim from `ChoresTest`'s `points_total/2` block when
    # the floor moved up to `Points` (D57) — expected values unchanged.

    test "worked example: extra earn -> fail -> redo nets back to start (20 -> 25 -> 15 -> 20)" do
      kid = kid_fixture()

      baseline_chores =
        for n <- 1..4, do: chore_fixture(kid, %{name: "Baseline #{n}", routine: nil, points: 5})

      baseline_days = [~D[2026-07-01], ~D[2026-07-02], ~D[2026-07-03], ~D[2026-07-04]]

      for {chore, day} <- Enum.zip(baseline_chores, baseline_days) do
        {:ok, _} = Chores.complete_chore(chore, la(day, ~T[08:00:00]), "kiosk")
      end

      assert Points.total(kid, ~D[2026-07-10]) == 20

      extra = chore_fixture(kid, %{name: "Extra", routine: nil, points: 5})
      {:ok, completion} = Chores.complete_chore(extra, la(~D[2026-07-10], ~T[08:00:00]), "kiosk")
      assert Points.total(kid, ~D[2026-07-10]) == 25

      fail_completion(completion, ~U[2026-07-10 15:00:00Z])
      assert Points.total(kid, ~D[2026-07-10]) == 15

      {:ok, _redo} = Chores.complete_chore(extra, la(~D[2026-07-10], ~T[16:00:00]), "kiosk")
      assert Points.total(kid, ~D[2026-07-10]) == 20
    end

    test "floor case: the aggregate never shows negative though the true sum dips below zero (3 -> 8 -> 0 -> 3)" do
      kid = kid_fixture()
      baseline = chore_fixture(kid, %{name: "Baseline", routine: nil, points: 3})
      {:ok, _} = Chores.complete_chore(baseline, la(~D[2026-07-01], ~T[08:00:00]), "kiosk")

      assert Points.total(kid, ~D[2026-07-10]) == 3

      chore = chore_fixture(kid, %{name: "Five", routine: nil, points: 5})
      {:ok, completion} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[08:00:00]), "kiosk")
      assert Points.total(kid, ~D[2026-07-10]) == 8

      fail_completion(completion, ~U[2026-07-10 15:00:00Z])
      assert Points.total(kid, ~D[2026-07-10]) == 0

      {:ok, _redo} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[16:00:00]), "kiosk")
      assert Points.total(kid, ~D[2026-07-10]) == 3
    end

    test "the floor applies to the aggregate only — the raw signed row stays recoverable (SC-4)" do
      kid = kid_fixture()
      chore = chore_fixture(kid, %{name: "Five", routine: nil, points: 5})
      {:ok, completion} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[08:00:00]), "kiosk")
      failed = fail_completion(completion, ~U[2026-07-10 15:00:00Z])

      assert Points.total(kid, ~D[2026-07-10]) == 0
      assert Chores.extra_contribution(failed, chore) == -5
    end

    test "the raw signed aggregate below zero is recoverable by composing the same pure functions (SC-4)" do
      kid = kid_fixture()
      small = chore_fixture(kid, %{name: "Small", routine: nil, points: 2})
      big = chore_fixture(kid, %{name: "Big", routine: nil, points: 5})

      {:ok, small_completion} =
        Chores.complete_chore(small, la(~D[2026-07-10], ~T[08:00:00]), "kiosk")

      {:ok, big_completion} =
        Chores.complete_chore(big, la(~D[2026-07-10], ~T[08:01:00]), "kiosk")

      failed_small = fail_completion(small_completion, ~U[2026-07-10 15:00:00Z])
      failed_big = fail_completion(big_completion, ~U[2026-07-10 15:01:00Z])

      raw_sum =
        Chores.extra_contribution(failed_small, small) +
          Chores.extra_contribution(failed_big, big)

      assert raw_sum == -7
      assert Points.total(kid, ~D[2026-07-10]) == 0
    end

    test "a completed routine-day counts toward the total alongside extras" do
      kid = kid_fixture()
      a = chore_fixture(kid, %{name: "A", routine: "morning"})
      b = chore_fixture(kid, %{name: "B", routine: "morning"})
      {:ok, _} = Chores.complete_chore(a, la(~D[2026-07-10], ~T[07:00:00]), "kiosk")
      {:ok, _} = Chores.complete_chore(b, la(~D[2026-07-10], ~T[07:01:00]), "kiosk")

      assert Points.total(kid, ~D[2026-07-10]) == Routines.bonus()
    end

    test "recomputes purely from completions — nothing stored, a kid with none scores zero" do
      kid = kid_fixture()
      _chore = chore_fixture(kid, %{name: "Five", routine: nil, points: 5})

      assert Points.total(kid, ~D[2026-07-10]) == 0
    end
  end

  describe "the earnings/spend split (D57)" do
    test "balance/2 equals Chores.earnings/2 while no spends exist" do
      kid = kid_fixture()
      chore = chore_fixture(kid, %{name: "Extra", routine: nil, points: 6})
      {:ok, _} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[08:00:00]), "kiosk")

      assert Points.balance(kid, ~D[2026-07-10]) == Chores.earnings(kid, ~D[2026-07-10])
    end

    test "Chores.earnings/2 is raw signed and unfloored — the floor lives only in Points" do
      kid = kid_fixture()
      chore = chore_fixture(kid, %{name: "Extra", routine: nil, points: 6})
      {:ok, completion} = Chores.complete_chore(chore, la(~D[2026-07-10], ~T[08:00:00]), "kiosk")
      fail_completion(completion, ~U[2026-07-10 15:00:00Z])

      assert Chores.earnings(kid, ~D[2026-07-10]) == -6
      assert Points.total(kid, ~D[2026-07-10]) == 0
    end
  end
end
