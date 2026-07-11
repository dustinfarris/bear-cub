defmodule BearCub.CalendarsTest do
  use BearCub.DataCase

  alias BearCub.Calendars
  alias BearCub.Calendars.Calendar

  import BearCub.CalendarsFixtures
  import BearCub.ChoresFixtures

  @invalid_attrs %{label: nil, ics_url: nil}

  test "list_calendars/0 returns all calendars" do
    calendar = calendar_fixture()
    assert Calendars.list_calendars() == [calendar]
  end

  test "get_calendar!/1 returns the calendar with given id" do
    calendar = calendar_fixture()
    assert Calendars.get_calendar!(calendar.id) == calendar
  end

  test "create_calendar/1 with valid data creates a family calendar (kid_id: nil)" do
    valid_attrs = %{label: "Family Events", ics_url: "https://example.com/family.ics"}

    assert {:ok, %Calendar{} = calendar} = Calendars.create_calendar(valid_attrs)
    assert calendar.label == "Family Events"
    assert calendar.ics_url == "https://example.com/family.ics"
    assert calendar.kid_id == nil
  end

  test "create_calendar/1 with a kid_id creates a kid-owned calendar" do
    kid = kid_fixture()
    valid_attrs = %{label: "School", ics_url: "https://example.com/school.ics", kid_id: kid.id}

    assert {:ok, %Calendar{} = calendar} = Calendars.create_calendar(valid_attrs)
    assert calendar.kid_id == kid.id
  end

  test "create_calendar/1 with invalid data returns error changeset" do
    assert {:error, %Ecto.Changeset{}} = Calendars.create_calendar(@invalid_attrs)
  end

  test "update_calendar/2 with valid data updates the calendar" do
    calendar = calendar_fixture()

    assert {:ok, %Calendar{} = calendar} =
             Calendars.update_calendar(calendar, %{label: "Renamed"})

    assert calendar.label == "Renamed"
  end

  test "update_calendar/2 with invalid data returns error changeset" do
    calendar = calendar_fixture()

    assert {:error, %Ecto.Changeset{}} = Calendars.update_calendar(calendar, @invalid_attrs)
    assert calendar == Calendars.get_calendar!(calendar.id)
  end

  test "delete_calendar/1 deletes the calendar" do
    calendar = calendar_fixture()

    assert {:ok, %Calendar{}} = Calendars.delete_calendar(calendar)
    assert_raise Ecto.NoResultsError, fn -> Calendars.get_calendar!(calendar.id) end
  end

  test "change_calendar/1 returns a calendar changeset" do
    calendar = calendar_fixture()
    assert %Ecto.Changeset{} = Calendars.change_calendar(calendar)
  end

  test "create_calendar/1 broadcasts :calendars_changed to subscribers" do
    Calendars.subscribe()
    {:ok, calendar} = Calendars.create_calendar(%{label: "School", ics_url: "https://x/y.ics"})

    assert_receive :calendars_changed
    assert Calendars.get_calendar!(calendar.id).label == "School"
  end
end
