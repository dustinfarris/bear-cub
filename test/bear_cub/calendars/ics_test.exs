defmodule BearCub.Calendars.ICSTest do
  use ExUnit.Case, async: true

  alias BearCub.Calendars.ICS

  @fixtures_path Path.join([__DIR__, "..", "..", "support", "fixtures", "ics"])

  defp fixture(name) do
    @fixtures_path
    |> Path.join(name)
    |> File.read!()
  end

  # Window big enough to cover every fixture's dates without constraining
  # the RRULE/EXDATE/RECURRENCE-ID assertions themselves.
  @window_start ~U[2026-01-01 00:00:00Z]
  @window_end ~U[2026-12-31 23:59:59Z]

  describe "parse/3 with a plain timed event" do
    test "returns a single instance with the event's UTC start and end" do
      ics = fixture("timed_event.ics")

      assert {:ok, [instance]} = ICS.parse(ics, @window_start, @window_end)

      assert instance.uid == "fixture-timed-event-1@bearcub.example"
      assert instance.summary == "Placeholder Timed Event"
      assert instance.location == "Placeholder Location"
      assert instance.starts_at == ~U[2026-02-11 01:30:00Z]
      assert instance.ends_at == ~U[2026-02-11 02:30:00Z]
      refute instance.all_day
    end
  end

  describe "parse/3 with an all-day event" do
    test "returns a single all-day instance spanning the inclusive date range" do
      ics = fixture("all_day_event.ics")

      assert {:ok, [instance]} = ICS.parse(ics, @window_start, @window_end)

      assert instance.uid == "fixture-all-day-event-1@bearcub.example"
      assert instance.summary == "Placeholder All-Day Event"
      # DTEND on all-day events is exclusive per RFC 5545: 04-14 through 04-16.
      assert instance.starts_at == ~U[2026-04-14 00:00:00Z]
      assert instance.ends_at == ~U[2026-04-17 00:00:00Z]
      assert instance.all_day
    end
  end

  describe "parse/3 with an event spanning local midnight" do
    test "resolves the TZID wall-clock start/end into distinct UTC instants" do
      ics = fixture("midnight_spanning_event.ics")

      assert {:ok, [instance]} = ICS.parse(ics, @window_start, @window_end)

      assert instance.uid == "fixture-midnight-spanning-event-1@bearcub.example"
      # 2026-02-15 22:30 / 2026-02-16 00:30 America/Los_Angeles (PST, UTC-8)
      assert instance.starts_at == ~U[2026-02-16 06:30:00Z]
      assert instance.ends_at == ~U[2026-02-16 08:30:00Z]
      refute instance.all_day
    end
  end

  describe "parse/3 with an RRULE recurring event" do
    test "expands FREQ=WEEKLY;BYDAY into one instance per matching occurrence" do
      ics = fixture("recurring_event.ics")

      assert {:ok, instances} = ICS.parse(ics, @window_start, @window_end)

      assert Enum.map(instances, & &1.starts_at) == [
               ~U[2026-04-13 23:30:00Z],
               ~U[2026-04-15 23:30:00Z],
               ~U[2026-04-20 23:30:00Z]
             ]

      assert Enum.all?(instances, &(&1.uid == "fixture-recurring-event-1@bearcub.example"))
      assert Enum.all?(instances, &(&1.summary == "Placeholder Recurring Event"))

      assert Enum.map(instances, & &1.ends_at) == [
               ~U[2026-04-14 00:00:00Z],
               ~U[2026-04-16 00:00:00Z],
               ~U[2026-04-21 00:00:00Z]
             ]
    end
  end

  describe "parse/3 with a cancelled recurring instance (EXDATE)" do
    test "excludes the EXDATE occurrences but keeps the rest of the series" do
      ics = fixture("cancelled_instance_event.ics")

      assert {:ok, instances} = ICS.parse(ics, @window_start, @window_end)

      # Weekly from 2026-04-03 until 2026-05-28T23:59:59 local; 04-17 and
      # 05-22 are cancelled via EXDATE, and 05-29 falls after UNTIL.
      assert Enum.map(instances, & &1.starts_at) == [
               ~U[2026-04-04 01:30:00Z],
               ~U[2026-04-11 01:30:00Z],
               ~U[2026-04-25 01:30:00Z],
               ~U[2026-05-02 01:30:00Z],
               ~U[2026-05-09 01:30:00Z],
               ~U[2026-05-16 01:30:00Z]
             ]

      assert Enum.all?(
               instances,
               &(&1.uid == "fixture-cancelled-instance-event-1@bearcub.example")
             )
    end
  end

  describe "parse/3 with a moved/edited recurring instance (RECURRENCE-ID)" do
    test "replaces the original occurrence with the override's own time and summary" do
      ics = fixture("moved_instance_event.ics")

      assert {:ok, instances} = ICS.parse(ics, @window_start, @window_end)

      # Master: weekly from 2026-03-22 until 2026-03-29T23:00:00Z, so raw
      # occurrences are 03-22 and 03-29. The 03-22 occurrence is moved to
      # 03-24 by RECURRENCE-ID — the kiosk must never show both the
      # original (un-moved) 03-22 slot and the moved 03-24 event.
      assert [moved, unmoved] = instances

      assert moved.starts_at == ~U[2026-03-24 23:00:00Z]
      assert moved.ends_at == ~U[2026-03-25 00:00:00Z]
      assert moved.summary == "Placeholder Recurring Event (Rescheduled)"

      assert unmoved.starts_at == ~U[2026-03-29 23:00:00Z]
      assert unmoved.ends_at == ~U[2026-03-30 00:00:00Z]
      assert unmoved.summary == "Placeholder Recurring Event"

      # The un-moved original slot (03-22 16:00 local) must not also appear.
      refute Enum.any?(instances, &(&1.starts_at == ~U[2026-03-22 23:00:00Z]))

      assert Enum.all?(instances, &(&1.uid == "fixture-moved-instance-event-1@bearcub.example"))
    end
  end

  describe "parse/3 with a FREQ=MONTHLY recurring event (BYDAY ordinal-weekday)" do
    test "expands FREQ=MONTHLY;BYDAY=1TH into one instance per matching month, honoring EXDATE" do
      ics = fixture("monthly_recurring_event.ics")

      assert {:ok, instances} = ICS.parse(ics, @window_start, @window_end)

      # First Thursday of every month, Jan-Dec 2026; 05-07 and 07-02 are
      # excluded via EXDATE. Local wall time is 16:00-17:00
      # America/Los_Angeles, so UTC offset flips with DST (Mar/Nov).
      assert Enum.map(instances, & &1.starts_at) == [
               ~U[2026-01-02 00:00:00Z],
               ~U[2026-02-06 00:00:00Z],
               ~U[2026-03-06 00:00:00Z],
               ~U[2026-04-02 23:00:00Z],
               ~U[2026-06-04 23:00:00Z],
               ~U[2026-08-06 23:00:00Z],
               ~U[2026-09-03 23:00:00Z],
               ~U[2026-10-01 23:00:00Z],
               ~U[2026-11-06 00:00:00Z],
               ~U[2026-12-04 00:00:00Z]
             ]

      assert Enum.map(instances, & &1.ends_at) == [
               ~U[2026-01-02 01:00:00Z],
               ~U[2026-02-06 01:00:00Z],
               ~U[2026-03-06 01:00:00Z],
               ~U[2026-04-03 00:00:00Z],
               ~U[2026-06-05 00:00:00Z],
               ~U[2026-08-07 00:00:00Z],
               ~U[2026-09-04 00:00:00Z],
               ~U[2026-10-02 00:00:00Z],
               ~U[2026-11-06 01:00:00Z],
               ~U[2026-12-04 01:00:00Z]
             ]

      assert Enum.all?(
               instances,
               &(&1.uid == "fixture-monthly-recurring-event-1@bearcub.example")
             )
    end
  end

  describe "parse/3 with an unsupported FREQ (graceful degradation)" do
    test "does not raise for FREQ=YEARLY, an unimplemented recurrence shape" do
      ics = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      DTSTART;TZID=America/Los_Angeles:20260315T090000
      DTEND;TZID=America/Los_Angeles:20260315T100000
      RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU
      UID:fixture-unsupported-freq-event-1@bearcub.example
      SUMMARY:Placeholder Yearly Event
      LOCATION:Placeholder Location
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, instances} = ICS.parse(ics, @window_start, @window_end)
      assert instances == []
    end
  end

  describe "parse/3 with a bounded window" do
    test "excludes occurrences entirely outside [window_start, window_end]" do
      ics = fixture("recurring_event.ics")

      # Full series is 04-13/15/20 23:30Z (ending 04-14/16/21 00:00Z). This
      # window only overlaps the 04-15 occurrence.
      window_start = ~U[2026-04-14 00:00:01Z]
      window_end = ~U[2026-04-16 00:00:00Z]

      assert {:ok, [instance]} = ICS.parse(ics, window_start, window_end)
      assert instance.starts_at == ~U[2026-04-15 23:30:00Z]
      assert instance.ends_at == ~U[2026-04-16 00:00:00Z]
    end
  end
end
