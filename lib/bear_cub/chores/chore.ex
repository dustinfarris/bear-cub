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
    # per-chore opt-in to a parent push on completion; same
    # `field/3` `:source` bridge as `recurring?`.
    field :notify_on_complete?, :boolean, source: :notify_on_complete, default: false
    # points per unit; NULL means an ordinary flat chore. Legal only on
    # extras (routine nil) and immutable once the chore is persisted.
    field :unit_rate, :integer
    # ceiling on the count; NULL iff unit_rate is NULL.
    field :unit_max, :integer
    # virtual: drives the admin "counted chore" checkbox and collapses
    # into the unit_rate/unit_max pair in the changeset, exactly as
    # `shows_in` collapses into `routine`/`recurring?`.
    field :counts_units?, :boolean, virtual: true
    # display-only: this morning chore carries today's weather on the
    # kiosk. Only a morning routine chore may hold true (D142); the
    # changeset clears it elsewhere rather than refusing it.
    field :shows_weather, :boolean, default: false

    belongs_to :kid, BearCub.Chores.Kid

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(chore, attrs) do
    chore
    |> cast(attrs, [
      :routine,
      :name,
      :icon,
      :points,
      :shows_in,
      :notify_on_complete?,
      :counts_units?,
      :unit_rate,
      :unit_max,
      :shows_weather
    ])
    |> validate_required([:name, :icon])
    |> validate_inclusion(:shows_in, @shows_in_values)
    |> apply_shows_in()
    |> validate_inclusion(:routine, @routines)
    # defence in depth for the create path, which sets `routine` directly
    # rather than through `shows_in` (D83)
    |> force_non_recurring_when_routine_present()
    |> clear_shows_weather_off_morning()
    |> apply_counts_units()
    |> validate_counted_extra()
    |> check_immutability_locks(chore)
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

  # Cleared, not refused: the admin form hides the checkbox off the
  # morning routine, so an error on it would be invisible (D142).
  defp clear_shows_weather_off_morning(changeset) do
    if get_field(changeset, :routine) == "morning" do
      changeset
    else
      put_change(changeset, :shows_weather, false)
    end
  end

  # Collapses the virtual `counts_units?` checkbox into the stored pair,
  # same shape as `apply_shows_in/1`: unchecked forces a NULL pair;
  # checked leaves the cast rate/max in place for `validate_counted_extra/1`
  # to require and bound.
  defp apply_counts_units(changeset) do
    case fetch_change(changeset, :counts_units?) do
      {:ok, false} ->
        changeset |> put_change(:unit_rate, nil) |> put_change(:unit_max, nil)

      _ ->
        changeset
    end
  end

  # Must run after `apply_shows_in/1` has resolved `routine` (Technical
  # Notes): counting is legal only on an extra, and `routine` may have
  # just been derived from `shows_in` rather than cast directly.
  defp validate_counted_extra(changeset) do
    changeset
    |> require_pair_when_checked()
    |> validate_no_routine_when_counted()
    |> validate_pair_together()
    |> validate_number(:unit_rate, greater_than_or_equal_to: 1)
    |> validate_number(:unit_max, greater_than_or_equal_to: 1)
  end

  defp require_pair_when_checked(changeset) do
    case fetch_change(changeset, :counts_units?) do
      {:ok, true} -> validate_required(changeset, [:unit_rate, :unit_max])
      _ -> changeset
    end
  end

  defp validate_no_routine_when_counted(changeset) do
    if get_field(changeset, :unit_rate) && get_field(changeset, :routine) do
      add_error(changeset, :unit_rate, "can only be set on an extra chore, not one in a routine")
    else
      changeset
    end
  end

  defp validate_pair_together(changeset) do
    case {get_field(changeset, :unit_rate), get_field(changeset, :unit_max)} do
      {nil, nil} ->
        changeset

      {nil, _max} ->
        add_error(changeset, :unit_rate, "must be set together with a max, or not at all")

      {_rate, nil} ->
        add_error(changeset, :unit_max, "must be set together with a rate, or not at all")

      {_rate, _max} ->
        changeset
    end
  end

  # Defence in depth, not the primary mechanism (Technical Notes): the
  # admin form never submits these fields on edit. Keyed on whether the
  # chore is persisted, not on completion history — SC-4 fixes these the
  # moment the chore exists, unlike `check_reclassification_lock/2`.
  defp check_immutability_locks(changeset, %__MODULE__{id: nil}), do: changeset

  defp check_immutability_locks(changeset, %__MODULE__{} = chore) do
    changeset
    |> forbid_change(:unit_rate)
    |> forbid_change(:unit_max)
    |> forbid_change(:counts_units?)
    |> forbid_points_change_when_counted(chore)
  end

  @immutable_message "can't be changed once this chore has history — archive it and create a new one instead"

  defp forbid_change(changeset, field) do
    case fetch_change(changeset, field) do
      {:ok, _value} -> add_error(changeset, field, @immutable_message)
      :error -> changeset
    end
  end

  defp forbid_points_change_when_counted(changeset, %__MODULE__{unit_rate: rate})
       when not is_nil(rate) do
    forbid_change(changeset, :points)
  end

  defp forbid_points_change_when_counted(changeset, %__MODULE__{}), do: changeset

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
