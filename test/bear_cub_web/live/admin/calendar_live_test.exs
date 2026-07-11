defmodule BearCubWeb.Admin.CalendarLiveTest do
  use BearCubWeb.ConnCase

  import Phoenix.LiveViewTest
  import BearCub.CalendarsFixtures
  import BearCub.ChoresFixtures

  alias BearCub.Calendars

  setup do
    %{kid: kid_fixture(%{name: "Kid A", color: "#f59e0b", position: 0})}
  end

  describe "index" do
    test "lists family and kid-owned calendars with edit links", %{conn: conn, kid: kid} do
      family = calendar_fixture(%{label: "Family Events"})
      kids_cal = calendar_fixture(%{label: "School", kid_id: kid.id})

      {:ok, view, _html} = live(conn, ~p"/admin/calendars")

      assert has_element?(view, "#admin-calendar-#{family.id}", "Family Events")
      assert has_element?(view, "#admin-calendar-#{family.id}", "Family")
      assert has_element?(view, "#admin-calendar-#{kids_cal.id}", "School")
      assert has_element?(view, "#admin-calendar-#{kids_cal.id}", "Kid A")
      assert has_element?(view, "#edit-calendar-#{family.id}")
    end

    test "the ICS URL never appears in the rendered page", %{conn: conn} do
      secret = "https://calendar.google.com/calendar/ical/private-abc123/basic.ics"
      calendar_fixture(%{label: "Family Events", ics_url: secret})

      {:ok, _view, html} = live(conn, ~p"/admin/calendars")

      refute html =~ "private-abc123"
    end

    test "a calendar created elsewhere appears without refresh", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/calendars")

      {:ok, calendar} = Calendars.create_calendar(%{label: "New One", ics_url: "https://x/y.ics"})

      assert has_element?(view, "#admin-calendar-#{calendar.id}", "New One")
    end
  end

  describe "form" do
    test "creates a family calendar", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/calendars/new")

      view
      |> form("#calendar-form", calendar: %{label: "Family Events", ics_url: "https://x/y.ics"})
      |> render_submit()

      assert_redirect(view, ~p"/admin/calendars")

      assert [calendar] = Calendars.list_calendars()
      assert calendar.label == "Family Events"
      assert calendar.kid_id == nil
    end

    test "creates a calendar assigned to a kid", %{conn: conn, kid: kid} do
      {:ok, view, _html} = live(conn, ~p"/admin/calendars/new")

      view
      |> form("#calendar-form",
        calendar: %{label: "School", ics_url: "https://x/y.ics", kid_id: kid.id}
      )
      |> render_submit()

      assert_redirect(view, ~p"/admin/calendars")

      assert [calendar] = Calendars.list_calendars()
      assert calendar.kid_id == kid.id
    end

    test "shows validation errors without saving", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/calendars/new")

      html =
        view
        |> form("#calendar-form", calendar: %{label: "", ics_url: ""})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert Calendars.list_calendars() == []
    end

    test "edits a calendar's label and URL", %{conn: conn} do
      calendar = calendar_fixture(%{label: "Old Label"})

      {:ok, view, _html} = live(conn, ~p"/admin/calendars/#{calendar.id}/edit")

      view
      |> form("#calendar-form", calendar: %{label: "New Label", ics_url: "https://new/url.ics"})
      |> render_submit()

      assert_redirect(view, ~p"/admin/calendars")

      updated = Calendars.get_calendar!(calendar.id)
      assert updated.label == "New Label"
      assert updated.ics_url == "https://new/url.ics"
    end

    test "reassigning from a kid to family clears kid_id", %{conn: conn, kid: kid} do
      calendar = calendar_fixture(%{label: "School", kid_id: kid.id})

      {:ok, view, _html} = live(conn, ~p"/admin/calendars/#{calendar.id}/edit")

      view
      |> form("#calendar-form", calendar: %{kid_id: ""})
      |> render_submit()

      assert_redirect(view, ~p"/admin/calendars")
      assert Calendars.get_calendar!(calendar.id).kid_id == nil
    end

    test "deletes a calendar from the edit form", %{conn: conn} do
      calendar = calendar_fixture()

      {:ok, view, _html} = live(conn, ~p"/admin/calendars/#{calendar.id}/edit")

      view |> element("#delete-calendar") |> render_click()

      assert_redirect(view, ~p"/admin/calendars")
      assert Calendars.list_calendars() == []
    end
  end
end
