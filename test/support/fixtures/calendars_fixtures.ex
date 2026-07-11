defmodule BearCub.CalendarsFixtures do
  @moduledoc """
  Test helpers for creating entities via the `BearCub.Calendars` context.
  """

  alias BearCub.Calendars

  def calendar_fixture(attrs \\ %{}) do
    {:ok, calendar} =
      attrs
      |> Enum.into(%{
        label: "Some Calendar",
        ics_url: "https://calendar.google.com/calendar/ical/some-id/basic.ics"
      })
      |> Calendars.create_calendar()

    calendar
  end
end
