defmodule BearCub.ChoresFixtures do
  @moduledoc """
  Test helpers for creating entities via the `BearCub.Chores` context.
  """

  alias BearCub.Chores

  def kid_fixture(attrs \\ %{}) do
    {:ok, kid} =
      attrs
      |> Enum.into(%{name: "Some Kid", color: "#f59e0b", position: 0})
      |> Chores.create_kid()

    kid
  end

  def chore_fixture(kid \\ nil, attrs \\ %{}) do
    kid = kid || kid_fixture()

    {:ok, chore} =
      Chores.create_chore(
        kid,
        Enum.into(attrs, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})
      )

    chore
  end
end
