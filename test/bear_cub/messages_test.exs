defmodule BearCub.MessagesTest do
  use ExUnit.Case, async: true

  alias BearCub.Messages

  test "morning_complete/0 returns the morning-routine affirmation" do
    assert Messages.morning_complete() == "Today is going to be a wonderful day"
  end

  test "evening_complete/0 returns the evening-routine affirmation" do
    assert Messages.evening_complete() == "You did great today!"
  end
end
