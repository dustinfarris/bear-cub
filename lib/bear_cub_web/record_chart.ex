defmodule BearCubWeb.RecordChart do
  @moduledoc """
  The arithmetic behind the record screen's monthly chart (DESIGN, My record
  screen): each kid's own scale, bar heights and floors, kept apart from the
  markup so it can be tested alone.
  """

  @max_height 186
  @min_height 12
  @min_current_height 18
  @gridline_months 5

  @doc "A kid's scale: the largest month rounded up to a multiple of 40, at least 40."
  def top(values), do: max(40, ceil(Enum.max(values, fn -> 0 end) / 40) * 40)

  @doc "Bar height in px from the baseline."
  def bar_height(value, top, current?) do
    max(
      round(value / top * @max_height),
      if(current?, do: @min_current_height, else: @min_height)
    )
  end

  @doc """
  Lays out `months` (`[{first_of_month, points}]`, oldest first, the last the
  current month) for one kid. Fewer than five months drop the gridlines.
  """
  def layout(months) do
    top = top(Enum.map(months, &elem(&1, 1)))
    last = length(months) - 1

    bars =
      months
      |> Enum.with_index()
      |> Enum.map(fn {{date, value}, i} ->
        current? = i == last

        %{
          label: Calendar.strftime(date, "%b"),
          current?: current?,
          height: bar_height(value, top, current?)
        }
      end)

    %{top: top, bars: bars, gridlines?: length(months) >= @gridline_months}
  end
end
