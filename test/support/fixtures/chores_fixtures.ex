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

  @doc """
  Creates a chore, live since the local date of `local_now`.

  The default is the same epoch floor the `add_chore_lifecycle` migration
  gives pre-lifecycle rows, so a chore a test never dates is live on every
  date that test uses; a test that cares about the day a chore became live
  passes its own local datetime, through the real create path (D86).
  """
  def chore_fixture(kid \\ nil, attrs \\ %{}, local_now \\ epoch()) do
    kid = kid || kid_fixture()

    {:ok, chore} =
      Chores.create_chore(
        kid,
        Enum.into(attrs, %{name: "Brush Teeth", icon: "🪥", routine: "morning"}),
        local_now
      )

    chore
  end

  defp epoch, do: DateTime.new!(~D[1970-01-01], ~T[00:00:00], BearCub.LocalTime.timezone())
end
