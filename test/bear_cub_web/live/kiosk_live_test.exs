defmodule BearCubWeb.KioskLiveTest do
  use BearCubWeb.ConnCase

  import Phoenix.LiveViewTest
  import BearCub.ChoresFixtures
  import BearCub.CalendarsFixtures

  alias BearCub.Calendars
  alias BearCub.LocalTime
  alias BearCub.Routines

  # Tests never mock the clock: expected outcomes are computed with the
  # same pure functions the LiveView uses, from the real current time.
  defp auto_routine do
    {_state, auto} = Routines.current(LocalTime.now())
    auto
  end

  # Events tests never mock the clock either — build ICS payloads relative
  # to the real current local day so they land in today's window no matter
  # when the suite runs.
  defp today, do: LocalTime.now() |> DateTime.to_date()
  defp tz, do: LocalTime.timezone()
  defp local(time), do: DateTime.new!(today(), time, tz())

  defp ics_with_event(uid, starts_at, ends_at, summary) do
    """
    BEGIN:VCALENDAR
    VERSION:2.0
    BEGIN:VEVENT
    UID:#{uid}
    DTSTART:#{format_utc(starts_at)}
    DTEND:#{format_utc(ends_at)}
    SUMMARY:#{summary}
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

  describe "with two kids" do
    setup do
      kid_a = kid_fixture(%{name: "Kid A", color: "#f59e0b", position: 0})
      kid_b = kid_fixture(%{name: "Kid B", color: "#0ea5e9", position: 1})
      %{kid_a: kid_a, kid_b: kid_b}
    end

    test "renders one column per kid, headed by name and identity color",
         %{conn: conn, kid_a: kid_a, kid_b: kid_b} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#kid-column-#{kid_a.id}", "Kid A")
      assert has_element?(view, "#kid-column-#{kid_b.id}", "Kid B")
      # identity color is painted as an inline style on the header band
      assert has_element?(
               view,
               "#kid-column-#{kid_a.id} header[style*='background-color: #f59e0b']"
             )

      assert has_element?(
               view,
               "#kid-column-#{kid_b.id} header[style*='background-color: #0ea5e9']"
             )
    end

    test "renders the shown routine's chores as icon + name rows",
         %{conn: conn, kid_a: kid_a} do
      chore =
        chore_fixture(kid_a, %{
          name: "Brush Teeth",
          icon: "🪥",
          routine: Atom.to_string(auto_routine()),
          position: 0
        })

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#chore-#{chore.id}", "Brush Teeth")
      assert has_element?(view, "#chore-#{chore.id}", "🪥")
    end

    test "renders an events strip region per kid", %{conn: conn, kid_a: kid_a} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#events-#{kid_a.id}")
    end

    test "with no calendars configured, the events strip renders empty and chores still render",
         %{conn: conn, kid_a: kid_a} do
      chore =
        chore_fixture(kid_a, %{
          name: "Brush Teeth",
          icon: "🪥",
          routine: Atom.to_string(auto_routine())
        })

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#events-#{kid_a.id}", "No events today")
      assert has_element?(view, "#chore-#{chore.id}")
    end

    test "renders a kid's personal event as a kid-color dot with its start time",
         %{conn: conn, kid_a: kid_a} do
      calendar =
        calendar_fixture(
          kid_id: kid_a.id,
          label: "Kid A",
          ics_url: "https://example.com/kid-a.ics"
        )

      ics = ics_with_event("evt-1", local(~T[09:00:00]), local(~T[10:00:00]), "Soccer Practice")
      {:ok, _} = Calendars.update_calendar_cache(calendar, %{last_payload: ics})
      Calendars.hydrate_cache(LocalTime.now())

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#event-#{kid_a.id}-evt-1", "Soccer Practice")

      assert has_element?(
               view,
               "#event-#{kid_a.id}-evt-1 [style*='background-color: #{kid_a.color}']"
             )
    end

    test "renders a family event as a neutral chip with a house glyph in both columns",
         %{conn: conn, kid_a: kid_a, kid_b: kid_b} do
      family_calendar =
        calendar_fixture(label: "Family", ics_url: "https://example.com/family.ics")

      ics = ics_with_event("family-evt", local(~T[08:00:00]), local(~T[08:30:00]), "Pickup")
      {:ok, _} = Calendars.update_calendar_cache(family_calendar, %{last_payload: ics})
      Calendars.hydrate_cache(LocalTime.now())

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#event-#{kid_a.id}-family-evt", "Pickup")
      assert has_element?(view, "#event-#{kid_a.id}-family-evt .hero-home")
      assert has_element?(view, "#event-#{kid_b.id}-family-evt", "Pickup")
      assert has_element?(view, "#event-#{kid_b.id}-family-evt .hero-home")
    end

    test "blends a kid's personal event with a family event in one chronological list",
         %{conn: conn, kid_a: kid_a} do
      kid_calendar =
        calendar_fixture(
          kid_id: kid_a.id,
          label: "Kid A",
          ics_url: "https://example.com/kid-a.ics"
        )

      family_calendar =
        calendar_fixture(label: "Family", ics_url: "https://example.com/family.ics")

      family_ics =
        ics_with_event("family-evt", local(~T[08:00:00]), local(~T[08:30:00]), "Pickup")

      kid_ics = ics_with_event("kid-evt", local(~T[10:00:00]), local(~T[11:00:00]), "Soccer")

      {:ok, _} = Calendars.update_calendar_cache(family_calendar, %{last_payload: family_ics})
      {:ok, _} = Calendars.update_calendar_cache(kid_calendar, %{last_payload: kid_ics})
      Calendars.hydrate_cache(LocalTime.now())

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#event-#{kid_a.id}-family-evt", "Pickup")
      assert has_element?(view, "#event-#{kid_a.id}-kid-evt", "Soccer")

      html = render(view)
      {family_index, _} = :binary.match(html, "Pickup")
      {kid_index, _} = :binary.match(html, "Soccer")
      assert family_index < kid_index
    end

    test "pins all-day events ahead of timed events regardless of start time",
         %{conn: conn, kid_a: kid_a} do
      calendar = calendar_fixture(kid_id: kid_a.id)
      date_str = Date.to_iso8601(today(), :basic)
      next_date_str = Date.to_iso8601(Date.add(today(), 1), :basic)

      ics = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:timed-evt
      DTSTART:#{format_utc(local(~T[07:00:00]))}
      DTEND:#{format_utc(local(~T[08:00:00]))}
      SUMMARY:Timed Thing
      END:VEVENT
      BEGIN:VEVENT
      UID:all-day-evt
      DTSTART;VALUE=DATE:#{date_str}
      DTEND;VALUE=DATE:#{next_date_str}
      SUMMARY:All Day Thing
      END:VEVENT
      END:VCALENDAR
      """

      {:ok, _} = Calendars.update_calendar_cache(calendar, %{last_payload: ics})
      Calendars.hydrate_cache(LocalTime.now())

      {:ok, view, _html} = live(conn, ~p"/")

      html = render(view)
      {all_day_index, _} = :binary.match(html, "All Day Thing")
      {timed_index, _} = :binary.match(html, "Timed Thing")
      assert all_day_index < timed_index
    end

    test "renders a midnight-spanning event clipped to today's portion",
         %{conn: conn, kid_a: kid_a} do
      calendar = calendar_fixture(kid_id: kid_a.id)
      yesterday = Date.add(today(), -1)
      starts_at = DateTime.new!(yesterday, ~T[20:00:00], tz())
      ends_at = local(~T[14:00:00])

      ics = ics_with_event("spans-midnight", starts_at, ends_at, "Sleepover")
      {:ok, _} = Calendars.update_calendar_cache(calendar, %{last_payload: ics})
      Calendars.hydrate_cache(LocalTime.now())

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#event-#{kid_a.id}-spans-midnight", "until 2:00 PM")
    end

    test "a calendar refresh that adds an event appears on the kiosk without a manual reload",
         %{conn: conn, kid_a: kid_a} do
      calendar = calendar_fixture(kid_id: kid_a.id)

      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, "#event-#{kid_a.id}-evt-1")

      ics = ics_with_event("evt-1", local(~T[09:00:00]), local(~T[10:00:00]), "New Event")
      {:ok, calendar} = Calendars.update_calendar_cache(calendar, %{last_payload: ics})
      Calendars.hydrate_cache(LocalTime.now())
      {:ok, _} = Calendars.update_calendar(calendar, %{label: calendar.label})

      assert has_element?(view, "#event-#{kid_a.id}-evt-1", "New Event")
    end

    test "the staleness clock glyph appears when a calendar is stale and clears once refreshed",
         %{conn: conn} do
      calendar = calendar_fixture()

      stale_fetched_at =
        LocalTime.now() |> DateTime.add(-3, :hour) |> DateTime.shift_zone!("Etc/UTC")

      {:ok, calendar} =
        Calendars.update_calendar_cache(calendar, %{last_fetched_at: stale_fetched_at})

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#calendar-stale-glyph")

      fresh_fetched_at = LocalTime.now() |> DateTime.shift_zone!("Etc/UTC")

      {:ok, calendar} =
        Calendars.update_calendar_cache(calendar, %{last_fetched_at: fresh_fetched_at})

      {:ok, _} = Calendars.update_calendar(calendar, %{label: calendar.label})

      refute has_element?(view, "#calendar-stale-glyph")
    end

    test "no staleness glyph when every calendar is fresh", %{conn: conn} do
      calendar = calendar_fixture()
      fresh_fetched_at = LocalTime.now() |> DateTime.shift_zone!("Etc/UTC")
      {:ok, _} = Calendars.update_calendar_cache(calendar, %{last_fetched_at: fresh_fetched_at})

      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#calendar-stale-glyph")
    end

    test "no staleness glyph when there are no calendars at all", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#calendar-stale-glyph")
    end

    test "renders fine with zero chores (production first boot)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#kiosk")
    end

    test "kiosk contains no links at all — Fully Kiosk's URL lock is the only fence",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "a")
    end

    test "no dimmed / opacity-40 rendering path remains anywhere in the kiosk",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "[data-dimmed]")
      refute has_element?(view, "#kiosk [class*='opacity-40']")
    end
  end

  describe "with no kids yet (fresh production database)" do
    test "renders the empty kiosk shell without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#kiosk")
      refute has_element?(view, "[id^='kid-column-']")
    end
  end

  describe "routine selection" do
    setup do
      kid = kid_fixture(%{name: "Kid A", color: "#f59e0b", position: 0})
      morning = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})
      evening = chore_fixture(kid, %{name: "Pajamas On", icon: "🌙", routine: "evening"})
      %{kid: kid, chores: %{morning: morning, evening: evening}}
    end

    test "shows the auto-selected routine's chores, never a manually flipped one",
         %{conn: conn, chores: chores} do
      auto = auto_routine()
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#chore-#{chores[auto].id}")
      refute has_element?(view, "#chore-#{chores[Routines.other(auto)].id}")
    end

    test "the kiosk has no flip control", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#routine-flip")
    end
  end

  describe "tap to complete and undo" do
    import Ecto.Query, only: [from: 2]

    alias BearCub.Chores
    alias BearCub.Chores.Completion
    alias BearCub.Repo

    setup do
      kid = kid_fixture(%{name: "Kid A", color: "#f59e0b", position: 0})

      # the chore lives in whichever routine the kiosk is showing right now,
      # so taps land on a visible row no matter when the suite runs
      chore =
        chore_fixture(kid, %{
          name: "Brush Teeth",
          icon: "🪥",
          routine: Atom.to_string(auto_routine())
        })

      # a companion chore that's never completed, so tapping `chore` never
      # completes the whole routine and auto-collapses it to a band
      # (story 05) — these tests are about single-row tap mechanics
      _companion =
        chore_fixture(kid, %{
          name: "Comb Hair",
          icon: "💇",
          routine: Atom.to_string(auto_routine())
        })

      %{kid: kid, chore: chore}
    end

    test "tapping a chore marks it done with the kid-color fill and a check (FR-7)",
         %{conn: conn, chore: chore} do
      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#chore-#{chore.id}[data-done]")

      view |> element("#chore-#{chore.id}") |> render_click()

      assert has_element?(view, "#chore-#{chore.id}[data-done]")
      assert has_element?(view, "#chore-#{chore.id}[style*='background-color: #f59e0b']")
      assert has_element?(view, "#chore-#{chore.id} .hero-check")
      assert has_element?(view, "#chore-#{chore.id}", "🪥")

      completion = Repo.one!(from c in Completion, where: c.chore_id == ^chore.id)
      assert completion.source == "kiosk"
      assert completion.local_date == DateTime.to_date(LocalTime.now())
      assert completion.undone_at == nil
    end

    test "tapping a done chore undoes it — no confirmation (FR-8)",
         %{conn: conn, chore: chore} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#chore-#{chore.id}") |> render_click()
      view |> element("#chore-#{chore.id}") |> render_click()

      refute has_element?(view, "#chore-#{chore.id}[data-done]")

      completion = Repo.one!(from c in Completion, where: c.chore_id == ^chore.id)
      refute is_nil(completion.undone_at)
    end

    test "complete → undo → complete: one current record, full history (FR-8 AC)",
         %{conn: conn, chore: chore} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#chore-#{chore.id}") |> render_click()
      view |> element("#chore-#{chore.id}") |> render_click()
      view |> element("#chore-#{chore.id}") |> render_click()

      assert has_element?(view, "#chore-#{chore.id}[data-done]")

      completions = Repo.all(from c in Completion, where: c.chore_id == ^chore.id)
      assert length(completions) == 2
      assert Enum.count(completions, &is_nil(&1.undone_at)) == 1
    end

    test "chore rows carry the 1s tap throttle (D15)", %{conn: conn, chore: chore} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#chore-#{chore.id}[phx-throttle='1000']")
    end

    test "a completion from another surface appears without refresh (FR-9)",
         %{conn: conn, chore: chore} do
      {:ok, view, _html} = live(conn, ~p"/")

      # stand-in for Phase 3's admin: any context write broadcasts
      {:ok, _} = Chores.complete_chore(chore, LocalTime.now(), "admin")

      assert has_element?(view, "#chore-#{chore.id}[data-done]")
    end

    test "a tap in one kiosk view updates another (FR-9)", %{conn: conn, chore: chore} do
      {:ok, view_a, _html} = live(conn, ~p"/")
      {:ok, view_b, _html} = live(Phoenix.ConnTest.build_conn(), ~p"/")

      view_a |> element("#chore-#{chore.id}") |> render_click()

      assert has_element?(view_b, "#chore-#{chore.id}[data-done]")
    end

    test "a tap racing an admin delete no-ops instead of crashing", %{conn: conn, chore: chore} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Delete behind the context's back (no broadcast), so the stale row
      # is still rendered when the tap arrives — the race window Phase 3's
      # admin deletes open up.
      Repo.delete!(chore)

      view |> element("#chore-#{chore.id}") |> render_click()

      refute has_element?(view, "#chore-#{chore.id}")
    end
  end

  describe "Good Night mode" do
    alias BearCub.Chores

    setup do
      kid = kid_fixture(%{name: "Kid A", color: "#f59e0b", position: 0})
      evening_chore = chore_fixture(kid, %{name: "Pajamas On", icon: "🌙", routine: "evening"})
      morning_chore = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})

      original_windows = Application.fetch_env!(:bear_cub, :routine_windows)
      on_exit(fn -> Application.put_env(:bear_cub, :routine_windows, original_windows) end)

      %{kid: kid, evening_chore: evening_chore, morning_chore: morning_chore}
    end

    # Windows are reconfigured relative to the real current time, never the
    # clock itself (design invariant: no clock mocking) — this lets a
    # boundary crossing be simulated deterministically between a mount and
    # a `:boundary` message, regardless of when the suite actually runs.
    defp put_windows(morning, evening) do
      Application.put_env(:bear_cub, :routine_windows, morning: morning, evening: evening)
    end

    for evening_state <- [:complete, :incomplete] do
      test "the boundary handler drops into Good Night mode when the evening window closes (evening #{evening_state})",
           %{conn: conn, kid: kid, evening_chore: evening_chore} do
        now = LocalTime.now()
        time = DateTime.to_time(now)

        put_windows({~T[00:00:00], time}, {time, Time.add(time, 30, :second)})

        if unquote(evening_state) == :complete do
          Chores.complete_chore(evening_chore, now, "kiosk")
        end

        {:ok, view, _html} = live(conn, ~p"/")
        refute has_element?(view, "#goodnight-#{kid.id}")

        # completing the sole evening chore while its window is active
        # auto-collapses to the band (story 05); incomplete stays rows
        if unquote(evening_state) == :complete do
          assert has_element?(view, "#band-#{kid.id}")
        else
          assert has_element?(view, "#chores-#{kid.id}")
        end

        put_windows({~T[00:00:00], time}, {time, time})
        send(view.pid, :boundary)

        assert has_element?(view, "#goodnight-#{kid.id}", BearCub.Messages.good_night())
        refute has_element?(view, "#chores-#{kid.id}")
      end
    end

    test "Good Night mode is not tap-expandable — no band affordance to reveal rows",
         %{conn: conn, kid: kid} do
      now = LocalTime.now()
      time = DateTime.to_time(now)

      put_windows(
        {Time.add(time, 60, :second), Time.add(time, 90, :second)},
        {~T[00:00:00], time}
      )

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#goodnight-#{kid.id}")
      refute has_element?(view, "#goodnight-#{kid.id}[phx-click]")
    end

    test "the boundary handler leaves Good Night mode and renders normal morning rows when the morning window opens",
         %{conn: conn, kid: kid, morning_chore: morning_chore} do
      now = LocalTime.now()
      time = DateTime.to_time(now)

      put_windows(
        {Time.add(time, 60, :second), Time.add(time, 90, :second)},
        {~T[00:00:00], time}
      )

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#goodnight-#{kid.id}", BearCub.Messages.good_night())
      refute has_element?(view, "#chores-#{kid.id}")

      put_windows(
        {~T[00:00:00], Time.add(time, 90, :second)},
        {Time.add(time, 90, :second), Time.add(time, 120, :second)}
      )

      send(view.pid, :boundary)

      assert has_element?(view, "#chore-#{morning_chore.id}")
      refute has_element?(view, "#goodnight-#{kid.id}")
    end
  end

  describe "collapse band, reveal gating, and extras reveal" do
    alias BearCub.Chores
    alias BearCub.Messages

    setup do
      kid = kid_fixture(%{name: "Kid A", color: "#f59e0b", position: 0})

      original_windows = Application.fetch_env!(:bear_cub, :routine_windows)
      on_exit(fn -> Application.put_env(:bear_cub, :routine_windows, original_windows) end)

      %{kid: kid}
    end

    # Pins morning active all day, evening never active — deterministic
    # regardless of when the suite runs, mirroring the Good Night helper.
    defp morning_active do
      Application.put_env(:bear_cub, :routine_windows,
        morning: {~T[00:00:00], ~T[23:59:59]},
        evening: {~T[23:59:59], ~T[23:59:59]}
      )
    end

    defp evening_active do
      Application.put_env(:bear_cub, :routine_windows,
        morning: {~T[23:59:59], ~T[23:59:59]},
        evening: {~T[00:00:00], ~T[23:59:59]}
      )
    end

    test "morning-complete-in-window collapses to a band with the message and reveals extras (outstanding + done-today), retired never appears",
         %{conn: conn, kid: kid} do
      morning_active()
      now = LocalTime.now()

      chore = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})
      {:ok, _} = Chores.complete_chore(chore, now, "kiosk")

      outstanding = chore_fixture(kid, %{name: "Wash Car", icon: "🚗", routine: nil})
      done_today = chore_fixture(kid, %{name: "Water Plants", icon: "🪴", routine: nil})
      {:ok, _} = Chores.complete_chore(done_today, now, "kiosk")
      retired = chore_fixture(kid, %{name: "Rake Leaves", icon: "🍂", routine: nil})
      {:ok, _} = Chores.complete_chore(retired, DateTime.add(now, -1, :day), "kiosk")

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#band-#{kid.id}", Messages.morning_complete())
      refute has_element?(view, "#chores-#{kid.id}")
      assert has_element?(view, "#extras-#{kid.id} #chore-#{outstanding.id}")
      refute has_element?(view, "#extras-#{kid.id} #chore-#{outstanding.id}[data-done]")
      assert has_element?(view, "#extras-#{kid.id} #chore-#{done_today.id}[data-done]")
      refute has_element?(view, "#chore-#{retired.id}")
    end

    test "the morning reveal appears even with zero extras", %{conn: conn, kid: kid} do
      morning_active()
      now = LocalTime.now()

      chore = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})
      {:ok, _} = Chores.complete_chore(chore, now, "kiosk")

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#band-#{kid.id}", Messages.morning_complete())
      assert has_element?(view, "#extras-#{kid.id}")
      refute has_element?(view, "#extras-#{kid.id} li[id]")
    end

    test "the same morning-complete state does not reveal when the morning window is not active (D33)",
         %{conn: conn, kid: kid} do
      evening_active()
      now = LocalTime.now()

      # a fully-completed morning routine — e.g. via an admin correction —
      # must never leak into the reveal while the evening window is what's
      # actually showing (the kiosk always shows one auto-selected routine).
      # An incomplete evening chore isolates this from the zero-chore guard.
      chore = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})
      {:ok, _} = Chores.complete_chore(chore, now, "kiosk")
      evening_chore = chore_fixture(kid, %{name: "Pajamas On", icon: "🌙", routine: "evening"})

      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#band-#{kid.id}")
      refute has_element?(view, "#extras-#{kid.id}")
      refute has_element?(view, "#chore-#{chore.id}")
      refute has_element?(view, "#chore-#{evening_chore.id}[data-done]")
      assert has_element?(view, "#chores-#{kid.id} #chore-#{evening_chore.id}")
    end

    test "evening-complete-in-window collapses to a band with the message and no extras",
         %{conn: conn, kid: kid} do
      evening_active()
      now = LocalTime.now()

      chore = chore_fixture(kid, %{name: "Pajamas On", icon: "🌙", routine: "evening"})
      {:ok, _} = Chores.complete_chore(chore, now, "kiosk")
      extra = chore_fixture(kid, %{name: "Wash Car", icon: "🚗", routine: nil})

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#band-#{kid.id}", Messages.evening_complete())
      refute has_element?(view, "#chores-#{kid.id}")
      refute has_element?(view, "#extras-#{kid.id}")
      refute has_element?(view, "#chore-#{extra.id}")
    end

    test "a routine with zero chores never collapses or reveals, even with extras assigned",
         %{conn: conn, kid: kid} do
      morning_active()
      extra = chore_fixture(kid, %{name: "Wash Car", icon: "🚗", routine: nil})

      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#band-#{kid.id}")
      refute has_element?(view, "#extras-#{kid.id}")
      refute has_element?(view, "#chore-#{extra.id}")
      assert has_element?(view, "#chores-#{kid.id}")
    end

    test "an empty evening column (zero evening chores) stays in its normal state when the evening window is active",
         %{conn: conn, kid: kid} do
      evening_active()

      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#band-#{kid.id}")
      refute has_element?(view, "#goodnight-#{kid.id}")
      assert has_element?(view, "#chores-#{kid.id}")
    end

    test "an outstanding extra in the reveal can be tapped to complete, and a done-today extra can be tapped to undo",
         %{conn: conn, kid: kid} do
      morning_active()
      now = LocalTime.now()

      chore = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})
      {:ok, _} = Chores.complete_chore(chore, now, "kiosk")
      extra = chore_fixture(kid, %{name: "Wash Car", icon: "🚗", routine: nil})

      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#chore-#{extra.id}[data-done]")
      view |> element("#chore-#{extra.id}") |> render_click()
      assert has_element?(view, "#chore-#{extra.id}[data-done]")

      view |> element("#chore-#{extra.id}") |> render_click()
      refute has_element?(view, "#chore-#{extra.id}[data-done]")
    end

    test "tapping the band re-expands to chore rows (tap-to-undo) and hides extras; undo returns to normal rows; re-complete auto-collapses",
         %{conn: conn, kid: kid} do
      morning_active()
      now = LocalTime.now()

      chore = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})
      {:ok, _} = Chores.complete_chore(chore, now, "kiosk")
      _extra = chore_fixture(kid, %{name: "Wash Car", icon: "🚗", routine: nil})

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#band-#{kid.id}")

      view |> element("#band-#{kid.id}") |> render_click()

      refute has_element?(view, "#band-#{kid.id}")
      refute has_element?(view, "#extras-#{kid.id}")
      assert has_element?(view, "#chores-#{kid.id} #chore-#{chore.id}[data-done]")

      view |> element("#chore-#{chore.id}") |> render_click()

      refute has_element?(view, "#chore-#{chore.id}[data-done]")
      refute has_element?(view, "#band-#{kid.id}")
      assert has_element?(view, "#chores-#{kid.id}")

      view |> element("#chore-#{chore.id}") |> render_click()

      assert has_element?(view, "#band-#{kid.id}")
    end
  end
end
