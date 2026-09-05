defmodule BearCub.Chores.Chore do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias BearCub.Chores.Completion
  alias BearCub.Repo

  @routines ~w(morning evening)
  @shows_in_values ~w(morning evening extra extra_daily)

  schema "chores" do
    field :routine, :string
    # virtual: not persisted. Drives the admin "Shows in" select and
    # collapses into `routine`/`recurring?` in the changeset (D83) — it's
    # a plain string, not a predicate, so it keeps a plain name.
    field :shows_in, :string, virtual: true
    field :name, :string
    field :icon, :string
    field :position, :integer
    field :points, :integer, default: 5
    # chore lifetime, in local dates so they compare cleanly against
    # completions.local_date (D80). `archived_on` nil means live.
    field :active_from, :date
    field :archived_on, :date
    # `is_recurring` in the database, `recurring?` in the schema (D82).
    # A raw fragment(...) bypasses this mapping and must spell the
    # column name — `extras_by_kid/1` already contains such a fragment.
    field :recurring?, :boolean, source: :is_recurring, default: false

    belongs_to :kid, BearCub.Chores.Kid

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(chore, attrs) do
    chore
    |> cast(attrs, [:routine, :name, :icon, :points, :shows_in])
    |> validate_required([:name, :icon])
    |> validate_inclusion(:shows_in, @shows_in_values)
    |> apply_shows_in()
    |> validate_inclusion(:routine, @routines)
    # defence in depth for the create path, which sets `routine` directly
    # rather than through `shows_in` (D83)
    |> force_non_recurring_when_routine_present()
    |> check_reclassification_lock(chore)
    |> assoc_constraint(:kid)
  end

  @doc """
  `chore` with its virtual `shows_in` pre-populated from the stored
  `routine`/`recurring?` pair (or from a freshly built chore's pinned
  `routine`), for a display-only changeset that preselects the "Shows in"
  option — never call this before `create_chore/3` or `update_chore/2`,
  or the derived value would be cast into `changes` and leak onto the
  persisted struct even when the caller never touched `shows_in`.
  """
  def with_default_shows_in(%__MODULE__{shows_in: nil} = chore) do
    %{chore | shows_in: shows_in_for(chore.routine, chore.recurring?)}
  end

  def with_default_shows_in(chore), do: chore

  defp shows_in_for(nil, true), do: "extra_daily"
  defp shows_in_for(nil, false), do: "extra"
  defp shows_in_for(routine, _recurring?), do: routine

  defp apply_shows_in(changeset) do
    case fetch_change(changeset, :shows_in) do
      {:ok, "morning"} ->
        put_change(changeset, :routine, "morning")

      {:ok, "evening"} ->
        put_change(changeset, :routine, "evening")

      {:ok, "extra"} ->
        changeset |> put_change(:routine, nil) |> put_change(:recurring?, false)

      {:ok, "extra_daily"} ->
        changeset |> put_change(:routine, nil) |> put_change(:recurring?, true)

      _ ->
        changeset
    end
  end

  defp force_non_recurring_when_routine_present(changeset) do
    case get_field(changeset, :routine) do
      nil -> changeset
      _ -> put_change(changeset, :recurring?, false)
    end
  end

  # A bucket (routine) change is refused once the chore has any completion
  # row — undone and failed ones included, since rows are never deleted
  # (D84). Runs only when the submitted `shows_in` (or a direct `routine`
  # cast) implies a different `routine` than the stored one; the
  # extra <-> extra_daily toggle never touches `routine` and is never
  # locked (D85).
  defp check_reclassification_lock(changeset, %__MODULE__{id: nil}), do: changeset

  defp check_reclassification_lock(changeset, %__MODULE__{id: id}) do
    case fetch_change(changeset, :routine) do
      {:ok, _new_routine} ->
        if Repo.exists?(from c in Completion, where: c.chore_id == ^id) do
          add_error(
            changeset,
            :shows_in,
            "can't be changed once this chore has history — archive it and create a new one instead"
          )
        else
          changeset
        end

      :error ->
        changeset
    end
  end
end
