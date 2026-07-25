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

  @doc """
  The kid's raw signed balance as of `local_date` — may be negative
  (SC-4). This is the affordability figure: a kid in the red can't buy.
  """
  def balance(%Kid{} = kid, %Date{} = local_date) do
    Chores.earnings(kid, local_date) + spend_total(kid, local_date)
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
  the whole-render form (D57).
  """
  def balances(%Date{} = local_date) do
    Chores.list_kids()
    |> Map.new(&{&1.id, balance(&1, local_date)})
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

  # The D42 spend seam. Story 03 fills this in from `BearCub.Rewards`;
  # until then no redemption rows exist and the term is structurally zero.
  defp spend_total(%Kid{}, %Date{}), do: 0
end
