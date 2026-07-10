defmodule BearCub.Calendars.CalendarTest do
  use BearCub.DataCase

  alias BearCub.Calendars.Calendar

  @secret_url "https://calendar.google.com/calendar/ical/private-abc123/basic.ics"

  test "ics_url never appears in inspected structs" do
    calendar = %Calendar{label: "School", ics_url: @secret_url}

    # Ecto's derived Inspect omits redacted fields from structs entirely.
    refute inspect(calendar) =~ "private-abc123"
  end

  test "ics_url never appears in inspected changesets" do
    changeset = Calendar.changeset(%Calendar{}, %{label: "School", ics_url: @secret_url})

    refute inspect(changeset) =~ "private-abc123"
    assert inspect(changeset) =~ "**redacted**"
  end

  test "kid_id is optional: nil means family calendar" do
    changeset = Calendar.changeset(%Calendar{}, %{label: "Family", ics_url: @secret_url})

    assert changeset.valid?
  end

  test "label and ics_url are required" do
    changeset = Calendar.changeset(%Calendar{}, %{})

    assert %{label: ["can't be blank"], ics_url: ["can't be blank"]} = errors_on(changeset)
  end

  test "a calendar row persists with a payload cache" do
    assert {:ok, calendar} =
             %Calendar{}
             |> Calendar.changeset(%{label: "School", ics_url: @secret_url})
             |> Repo.insert()

    assert {:ok, _} =
             calendar
             |> Ecto.Changeset.change(
               last_payload: "BEGIN:VCALENDAR\nEND:VCALENDAR",
               last_fetched_at: ~U[2026-07-10 14:30:00Z]
             )
             |> Repo.update()
  end
end
