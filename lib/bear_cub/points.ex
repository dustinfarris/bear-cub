defmodule BearCub.Points do
  @moduledoc """
  The points composition module (D57) — the only place in the app that
  knows both sides of the ledger:

      balance = Chores.earnings + Rewards.spend_total
                └─ D42's completions_earnings   └─ D42's other_signed_inputs

  `BearCub.Chores` derives earnings and never learns that rewards exist;
  `BearCub.Rewards` owns spends and never learns that chores exist. Every
  balance read in the app goes through here, so a missed caller can't
  silently show a half-summed figure.

  Nothing is stored (D10): every figure is derived from `completions` (and,
  from Story 03, `redemptions`) as of the *local date* passed in. The D41
  display floor lives here, on the complete summation — never on an
  individual contribution, and never inside `Chores`.
  """

  alias BearCub.Chores
  alias BearCub.Chores.Kid
  alias BearCub.Rewards

  @doc """
  The kid's raw signed balance as of `local_date` — may be negative
  (SC-4). This is the affordability figure: a kid in the red can't buy.
  Delegates to `balances/1` (Story 02, D72) for an ergonomic single-kid
  entry point; the map is where the grouped-query work happens.
  """
  def balance(%Kid{} = kid, %Date{} = local_date) do
    local_date
    |> balances()
    |> Map.fetch!(kid.id)
  end

  @doc """
  The kid's floored display figure as of `local_date` — `max(0, balance)`
  (D41). The badge never shows a negative number; the debt is still real
  and still recoverable via `balance/2`.
  """
  def total(%Kid{} = kid, %Date{} = local_date) do
    max(0, balance(kid, local_date))
  end

  @doc """
  Every kid's raw signed balance as of `local_date`, keyed by kid id —
  the whole-render form (D57), rewritten in Story 02 (D72) as grouped
  aggregate queries rather than a per-kid loop over `Chores.earnings/2`:
  O(1) queries for the entire roster, not O(kids × days). Story 03 adds
  the third leg, `Rewards.spend_totals_by_kid/1` (D72). Nothing is
  cached or memoized (D10) — every read recomputes from `completions`
  and `redemptions`.
  """
  def balances(%Date{} = local_date) do
    earnings = Chores.earnings_by_kid(local_date)
    spends = Rewards.spend_totals_by_kid(local_date)

    Chores.list_kids()
    |> Map.new(&{&1.id, Map.get(earnings, &1.id, 0) + Map.get(spends, &1.id, 0)})
  end

  @doc """
  Every kid's floored display figure as of `local_date`, keyed by kid id
  — `balances/1` with the D41 floor applied per kid.
  """
  def totals(%Date{} = local_date) do
    local_date
    |> balances()
    |> Map.new(fn {kid_id, balance} -> {kid_id, max(0, balance)} end)
  end

  @history_months 8

  @doc """
  Every kid's points *earned* (D158) — the signed contribution of
  `Chores.earnings_by_kid_month/1`, with no redemptions leg, so spending
  never lowers it and a parent's fail does. Per kid:

      %{lifetime: non_neg_integer, months: [{first_of_month, non_neg_integer}]}

  `months` is the last #{@history_months} ending with `local_date`'s month, none before
  the kid's first completion month, always including the current month
  (a kid with no completions gets that one slot at 0). Each month floors
  at 0, and `lifetime` is `max(0, sum of the unfloored months)`.
  """
  def earned_history(%Date{} = local_date) do
    by_month = Chores.earnings_by_kid_month(local_date)
    current = Date.beginning_of_month(local_date)
    window_start = Enum.reduce(1..(@history_months - 1), current, fn _, d -> prev_month(d) end)

    Map.new(Chores.list_kids(), fn kid ->
      earned = Map.get(by_month, kid.id, %{})

      first =
        case Map.keys(earned) do
          [] -> current
          keys -> Enum.min(keys, Date)
        end

      start = Enum.max([first, window_start], Date)

      months =
        start
        |> Stream.iterate(&next_month/1)
        |> Enum.take_while(&(Date.compare(&1, current) != :gt))
        |> Enum.map(&{&1, max(0, Map.get(earned, &1, 0))})

      {kid.id, %{lifetime: max(0, earned |> Map.values() |> Enum.sum()), months: months}}
    end)
  end

  defp prev_month(date), do: date |> Date.add(-1) |> Date.beginning_of_month()
  defp next_month(date), do: date |> Date.end_of_month() |> Date.add(1)
end
