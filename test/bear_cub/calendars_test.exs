defmodule BearCub.CalendarsTest do
  use BearCub.DataCase

  alias BearCub.Calendars
  alias BearCub.Calendars.Calendar
  alias BearCub.Calendars.Refresher

  import BearCub.CalendarsFixtures
  import BearCub.ChoresFixtures

  @invalid_attrs %{label: nil, ics_url: nil}

  @tz "America/Los_Angeles"
  defp la(date, time), do: DateTime.new!(date, time, @tz)

  defp ics_with_event(uid, starts_at, ends_at) do
    """
    BEGIN:VCALENDAR
    VERSION:2.0
    BEGIN:VEVENT
    UID:#{uid}
    DTSTART:#{format_utc(starts_at)}
    DTEND:#{format_utc(ends_at)}
    SUMMARY:Event #{uid}
    END:VEVENT
    END:VCALENDAR
    """
  end

  # A VEVENT missing DTSTART entirely: every recognized fixture in story-01
  # always has one, but a real-world feed quirk could omit it. ICS.parse
  # doesn't guard this case (nil dtstart_utc reaches DateTime.compare/2
  # during sort/overlap filtering) — a genuine raise the Refresher must
  # contain per-calendar (story Technical Notes).
  defp ics_missing_dtstart(uid) do
    """
    BEGIN:VCALENDAR
    VERSION:2.0
    BEGIN:VEVENT
    UID:#{uid}
    SUMMARY:Broken Event
    END:VEVENT
    END:VCALENDAR
    """
  end

  defp format_utc(%DateTime{} = dt) do
    dt
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.to_naive()
    |> NaiveDateTime.to_iso8601()
    |> String.replace(["-", ":"], "")
    |> Kernel.<>("Z")
  end

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

  describe "stale?/2" do
    test "true when the calendar has never been successfully fetched" do
      calendar = calendar_fixture()
      assert Calendars.stale?(calendar, la(~D[2026-07-11], ~T[12:00:00]))
    end

    test "false when fetched within the staleness threshold" do
      calendar = calendar_fixture()
      fetched_at = la(~D[2026-07-11], ~T[11:00:00]) |> DateTime.shift_zone!("Etc/UTC")
      {:ok, calendar} = Calendars.update_calendar_cache(calendar, %{last_fetched_at: fetched_at})

      refute Calendars.stale?(calendar, la(~D[2026-07-11], ~T[12:00:00]))
    end

    test "true once the staleness threshold (default 2h) has elapsed" do
      calendar = calendar_fixture()
      fetched_at = la(~D[2026-07-11], ~T[08:00:00]) |> DateTime.shift_zone!("Etc/UTC")
      {:ok, calendar} = Calendars.update_calendar_cache(calendar, %{last_fetched_at: fetched_at})

      assert Calendars.stale?(calendar, la(~D[2026-07-11], ~T[12:00:00]))
    end
  end

  describe "hydrate_cache/1" do
    test "loads a calendar's cached payload into the store without any network call" do
      calendar = calendar_fixture()
      now = la(~D[2026-07-11], ~T[12:00:00])

      ics =
        ics_with_event(
          "evt-1",
          la(~D[2026-07-11], ~T[09:00:00]),
          la(~D[2026-07-11], ~T[10:00:00])
        )

      {:ok, calendar} = Calendars.update_calendar_cache(calendar, %{last_payload: ics})

      Calendars.hydrate_cache(now)

      assert [%{uid: "evt-1"}] = Calendars.today_events(calendar.kid_id, ~D[2026-07-11])
    end

    test "calendars with no cached payload contribute nothing" do
      calendar_fixture()
      Calendars.hydrate_cache(la(~D[2026-07-11], ~T[12:00:00]))

      assert Calendars.today_events(nil, ~D[2026-07-11]) == []
    end
  end

  describe "refresh_calendar/2" do
    test "success stores parsed instances, updates the cache fields, and broadcasts on change" do
      calendar = calendar_fixture()
      now = la(~D[2026-07-11], ~T[12:00:00])

      ics =
        ics_with_event(
          "evt-1",
          la(~D[2026-07-11], ~T[09:00:00]),
          la(~D[2026-07-11], ~T[10:00:00])
        )

      Req.Test.stub(Refresher, fn conn -> Plug.Conn.send_resp(conn, 200, ics) end)

      Calendars.subscribe()
      assert {:ok, updated} = Calendars.refresh_calendar(calendar, now)

      assert updated.last_payload == ics
      assert updated.last_fetched_at
      assert updated.last_error == nil
      assert [%{uid: "evt-1"}] = Calendars.today_events(calendar.kid_id, ~D[2026-07-11])
      assert_receive :calendars_changed
    end

    test "success with unchanged events does not broadcast" do
      calendar = calendar_fixture()
      now = la(~D[2026-07-11], ~T[12:00:00])

      ics =
        ics_with_event(
          "evt-1",
          la(~D[2026-07-11], ~T[09:00:00]),
          la(~D[2026-07-11], ~T[10:00:00])
        )

      {:ok, calendar} = Calendars.update_calendar_cache(calendar, %{last_payload: ics})
      Calendars.hydrate_cache(now)

      Req.Test.stub(Refresher, fn conn -> Plug.Conn.send_resp(conn, 200, ics) end)

      Calendars.subscribe()
      Calendars.refresh_calendar(calendar, now)

      refute_receive :calendars_changed
    end

    test "failure keeps serving the previously cached events and records a last_error that never contains the ics_url" do
      calendar = calendar_fixture(ics_url: "https://example.com/secret-token-abc123.ics")
      now = la(~D[2026-07-11], ~T[12:00:00])

      ics =
        ics_with_event(
          "evt-1",
          la(~D[2026-07-11], ~T[09:00:00]),
          la(~D[2026-07-11], ~T[10:00:00])
        )

      {:ok, calendar} = Calendars.update_calendar_cache(calendar, %{last_payload: ics})
      Calendars.hydrate_cache(now)

      Req.Test.stub(Refresher, fn conn -> Plug.Conn.send_resp(conn, 503, "nope") end)

      Calendars.subscribe()
      assert {:ok, updated} = Calendars.refresh_calendar(calendar, now)

      assert updated.last_payload == ics
      assert updated.last_error
      refute updated.last_error =~ "secret-token-abc123"
      assert [%{uid: "evt-1"}] = Calendars.today_events(calendar.kid_id, ~D[2026-07-11])
      refute_receive :calendars_changed
    end

    test "a parse failure on a malformed feed is contained per-calendar and keeps serving the old cache" do
      calendar = calendar_fixture()
      now = la(~D[2026-07-11], ~T[12:00:00])

      good_ics =
        ics_with_event(
          "evt-1",
          la(~D[2026-07-11], ~T[09:00:00]),
          la(~D[2026-07-11], ~T[10:00:00])
        )

      {:ok, calendar} = Calendars.update_calendar_cache(calendar, %{last_payload: good_ics})
      Calendars.hydrate_cache(now)

      Req.Test.stub(Refresher, fn conn ->
        Plug.Conn.send_resp(conn, 200, ics_missing_dtstart("broken-evt"))
      end)

      assert {:ok, updated} = Calendars.refresh_calendar(calendar, now)

      assert updated.last_error
      assert [%{uid: "evt-1"}] = Calendars.today_events(calendar.kid_id, ~D[2026-07-11])
    end
  end

  describe "refresh_all/1" do
    test "one calendar's fetch failure does not stop the others from refreshing" do
      now = la(~D[2026-07-11], ~T[12:00:00])
      good = calendar_fixture(label: "Good", ics_url: "https://example.com/good.ics")
      bad = calendar_fixture(label: "Bad", ics_url: "https://example.com/bad.ics")

      good_ics =
        ics_with_event(
          "good-evt",
          la(~D[2026-07-11], ~T[09:00:00]),
          la(~D[2026-07-11], ~T[10:00:00])
        )

      Req.Test.stub(Refresher, fn conn ->
        case conn.request_path do
          "/good.ics" -> Plug.Conn.send_resp(conn, 200, good_ics)
          "/bad.ics" -> Plug.Conn.send_resp(conn, 500, "boom")
        end
      end)

      Calendars.refresh_all(now)

      assert [%{uid: "good-evt"}] = Calendars.today_events(good.kid_id, ~D[2026-07-11])
      assert Calendars.get_calendar!(bad.id).last_error
    end
  end

  describe "today_events/2" do
    test "blends a kid's own calendar with family calendars, sorted by start time, excluding other kids" do
      kid = kid_fixture()
      other_kid = kid_fixture()

      kid_calendar =
        calendar_fixture(kid_id: kid.id, label: "Kid", ics_url: "https://example.com/kid.ics")

      family_calendar =
        calendar_fixture(label: "Family", ics_url: "https://example.com/family.ics")

      other_calendar =
        calendar_fixture(
          kid_id: other_kid.id,
          label: "Other",
          ics_url: "https://example.com/other.ics"
        )

      now = la(~D[2026-07-11], ~T[12:00:00])

      kid_ics =
        ics_with_event(
          "kid-evt",
          la(~D[2026-07-11], ~T[10:00:00]),
          la(~D[2026-07-11], ~T[11:00:00])
        )

      family_ics =
        ics_with_event(
          "family-evt",
          la(~D[2026-07-11], ~T[08:00:00]),
          la(~D[2026-07-11], ~T[09:00:00])
        )

      other_ics =
        ics_with_event(
          "other-evt",
          la(~D[2026-07-11], ~T[07:00:00]),
          la(~D[2026-07-11], ~T[07:30:00])
        )

      {:ok, _} = Calendars.update_calendar_cache(kid_calendar, %{last_payload: kid_ics})
      {:ok, _} = Calendars.update_calendar_cache(family_calendar, %{last_payload: family_ics})
      {:ok, _} = Calendars.update_calendar_cache(other_calendar, %{last_payload: other_ics})

      Calendars.hydrate_cache(now)

      assert [%{uid: "family-evt"}, %{uid: "kid-evt"}] =
               Calendars.today_events(kid.id, ~D[2026-07-11])
    end

    test "excludes events that fall outside the given local day" do
      calendar = calendar_fixture()
      now = la(~D[2026-07-11], ~T[12:00:00])

      ics =
        ics_with_event(
          "yesterday-evt",
          la(~D[2026-07-10], ~T[10:00:00]),
          la(~D[2026-07-10], ~T[11:00:00])
        )

      {:ok, calendar} = Calendars.update_calendar_cache(calendar, %{last_payload: ics})
      Calendars.hydrate_cache(now)

      assert Calendars.today_events(calendar.kid_id, ~D[2026-07-11]) == []
    end
  end
end
