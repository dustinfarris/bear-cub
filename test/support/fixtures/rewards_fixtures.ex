defmodule BearCub.RewardsFixtures do
  @moduledoc """
  Test helpers for creating entities via the `BearCub.Rewards` context.
  """

  alias BearCub.Rewards

  @doc "kid_or_nil defaults to nil (offered to any kid)."
  def reward_fixture(kid_or_nil \\ nil, attrs \\ %{}) do
    {:ok, reward} =
      Rewards.create_reward(
        kid_or_nil,
        Enum.into(attrs, %{name: "Extra Story Time", icon: "🎁", points: 20, repeatable: true})
      )

    reward
  end
end
