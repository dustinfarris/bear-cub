defmodule BearCub.Calendars.Calendar do
  use Ecto.Schema
  import Ecto.Changeset

  schema "calendars" do
    field :label, :string
    # A private Google ICS URL is a family secret (D9): redact so it can
    # never leak through inspected structs, changesets, or crash reports.
    field :ics_url, :string, redact: true
    field :last_payload, :string
    field :last_fetched_at, :utc_datetime
    field :last_error, :string

    belongs_to :kid, BearCub.Chores.Kid

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(calendar, attrs) do
    calendar
    |> cast(attrs, [:kid_id, :label, :ics_url])
    |> validate_required([:label, :ics_url])
    |> assoc_constraint(:kid)
  end
end
