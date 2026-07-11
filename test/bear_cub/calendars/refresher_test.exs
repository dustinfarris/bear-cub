defmodule BearCub.Calendars.RefresherTest do
  use BearCub.DataCase

  alias BearCub.Calendars
  alias BearCub.Calendars.Refresher
  alias BearCub.LocalTime

  import BearCub.CalendarsFixtures

  # The Refresher fetches from its own GenServer process, not the test
  # process, so its stub must be reachable from any pid (safe here since
  # DataCase tests already run synchronously, never concurrently — D24).
  setup context do
    Req.Test.set_req_test_to_shared(context)
    :ok
  end

  defp today, do: LocalTime.now() |> DateTime.to_date()

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

  defp format_utc(%DateTime{} = dt) do
    dt
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.to_naive()
    |> NaiveDateTime.to_iso8601()
    |> String.replace(["-", ":"], "")
    |> Kernel.<>("Z")
  end

  test "boot hydrates cached events immediately, even when the boot-time fetch fails (FR-20 WAN-down)" do
    calendar = calendar_fixture()

    cached_ics =
      ics_with_event(
        "cached-evt",
        DateTime.new!(today(), ~T[09:00:00], LocalTime.timezone()),
        DateTime.new!(today(), ~T[10:00:00], LocalTime.timezone())
      )

    {:ok, calendar} = Calendars.update_calendar_cache(calendar, %{last_payload: cached_ics})

    Req.Test.stub(Refresher, fn conn -> Plug.Conn.send_resp(conn, 503, "down") end)

    start_supervised!(Refresher)

    assert [%{uid: "cached-evt"}] = Calendars.today_events(calendar.kid_id, today())
    assert Calendars.get_calendar!(calendar.id).last_error
  end

  test "boot performs an initial live fetch and stores its events" do
    calendar = calendar_fixture()

    ics =
      ics_with_event(
        "live-evt",
        DateTime.new!(today(), ~T[09:00:00], LocalTime.timezone()),
        DateTime.new!(today(), ~T[10:00:00], LocalTime.timezone())
      )

    Req.Test.stub(Refresher, fn conn -> Plug.Conn.send_resp(conn, 200, ics) end)

    start_supervised!(Refresher)

    assert [%{uid: "live-evt"}] = Calendars.today_events(calendar.kid_id, today())
    assert Calendars.get_calendar!(calendar.id).last_fetched_at
  end

  test "handling :refresh re-fetches every calendar and picks up new events" do
    calendar = calendar_fixture()
    tz = LocalTime.timezone()

    first_ics =
      ics_with_event(
        "first",
        DateTime.new!(today(), ~T[09:00:00], tz),
        DateTime.new!(today(), ~T[10:00:00], tz)
      )

    Req.Test.stub(Refresher, fn conn -> Plug.Conn.send_resp(conn, 200, first_ics) end)

    pid = start_supervised!(Refresher)
    assert [%{uid: "first"}] = Calendars.today_events(calendar.kid_id, today())

    second_ics =
      ics_with_event(
        "second",
        DateTime.new!(today(), ~T[09:00:00], tz),
        DateTime.new!(today(), ~T[10:00:00], tz)
      )

    Req.Test.stub(Refresher, fn conn -> Plug.Conn.send_resp(conn, 200, second_ics) end)

    send(pid, :refresh)
    _ = :sys.get_state(pid)

    assert [%{uid: "second"}] = Calendars.today_events(calendar.kid_id, today())
  end
end
