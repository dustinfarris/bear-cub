defmodule BearCubWeb.RecordChartTest do
  use ExUnit.Case, async: true

  alias BearCubWeb.RecordChart

  describe "top/1" do
    test "never below 40" do
      assert RecordChart.top([0]) == 40
      assert RecordChart.top([40]) == 40
    end

    test "rounds the maximum up to the next 40" do
      assert RecordChart.top([41]) == 80
      assert RecordChart.top([3, 120, 7]) == 120
      assert RecordChart.top([121]) == 160
    end
  end

  describe "bar_height/3" do
    test "scales against top over 186 px" do
      assert RecordChart.bar_height(40, 80, false) == 93
      assert RecordChart.bar_height(80, 80, false) == 186
    end

    test "floors at 12 px, and 18 px for the current month" do
      assert RecordChart.bar_height(0, 40, false) == 12
      assert RecordChart.bar_height(1, 160, false) == 12
      assert RecordChart.bar_height(0, 40, true) == 18
      assert RecordChart.bar_height(2, 160, true) == 18
      assert RecordChart.bar_height(40, 40, true) == 186
    end
  end

  describe "layout/1" do
    test "eight months: scaled bars, gridlines, current last" do
      months = for m <- 1..8, do: {Date.new!(2026, m, 1), m * 10}
      layout = RecordChart.layout(months)

      assert layout.gridlines?

      assert layout.top == 80
      assert length(layout.bars) == 8
      assert hd(layout.bars).label == "Jan"
      assert List.last(layout.bars).label == "Aug"
      assert List.last(layout.bars).current?
      assert Enum.count(layout.bars, & &1.current?) == 1
      assert List.last(layout.bars).height == 186
    end

    test "fewer than five months: no gridlines" do
      layout = RecordChart.layout([{~D[2026-09-01], 5}, {~D[2026-10-01], 9}])
      refute layout.gridlines?
      assert length(layout.bars) == 2
    end

    test "five months is the first with gridlines" do
      months = for m <- 6..10, do: {Date.new!(2026, m, 1), 1}
      assert RecordChart.layout(months).gridlines?
    end

    test "a lone current month at 0 gets the minimum current height" do
      layout = RecordChart.layout([{~D[2026-10-01], 0}])
      refute layout.gridlines?
      assert [%{label: "Oct", height: 18, current?: true}] = layout.bars
    end
  end
end
