defmodule BearCub.Chores do
  @moduledoc """
  Kids, chores, and completions — pure local CRUD, no network.

  This context must never depend on `BearCub.Calendars` (design §1):
  calendar trouble structurally cannot touch the chore path.
  """

  import Ecto.Query, warn: false

  alias BearCub.Repo
  alias BearCub.Chores.Kid

  @doc "All kids ordered for display: position 0 is the left column."
  def list_kids do
    Repo.all(from k in Kid, order_by: [asc: k.position, asc: k.id])
  end

  @doc """
  Gets a single kid.

  Raises `Ecto.NoResultsError` if the Kid does not exist.

  ## Examples

      iex> get_kid!(123)
      %Kid{}

      iex> get_kid!(456)
      ** (Ecto.NoResultsError)

  """
  def get_kid!(id), do: Repo.get!(Kid, id)

  @doc """
  Creates a kid.

  ## Examples

      iex> create_kid(%{field: value})
      {:ok, %Kid{}}

      iex> create_kid(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_kid(attrs) do
    %Kid{}
    |> Kid.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a kid.

  ## Examples

      iex> update_kid(kid, %{field: new_value})
      {:ok, %Kid{}}

      iex> update_kid(kid, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_kid(%Kid{} = kid, attrs) do
    kid
    |> Kid.changeset(attrs)
    |> Repo.update()
  end

  def change_kid(%Kid{} = kid, attrs \\ %{}) do
    Kid.changeset(kid, attrs)
  end
end
