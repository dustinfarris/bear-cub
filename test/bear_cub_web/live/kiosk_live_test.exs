defmodule BearCubWeb.KioskLiveTest do
  use BearCubWeb.ConnCase

  import Phoenix.LiveViewTest
  import BearCub.ChoresFixtures
  import BearCub.CalendarsFixtures
  import BearCub.RewardsFixtures

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
      original_windows = Application.fetch_env!(:bear_cub, :routine_windows)
      on_exit(fn -> Application.put_env(:bear_cub, :routine_windows, original_windows) end)
      morning_active()

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

    test "chore cards render at a fixed height instead of equally filling the column",
         %{conn: conn, kid_a: kid_a} do
      original_windows = Application.fetch_env!(:bear_cub, :routine_windows)
      on_exit(fn -> Application.put_env(:bear_cub, :routine_windows, original_windows) end)
      morning_active()

      chore_fixture(kid_a, %{
        name: "Brush Teeth",
        icon: "🪥",
        routine: Atom.to_string(auto_routine())
      })

      chore_fixture(kid_a, %{
        name: "Comb Hair",
        icon: "💇",
        routine: Atom.to_string(auto_routine())
      })

      {:ok, view, _html} = live(conn, ~p"/")
      html = render(view)

      # Row tracks are content-sized (docs/design-language.org): never an
      # equal-fill grid, and every pending row carries its fixed height.
      refute html =~ "auto-rows-fr"

      [chore_a, chore_b] = BearCub.Chores.list_chores(kid_a, auto_routine() |> Atom.to_string())
      assert has_element?(view, "#chore-#{chore_a.id}.h-24")
      assert has_element?(view, "#chore-#{chore_b.id}.h-24")
    end

    test "renders an events strip region per kid", %{conn: conn, kid_a: kid_a} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#events-#{kid_a.id}")
    end

    test "with no calendars configured, the events strip renders empty and chores still render",
         %{conn: conn, kid_a: kid_a} do
      original_windows = Application.fetch_env!(:bear_cub, :routine_windows)
      on_exit(fn -> Application.put_env(:bear_cub, :routine_windows, original_windows) end)
      morning_active()

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
      original_windows = Application.fetch_env!(:bear_cub, :routine_windows)
      on_exit(fn -> Application.put_env(:bear_cub, :routine_windows, original_windows) end)
      morning_active()

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
      original_windows = Application.fetch_env!(:bear_cub, :routine_windows)
      on_exit(fn -> Application.put_env(:bear_cub, :routine_windows, original_windows) end)
      # pinned rather than left to the real clock (tests must never inherit
      # the real clock — see docs/learnings.org), so the routine is always
      # in its active window no matter when the suite runs
      morning_active()

      kid = kid_fixture(%{name: "Kid A", color: "#f59e0b", position: 0})

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

    test "a completed chore row shrinks a little; undo restores full height",
         %{conn: conn, chore: chore} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#chore-#{chore.id}.h-24")
      refute has_element?(view, "#chore-#{chore.id}.h-20")

      view |> element("#chore-#{chore.id}") |> render_click()
      # the shrink lands once the row has settled out of its in-place beat
      send(view.pid, {:settled, chore.id})

      assert has_element?(view, "#chore-#{chore.id}.h-20")
      refute has_element?(view, "#chore-#{chore.id}.h-24")

      view |> element("#chore-#{chore.id}") |> render_click()

      assert has_element?(view, "#chore-#{chore.id}.h-24")
      refute has_element?(view, "#chore-#{chore.id}.h-20")
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

    test "an archived chore's card disappears live on the next :chores_changed broadcast (Story 03, D78)",
         %{conn: conn, chore: chore} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#chore-#{chore.id}")

      {:ok, _} = Chores.archive_chore(chore, LocalTime.now())

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
      test "the boundary handler drops into the night screen when the evening window closes (evening #{evening_state})",
           %{conn: conn, kid: kid, evening_chore: evening_chore} do
        now = LocalTime.now()
        time = DateTime.to_time(now)

        put_windows({~T[00:00:00], time}, {time, Time.add(time, 30, :second)})

        if unquote(evening_state) == :complete do
          Chores.complete_chore(evening_chore, now, "kiosk")
        end

        {:ok, view, _html} = live(conn, ~p"/")
        refute has_element?(view, "#night-screen")

        # completing the sole evening chore while its window is active
        # auto-collapses to the band (story 05); incomplete stays rows
        if unquote(evening_state) == :complete do
          assert has_element?(view, "#band-#{kid.id}")
        else
          assert has_element?(view, "#chores-#{kid.id}")
        end

        put_windows({~T[00:00:00], time}, {time, time})
        send(view.pid, :boundary)

        assert has_element?(view, "#night-screen")
        refute has_element?(view, "#chores-#{kid.id}")
      end
    end

    test "the night screen is a single dark screen with an evening-colored moon and nothing else (D56)",
         %{conn: conn, kid: kid} do
      now = LocalTime.now()
      time = DateTime.to_time(now)

      put_windows(
        {Time.add(time, 60, :second), Time.add(time, 90, :second)},
        {~T[00:00:00], time}
      )

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#night-screen .hero-moon-solid")
      assert has_element?(view, "#night-screen[style*='--routine-evening']")

      # nothing else: the per-kid columns — banner, points badge, events
      # strip, routine card — do not render at night (D56 supersedes D43's
      # unconditional badge visibility for this window)
      refute has_element?(view, "#kid-column-#{kid.id}")
      refute has_element?(view, "#points-badge-#{kid.id}")
      refute has_element?(view, "#events-#{kid.id}")
      refute has_element?(view, "#goodnight-#{kid.id}")
    end

    test "the night screen is not tap-expandable — no affordance to reveal rows",
         %{conn: conn, kid: _kid} do
      now = LocalTime.now()
      time = DateTime.to_time(now)

      put_windows(
        {Time.add(time, 60, :second), Time.add(time, 90, :second)},
        {~T[00:00:00], time}
      )

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#night-screen")
      refute has_element?(view, "#night-screen[phx-click]")
    end

    test "the boundary handler leaves the night screen and renders normal morning rows when the morning window opens",
         %{conn: conn, kid: kid, morning_chore: morning_chore} do
      now = LocalTime.now()
      time = DateTime.to_time(now)

      put_windows(
        {Time.add(time, 60, :second), Time.add(time, 90, :second)},
        {~T[00:00:00], time}
      )

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#night-screen")
      refute has_element?(view, "#chores-#{kid.id}")

      put_windows(
        {~T[00:00:00], Time.add(time, 90, :second)},
        {Time.add(time, 90, :second), Time.add(time, 120, :second)}
      )

      send(view.pid, :boundary)

      assert has_element?(view, "#chore-#{morning_chore.id}")
      refute has_element?(view, "#night-screen")
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

    test "an extra renders on the fixed neutral card surface, not the routine tint",
         %{conn: conn, kid: kid} do
      morning_active()
      now = LocalTime.now()

      chore = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})
      {:ok, _} = Chores.complete_chore(chore, now, "kiosk")
      extra = chore_fixture(kid, %{name: "Wash Car", icon: "🚗", routine: nil})

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(
               view,
               "#extras-#{kid.id} #chore-#{extra.id}[style*='var(--extra-card-background)']"
             )

      refute has_element?(
               view,
               "#extras-#{kid.id} #chore-#{extra.id}[style*='var(--routine-morning-tint)']"
             )
    end

    test "a recurring extra completed yesterday is present and tappable at today's reveal (Story 05, D82)",
         %{conn: conn, kid: kid} do
      morning_active()
      now = LocalTime.now()

      chore = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})
      {:ok, _} = Chores.complete_chore(chore, now, "kiosk")

      recurring =
        chore_fixture(kid, %{name: "Wash Car", icon: "🚗", shows_in: "extra_daily"})

      {:ok, _} = Chores.complete_chore(recurring, DateTime.add(now, -1, :day), "kiosk")

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#extras-#{kid.id} #chore-#{recurring.id}")
      refute has_element?(view, "#extras-#{kid.id} #chore-#{recurring.id}[data-done]")

      view |> element("#chore-#{recurring.id}") |> render_click()
      assert has_element?(view, "#chore-#{recurring.id}[data-done]")
    end

    test "an archived extra's card disappears live on the next :chores_changed broadcast",
         %{conn: conn, kid: kid} do
      morning_active()
      now = LocalTime.now()

      chore = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})
      {:ok, _} = Chores.complete_chore(chore, now, "kiosk")
      extra = chore_fixture(kid, %{name: "Wash Car", icon: "🚗", routine: nil})

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#extras-#{kid.id} #chore-#{extra.id}")

      {:ok, _} = Chores.archive_chore(extra, now)

      refute has_element?(view, "#extras-#{kid.id} #chore-#{extra.id}")
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
      refute has_element?(view, "#night-screen")
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

    test "tapping the completion icon expands to chore rows (tap-to-undo) and hides extras; undo returns to normal rows; re-complete auto-collapses (Story 08, D44, D47)",
         %{conn: conn, kid: kid} do
      morning_active()
      now = LocalTime.now()

      chore = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})
      {:ok, _} = Chores.complete_chore(chore, now, "kiosk")
      _extra = chore_fixture(kid, %{name: "Wash Car", icon: "🚗", routine: nil})

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#band-#{kid.id}")
      assert has_element?(view, "#completion-icon-#{kid.id}")

      view |> element("#completion-icon-#{kid.id}") |> render_click()

      refute has_element?(view, "#band-#{kid.id}")
      refute has_element?(view, "#extras-#{kid.id}")
      assert has_element?(view, "#chores-#{kid.id} #chore-#{chore.id}[data-done]")
      # the icon persists across the toggle — it's the affordance back too
      assert has_element?(view, "#completion-icon-#{kid.id}")

      view |> element("#completion-icon-#{kid.id}") |> render_click()

      assert has_element?(view, "#band-#{kid.id}")
      refute has_element?(view, "#chores-#{kid.id}")

      view |> element("#completion-icon-#{kid.id}") |> render_click()
      view |> element("#chore-#{chore.id}") |> render_click()

      refute has_element?(view, "#chore-#{chore.id}[data-done]")
      refute has_element?(view, "#band-#{kid.id}")
      refute has_element?(view, "#completion-icon-#{kid.id}")
      assert has_element?(view, "#chores-#{kid.id}")

      view |> element("#chore-#{chore.id}") |> render_click()

      # re-completing the last chore starts the collapse-delay (Story 07);
      # simulate the timer firing rather than sleeping in the test
      refute has_element?(view, "#band-#{kid.id}")
      send(view.pid, {:collapse_ready, kid.id})
      assert has_element?(view, "#band-#{kid.id}")
      assert has_element?(view, "#completion-icon-#{kid.id}")
    end
  end

  describe "standing band and ring (Story 05, D95, D97, D98)" do
    alias BearCub.Chores

    setup do
      kid = kid_fixture(%{name: "Kid A", color: "#f59e0b", position: 0})

      original_windows = Application.fetch_env!(:bear_cub, :routine_windows)
      on_exit(fn -> Application.put_env(:bear_cub, :routine_windows, original_windows) end)

      %{kid: kid}
    end

    test "a kid in good standing sees the band with thirteen stars and the column ring during the morning window",
         %{conn: conn, kid: kid} do
      morning_active()
      now = LocalTime.now()

      chore = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})
      {:ok, _} = Chores.complete_chore(chore, now, "kiosk")

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#standing-band-#{kid.id}")
      assert has_element?(view, "#kid-column-#{kid.id}.ring-success")

      document = LazyHTML.from_fragment(render(view))
      stars = LazyHTML.query(document, "#standing-band-#{kid.id} .hero-star-solid")
      assert Enum.count(stars) == 13
    end

    test "a kid not in good standing sees neither the band nor the ring",
         %{conn: conn, kid: kid} do
      morning_active()
      _chore = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})

      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#standing-band-#{kid.id}")
      refute has_element?(view, "#kid-column-#{kid.id}.ring-success")
    end

    test "the band and ring disappear when the evening window opens, even though the kid is in standing",
         %{conn: conn, kid: kid} do
      now = LocalTime.now()

      morning_chore = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})
      {:ok, _} = Chores.complete_chore(morning_chore, now, "kiosk")

      evening_chore = chore_fixture(kid, %{name: "Pajamas On", icon: "🌙", routine: "evening"})
      {:ok, _} = Chores.complete_chore(evening_chore, DateTime.add(now, -1, :day), "kiosk")

      evening_active()

      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#standing-band-#{kid.id}")
      refute has_element?(view, "#kid-column-#{kid.id}.ring-success")
    end

    test "the night screen shows no band or ring even when the kid is in standing",
         %{conn: conn, kid: kid} do
      now = LocalTime.now()
      time = DateTime.to_time(now)

      put_windows(
        {Time.add(time, 60, :second), Time.add(time, 90, :second)},
        {Time.add(time, 90, :second), Time.add(time, 120, :second)}
      )

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#night-screen")
      refute has_element?(view, "#standing-band-#{kid.id}")
      refute has_element?(view, "#kid-column-#{kid.id}")
    end

    test "the band and ring wait for the collapse delay, then appear together with the collapse",
         %{conn: conn, kid: kid} do
      morning_active()

      chore = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})

      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, "#standing-band-#{kid.id}")

      view |> element("#chore-#{chore.id}") |> render_click()

      refute has_element?(view, "#band-#{kid.id}")
      refute has_element?(view, "#standing-band-#{kid.id}")

      send(view.pid, {:collapse_ready, kid.id})

      assert has_element?(view, "#band-#{kid.id}")
      assert has_element?(view, "#standing-band-#{kid.id}")
      assert has_element?(view, "#kid-column-#{kid.id}.ring-success")
    end

    test "a kid with no morning chores configured sees the band and ring from the moment the morning window opens",
         %{conn: conn, kid: kid} do
      morning_active()

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#standing-band-#{kid.id}")
      assert has_element?(view, "#kid-column-#{kid.id}.ring-success")
    end

    test "the band and ring stay visible while the reward shop is open",
         %{conn: conn, kid: kid} do
      morning_active()
      now = LocalTime.now()

      chore = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})
      {:ok, _} = Chores.complete_chore(chore, now, "kiosk")

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#standing-band-#{kid.id}")

      view |> element("#gift-button-#{kid.id}") |> render_click()

      assert has_element?(view, "#rewards-#{kid.id}")
      assert has_element?(view, "#standing-band-#{kid.id}")
      assert has_element?(view, "#kid-column-#{kid.id}.ring-success")
    end
  end

  describe "completion icon (Story 08, D44, D47, D48)" do
    alias BearCub.Chores

    setup do
      kid = kid_fixture(%{name: "Kid A", color: "#f59e0b", position: 0})

      original_windows = Application.fetch_env!(:bear_cub, :routine_windows)
      on_exit(fn -> Application.put_env(:bear_cub, :routine_windows, original_windows) end)

      # These tests complete chores at the real `now` and assert a plain +R
      # badge; before 07:45 local that would be +R+E (D104). Pin the cutoff
      # to midnight so nothing here is ever early, whatever the clock says.
      original_cutoff = Application.fetch_env!(:bear_cub, :early_bird_cutoff)
      Application.put_env(:bear_cub, :early_bird_cutoff, ~T[00:00:00])
      on_exit(fn -> Application.put_env(:bear_cub, :early_bird_cutoff, original_cutoff) end)

      %{kid: kid}
    end

    test "no completion icon shows while the routine is incomplete — only name and points badge (AC1)",
         %{conn: conn, kid: kid} do
      morning_active()
      chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})

      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#completion-icon-#{kid.id}")
      refute has_element?(view, "#completion-badge-#{kid.id}")
      assert has_element?(view, "#kid-column-#{kid.id} h1", "Kid A")
      assert has_element?(view, "#points-badge-#{kid.id}")
    end

    test "the persistent routine header bar and its collapse-band twin are gone entirely (AC2, D48)",
         %{conn: conn, kid: kid} do
      morning_active()
      now = LocalTime.now()

      chore = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})

      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, "#routine-header-#{kid.id}")

      {:ok, _} = Chores.complete_chore(chore, now, "kiosk")
      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#routine-header-#{kid.id}")
      assert has_element?(view, "#band-#{kid.id}")
      refute has_element?(view, "#band-#{kid.id}", "Morning Routine")
      assert has_element?(view, "#band-#{kid.id}", BearCub.Messages.morning_complete())
    end

    test "shows a large sun icon with a green bonus badge for a complete morning routine",
         %{conn: conn, kid: kid} do
      morning_active()
      now = LocalTime.now()
      chore = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})
      {:ok, _} = Chores.complete_chore(chore, now, "kiosk")

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#completion-icon-#{kid.id} .hero-sun-solid")
      refute has_element?(view, "#completion-icon-#{kid.id} .hero-moon-solid")
      refute has_element?(view, "#completion-badge-#{kid.id} .hero-check")
      assert has_element?(view, "#completion-badge-#{kid.id}", "+#{Routines.bonus()}")
    end

    test "shows a large moon icon with a green bonus badge for a complete evening routine",
         %{conn: conn, kid: kid} do
      evening_active()
      now = LocalTime.now()
      chore = chore_fixture(kid, %{name: "Pajamas On", icon: "🌙", routine: "evening"})
      {:ok, _} = Chores.complete_chore(chore, now, "kiosk")

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#completion-icon-#{kid.id} .hero-moon-solid")
      refute has_element?(view, "#completion-icon-#{kid.id} .hero-sun-solid")
      refute has_element?(view, "#completion-badge-#{kid.id} .hero-check")
      assert has_element?(view, "#completion-badge-#{kid.id}", "+#{Routines.bonus()}")
    end

    test "the bonus badge shows the intact routine bonus when nothing failed (AC4, D47)",
         %{conn: conn, kid: kid} do
      morning_active()
      now = LocalTime.now()
      chore = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})
      {:ok, _} = Chores.complete_chore(chore, now, "kiosk")

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#completion-badge-#{kid.id}", "+#{Routines.bonus()}")
    end

    test "no bonus badge shows when the routine was completed via an in-window redo after a fail, though the icon still toggles (AC4, D45, D47)",
         %{conn: conn, kid: kid} do
      morning_active()
      now = LocalTime.now()
      chore = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})

      {:ok, _} = Chores.complete_chore(chore, now, "kiosk")
      {:ok, _} = Chores.fail_chore(chore, now)
      {:ok, _} = Chores.complete_chore(chore, now, "kiosk")

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#completion-icon-#{kid.id}")
      refute has_element?(view, "#completion-badge-#{kid.id}")
    end

    test "a fail on a different day does not forfeit today's bonus — the badge stays intact (D47 rejected alternative)",
         %{conn: conn, kid: kid} do
      morning_active()
      now = LocalTime.now()
      yesterday = DateTime.add(now, -1, :day)
      chore = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})

      {:ok, _} = Chores.complete_chore(chore, yesterday, "kiosk")
      {:ok, _} = Chores.fail_chore(chore, yesterday)
      {:ok, _} = Chores.complete_chore(chore, now, "kiosk")

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#completion-badge-#{kid.id}", "+#{Routines.bonus()}")
    end
  end

  describe "early bird (backlog 2026-09-06, D100, D101)" do
    alias BearCub.Chores

    setup do
      kid = kid_fixture(%{name: "Kid A", color: "#f59e0b", position: 0})

      original_windows = Application.fetch_env!(:bear_cub, :routine_windows)
      on_exit(fn -> Application.put_env(:bear_cub, :routine_windows, original_windows) end)

      %{kid: kid}
    end

    # A completion stamped at a chosen local wall-clock time today — the
    # kiosk renders against the real clock, but the early bird is decided
    # by `completed_at`, which the domain takes as an argument.
    defp today_at(time) do
      DateTime.new!(DateTime.to_date(LocalTime.now()), time, LocalTime.timezone())
    end

    test "a morning finished before the cutoff shows one combined +R+E badge on the sun and an EARLY pill",
         %{conn: conn, kid: kid} do
      morning_active()
      chore = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})
      {:ok, _} = Chores.complete_chore(chore, today_at(~T[07:00:00]), "kiosk")

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#completion-icon-#{kid.id} .hero-sun-solid")

      assert has_element?(
               view,
               "#completion-badge-#{kid.id}",
               "+#{Routines.bonus() + Routines.early_bird_bonus()}"
             )

      assert has_element?(view, "#completion-icon-#{kid.id} #early-bird-#{kid.id}", "EARLY")
      refute has_element?(view, "#completion-icon-#{kid.id} svg.sparrow")
      refute has_element?(view, "#early-bird-badge-#{kid.id}")
    end

    test "a morning finished after the cutoff shows the plain +R badge and no pill",
         %{conn: conn, kid: kid} do
      morning_active()
      chore = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})
      {:ok, _} = Chores.complete_chore(chore, today_at(~T[09:00:00]), "kiosk")

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#completion-badge-#{kid.id}", "+#{Routines.bonus()}")
      refute has_element?(view, "#early-bird-#{kid.id}")
    end

    test "a fail forfeits badge and pill together, even when the redo lands before the cutoff",
         %{conn: conn, kid: kid} do
      morning_active()
      chore = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})
      {:ok, _} = Chores.complete_chore(chore, today_at(~T[07:00:00]), "kiosk")
      {:ok, _} = Chores.fail_chore(chore, today_at(~T[07:10:00]))
      {:ok, _} = Chores.complete_chore(chore, today_at(~T[07:20:00]), "kiosk")

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#completion-icon-#{kid.id}")
      refute has_element?(view, "#completion-badge-#{kid.id}")
      refute has_element?(view, "#early-bird-#{kid.id}")
    end

    test "the evening moon never gets the pill, however early the taps", %{conn: conn, kid: kid} do
      evening_active()
      chore = chore_fixture(kid, %{name: "Pajamas On", icon: "🌙", routine: "evening"})
      {:ok, _} = Chores.complete_chore(chore, today_at(~T[07:00:00]), "kiosk")

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#completion-icon-#{kid.id} .hero-moon-solid")
      assert has_element?(view, "#completion-badge-#{kid.id}", "+#{Routines.bonus()}")
      refute has_element?(view, "#early-bird-#{kid.id}")
    end

    test "the points badge includes the early bird on top of the routine bonus",
         %{conn: conn, kid: kid} do
      morning_active()
      chore = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})
      {:ok, _} = Chores.complete_chore(chore, today_at(~T[07:00:00]), "kiosk")

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(
               view,
               "#points-badge-#{kid.id}",
               "#{Routines.bonus() + Routines.early_bird_bonus()}"
             )
    end
  end

  describe "collapse-delay before the routine list collapses (Story 07)" do
    setup do
      kid = kid_fixture(%{name: "Kid A", color: "#f59e0b", position: 0})

      original_windows = Application.fetch_env!(:bear_cub, :routine_windows)
      on_exit(fn -> Application.put_env(:bear_cub, :routine_windows, original_windows) end)

      %{kid: kid}
    end

    defp morning_active_delay do
      Application.put_env(:bear_cub, :routine_windows,
        morning: {~T[00:00:00], ~T[23:59:59]},
        evening: {~T[23:59:59], ~T[23:59:59]}
      )
    end

    test "completing the last routine chore keeps it visible in rows before the routine list collapses, then collapses once the delay elapses (AC1, AC2)",
         %{conn: conn, kid: kid} do
      morning_active_delay()

      chore = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#chores-#{kid.id}")

      view |> element("#chore-#{chore.id}") |> render_click()

      # the last chore's own completion is visible before the collapse
      assert has_element?(view, "#chore-#{chore.id}[data-done]")
      refute has_element?(view, "#band-#{kid.id}")

      send(view.pid, {:collapse_ready, kid.id})

      assert has_element?(view, "#band-#{kid.id}")
    end

    test "completing a chore that is not the last causes no delay — the routine stays in rows with no pending collapse (AC2)",
         %{conn: conn, kid: kid} do
      morning_active_delay()

      chore = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})
      _companion = chore_fixture(kid, %{name: "Comb Hair", icon: "💇", routine: "morning"})

      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#chore-#{chore.id}") |> render_click()

      assert has_element?(view, "#chore-#{chore.id}[data-done]")
      refute has_element?(view, "#band-#{kid.id}")

      # nothing was scheduled for a non-last completion — a stray message is a no-op
      send(view.pid, {:collapse_ready, kid.id})
      refute has_element?(view, "#band-#{kid.id}")
    end
  end

  describe "stake bar and sinking done rows (D105)" do
    alias BearCub.Chores

    setup do
      kid = kid_fixture(%{name: "Kid A", color: "#f59e0b", position: 0})

      original_windows = Application.fetch_env!(:bear_cub, :routine_windows)
      on_exit(fn -> Application.put_env(:bear_cub, :routine_windows, original_windows) end)

      morning_active()

      a = chore_fixture(kid, %{name: "Make Bed", icon: "🛏️", routine: "morning", position: 0})
      b = chore_fixture(kid, %{name: "Eat Breakfast", icon: "🥣", routine: "morning", position: 1})
      c = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning", position: 2})

      %{kid: kid, chores: [a, b, c]}
    end

    defp segments(view, kid) do
      document = LazyHTML.from_fragment(render(view))

      filled =
        LazyHTML.query(document, "#stake-bar-#{kid.id} [data-segment][data-filled]")
        |> Enum.count()

      total = LazyHTML.query(document, "#stake-bar-#{kid.id} [data-segment]") |> Enum.count()
      {filled, total}
    end

    defp row_ids(view, kid) do
      document = LazyHTML.from_fragment(render(view))

      LazyHTML.query(document, "#chores-#{kid.id} li[id^='chore-']")
      |> LazyHTML.attribute("id")
    end

    test "one segment per routine chore, filled as chores complete, with a single +R chip",
         %{conn: conn, kid: kid, chores: [a, _b, _c]} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert {0, 3} = segments(view, kid)
      assert has_element?(view, "#stake-chip-#{kid.id}", "+#{Routines.bonus()}")
      refute has_element?(view, "#stake-bar-#{kid.id}[data-paid]")

      view |> element("#chore-#{a.id}") |> render_click()

      assert {1, 3} = segments(view, kid)
      refute has_element?(view, "#stake-bar-#{kid.id}[data-paid]")
    end

    test "the stake bar enters the paid state when every chore is done, and stays through the band",
         %{conn: conn, kid: kid, chores: chores} do
      now = LocalTime.now()
      for chore <- chores, do: {:ok, _} = Chores.complete_chore(chore, now, "kiosk")

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#band-#{kid.id}")
      assert has_element?(view, "#stake-bar-#{kid.id}[data-paid]")
      assert {3, 3} = segments(view, kid)
      assert has_element?(view, "#stake-chip-#{kid.id}", "+#{Routines.bonus()}")
    end

    test "a forfeited routine keeps its segments but loses the chip, like the header badge (D47)",
         %{conn: conn, kid: kid, chores: [a, _b, _c]} do
      now = LocalTime.now()
      {:ok, _} = Chores.complete_chore(a, now, "kiosk")
      {:ok, _} = Chores.fail_chore(a, now)

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#stake-bar-#{kid.id}")
      assert has_element?(view, "#routine-penalty-#{kid.id}")
      refute has_element?(view, "#stake-chip-#{kid.id}")
    end

    test "the stake bar is absent from the reward shop and the night screen",
         %{conn: conn, kid: kid} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#stake-bar-#{kid.id}")

      view |> element("#gift-button-#{kid.id}") |> render_click()

      refute has_element?(view, "#stake-bar-#{kid.id}")
    end

    test "done rows sink below the pending ones, most recent completion first",
         %{conn: conn, kid: kid, chores: [a, b, c]} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert row_ids(view, kid) == ["chore-#{a.id}", "chore-#{b.id}", "chore-#{c.id}"]

      view |> element("#chore-#{a.id}") |> render_click()
      send(view.pid, {:settled, a.id})
      assert row_ids(view, kid) == ["chore-#{b.id}", "chore-#{c.id}", "chore-#{a.id}"]

      view |> element("#chore-#{b.id}") |> render_click()
      send(view.pid, {:settled, b.id})
      assert row_ids(view, kid) == ["chore-#{c.id}", "chore-#{b.id}", "chore-#{a.id}"]

      # undo floats the row back up into authored order among the pending
      view |> element("#chore-#{a.id}") |> render_click()
      assert row_ids(view, kid) == ["chore-#{a.id}", "chore-#{c.id}", "chore-#{b.id}"]
    end

    test "a just-tapped chore shows done in place for a beat, then sinks with its check springing in",
         %{conn: conn, kid: kid, chores: [a, b, c]} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#chore-#{a.id}") |> render_click()

      # done treatment, still in authored position, still slot-sized, not
      # yet animating anywhere
      assert has_element?(view, "#chore-#{a.id}[data-done]")
      assert has_element?(view, "#chore-#{a.id}.h-24")
      refute has_element?(view, "#chore-#{a.id}.animate-sink-grow")
      refute has_element?(view, "#chore-#{a.id} .animate-pop")
      refute has_element?(view, "#ghost-#{a.id}")
      assert row_ids(view, kid) == ["chore-#{a.id}", "chore-#{b.id}", "chore-#{c.id}"]

      send(view.pid, {:settled, a.id})

      assert has_element?(view, "#chore-#{a.id}[data-done]")
      assert has_element?(view, "#chore-#{a.id}.h-20.animate-sink-grow")
      assert has_element?(view, "#chore-#{a.id} #chore-check-#{a.id}.animate-pop")
      assert row_ids(view, kid) == ["chore-#{b.id}", "chore-#{c.id}", "chore-#{a.id}"]
    end

    test "an undo during the beat puts the slot back; the late settle message is a no-op",
         %{conn: conn, kid: kid, chores: [a, b, c]} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#chore-#{a.id}") |> render_click()
      view |> element("#chore-#{a.id}") |> render_click()

      # a plain slot again, no rise: the row never reached the done stack,
      # so there is nothing to collapse there and nothing to grow back here
      refute has_element?(view, "#chore-#{a.id}[data-done]")
      assert has_element?(view, "#chore-#{a.id}.border-dashed")
      refute has_element?(view, "#chore-#{a.id}.animate-sink-grow")
      refute has_element?(view, "#ghost-#{a.id}")

      send(view.pid, {:settled, a.id})

      refute has_element?(view, "#chore-#{a.id}[data-done]")
      refute has_element?(view, "#chore-#{a.id}.animate-sink-grow")
      refute has_element?(view, "#ghost-#{a.id}")
      assert row_ids(view, kid) == ["chore-#{a.id}", "chore-#{b.id}", "chore-#{c.id}"]
    end

    test "every chore row presses in under the finger", %{conn: conn, chores: [a, _b, _c]} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#chore-#{a.id}.active\\:scale-\\[0\\.97\\]")
    end

    test "a row that just sank grows open once, not on later renders",
         %{conn: conn, chores: [a, b, _c]} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#chore-#{a.id}") |> render_click()
      send(view.pid, {:settled, a.id})

      assert has_element?(view, "#chore-#{a.id}.animate-sink-grow")
      assert has_element?(view, "#chore-#{a.id} .animate-pop")

      # any later render — another broadcast, another tap — must not replay
      send(view.pid, :chores_changed)

      refute has_element?(view, "#chore-#{a.id}.animate-sink-grow")
      refute has_element?(view, "#chore-#{a.id} .animate-pop")

      view |> element("#chore-#{b.id}") |> render_click()
      send(view.pid, {:settled, b.id})

      assert has_element?(view, "#chore-#{b.id}.animate-sink-grow")
      refute has_element?(view, "#chore-#{a.id}.animate-sink-grow")
    end

    test "the vacated slot collapses as an inert ghost, in authored place, for that one render",
         %{conn: conn, kid: kid, chores: [a, b, c]} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#chore-#{b.id}") |> render_click()
      refute has_element?(view, "#ghost-#{b.id}")

      send(view.pid, {:settled, b.id})

      # ghost holds b's authored place among the pending rows; the real
      # row is at the top of the done stack beneath them
      document = LazyHTML.from_fragment(render(view))
      all_ids = LazyHTML.query(document, "#chores-#{kid.id} li") |> LazyHTML.attribute("id")
      assert all_ids == ["chore-#{a.id}", "ghost-#{b.id}", "chore-#{c.id}", "chore-#{b.id}"]

      assert has_element?(view, "#ghost-#{b.id}.animate-sink-collapse[data-done]")
      refute has_element?(view, "#ghost-#{b.id}[phx-click]")
      refute has_element?(view, "#ghost-#{b.id} .animate-pop")
      # one segment per real chore — the ghost is not a chore
      assert {1, 3} = segments(view, kid)

      view |> element("#chore-#{c.id}") |> render_click()

      refute has_element?(view, "#ghost-#{b.id}")
    end

    test "an undo rises the same way: a ghost collapses in the done stack while the row grows back into its slot",
         %{conn: conn, kid: kid, chores: [a, b, c]} do
      {:ok, view, _html} = live(conn, ~p"/")

      for chore <- [a, b] do
        view |> element("#chore-#{chore.id}") |> render_click()
        send(view.pid, {:settled, chore.id})
      end

      send(view.pid, :chores_changed)
      # done stack newest-first: b above a
      assert row_ids(view, kid) == ["chore-#{c.id}", "chore-#{b.id}", "chore-#{a.id}"]

      view |> element("#chore-#{a.id}") |> render_click()

      # the row is back in authored place, growing; its ghost holds the
      # old spot at the bottom of the done stack, collapsing in the done look
      document = LazyHTML.from_fragment(render(view))
      all_ids = LazyHTML.query(document, "#chores-#{kid.id} li") |> LazyHTML.attribute("id")

      assert all_ids == [
               "chore-#{a.id}",
               "chore-#{c.id}",
               "chore-#{b.id}",
               "ghost-#{a.id}"
             ]

      assert has_element?(view, "#chore-#{a.id}.border-dashed.animate-sink-grow")
      refute has_element?(view, "#chore-#{a.id} .animate-pop")
      assert has_element?(view, "#ghost-#{a.id}.h-20.animate-sink-collapse[data-done]")
      refute has_element?(view, "#ghost-#{a.id}[phx-click]")
      assert {1, 3} = segments(view, kid)

      # the write's own :chores_changed echo was already queued ahead of
      # the render above and carried the marker through; it is spent
      # there, so the next render of any kind drops both halves
      send(view.pid, :chores_changed)

      refute has_element?(view, "#chore-#{a.id}.animate-sink-grow")
      refute has_element?(view, "#ghost-#{a.id}")
    end

    test "an already-sunk row at page load does not grow — only a live sink animates",
         %{conn: conn, chores: [a, _b, _c]} do
      {:ok, _} = Chores.complete_chore(a, LocalTime.now(), "kiosk")

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#chore-#{a.id}[data-done]")
      refute has_element?(view, "#chore-#{a.id}.animate-sink-grow")
      refute has_element?(view, "#chore-#{a.id} .animate-pop")
    end

    test "a pending routine row is a dashed slot with no child-color border; a done row carries the circled check",
         %{conn: conn, kid: kid, chores: [a, _b, _c]} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#chore-#{a.id}.border-dashed")
      refute has_element?(view, "#chore-#{a.id}[style*='border-left-color']")
      refute has_element?(view, "#chore-#{a.id} .hero-check")

      view |> element("#chore-#{a.id}") |> render_click()

      refute has_element?(view, "#chore-#{a.id}.border-dashed")
      assert has_element?(view, "#chore-#{a.id} #chore-check-#{a.id} .hero-check")

      assert has_element?(
               view,
               "#chore-#{a.id} #chore-check-#{a.id}[style*='color: #{kid.color}']"
             )
    end

    test "the reward layer (name, points pill, bonus badge, stake chip) sets the reward font",
         %{conn: conn, kid: kid, chores: chores} do
      now = LocalTime.now()
      for chore <- chores, do: {:ok, _} = Chores.complete_chore(chore, now, "kiosk")

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#kid-column-#{kid.id} h1.font-reward", "Kid A")
      assert has_element?(view, "#points-badge-#{kid.id}.font-reward")
      assert has_element?(view, "#completion-badge-#{kid.id}.font-reward")
      assert has_element?(view, "#stake-chip-#{kid.id}.font-reward")
    end
  end

  describe "failed-chore marking (Story 06, D45, D46, D49)" do
    alias BearCub.Chores

    setup do
      kid = kid_fixture(%{name: "Kid A", color: "#f59e0b", position: 0})

      original_windows = Application.fetch_env!(:bear_cub, :routine_windows)
      on_exit(fn -> Application.put_env(:bear_cub, :routine_windows, original_windows) end)

      %{kid: kid}
    end

    test "a failed-and-not-redone routine chore shows a warning icon with no per-chore number (AC1, D46)",
         %{conn: conn, kid: kid} do
      morning_active()
      now = LocalTime.now()

      chore =
        chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning", points: 9})

      {:ok, _} = Chores.complete_chore(chore, now, "kiosk")
      {:ok, _} = Chores.fail_chore(chore, now)

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#chores-#{kid.id} #chore-#{chore.id} .hero-exclamation-triangle")
      refute has_element?(view, "#chore-#{chore.id} #chore-penalty-#{chore.id}")
      refute has_element?(view, "#chore-#{chore.id}", "9")
    end

    test "a single routine-penalty strip shows −R once, capped even with two failed chores (AC2, D45, D46)",
         %{conn: conn, kid: kid} do
      morning_active()
      now = LocalTime.now()

      a = chore_fixture(kid, %{name: "A", icon: "🅰️", routine: "morning"})
      b = chore_fixture(kid, %{name: "B", icon: "🅱️", routine: "morning"})
      {:ok, _} = Chores.complete_chore(a, now, "kiosk")
      {:ok, _} = Chores.fail_chore(a, now)
      {:ok, _} = Chores.complete_chore(b, now, "kiosk")
      {:ok, _} = Chores.fail_chore(b, now)

      {:ok, view, _html} = live(conn, ~p"/")

      strip = view |> element("#routine-penalty-#{kid.id}") |> render()
      assert strip =~ "−#{Routines.bonus()}"
      refute strip =~ "−#{2 * Routines.bonus()}"
    end

    test "no routine-penalty strip when nothing is failed", %{conn: conn, kid: kid} do
      morning_active()
      chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})

      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#routine-penalty-#{kid.id}")
    end

    test "a failed extra in the morning reveal shows a warning icon and its own −N (AC3, D46)",
         %{conn: conn, kid: kid} do
      morning_active()
      now = LocalTime.now()

      chore = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})
      {:ok, _} = Chores.complete_chore(chore, now, "kiosk")

      extra = chore_fixture(kid, %{name: "Wash Car", icon: "🚗", routine: nil, points: 12})
      {:ok, _} = Chores.complete_chore(extra, now, "kiosk")
      {:ok, _} = Chores.fail_chore(extra, now)

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#band-#{kid.id}")
      assert has_element?(view, "#extras-#{kid.id} #chore-#{extra.id} .hero-exclamation-triangle")
      assert has_element?(view, "#chore-penalty-#{extra.id}", "−12")
    end

    test "an outstanding (never-failed) extra shows no warning or penalty", %{
      conn: conn,
      kid: kid
    } do
      morning_active()
      now = LocalTime.now()

      chore = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})
      {:ok, _} = Chores.complete_chore(chore, now, "kiosk")
      extra = chore_fixture(kid, %{name: "Wash Car", icon: "🚗", routine: nil, points: 12})

      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#extras-#{kid.id} #chore-#{extra.id} .hero-exclamation-triangle")
      refute has_element?(view, "#chore-penalty-#{extra.id}")
    end

    test "while the window is active, a failed chore's row still renders and can be redone, clearing its warning and the penalty strip (AC4, D49)",
         %{conn: conn, kid: kid} do
      morning_active()
      now = LocalTime.now()

      chore = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})
      # a never-completed companion keeps the routine incomplete (:rows) after
      # the redo below, so we can observe the redone chore's row directly
      # instead of the routine auto-collapsing to the band
      _companion = chore_fixture(kid, %{name: "Comb Hair", icon: "💇", routine: "morning"})

      {:ok, _} = Chores.complete_chore(chore, now, "kiosk")
      {:ok, _} = Chores.fail_chore(chore, now)

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#routine-penalty-#{kid.id}")
      refute has_element?(view, "#chore-#{chore.id}[data-done]")
      assert has_element?(view, "#chore-#{chore.id} .hero-exclamation-triangle")

      view |> element("#chore-#{chore.id}") |> render_click()

      assert has_element?(view, "#chore-#{chore.id}[data-done]")
      refute has_element?(view, "#chore-#{chore.id} .hero-exclamation-triangle")
      refute has_element?(view, "#routine-penalty-#{kid.id}")
    end

    test "once Routines.current/2 moves past the window mid-session, a failed chore's row becomes unreachable — permanent loss (AC5, D49)",
         %{conn: conn, kid: kid} do
      now = LocalTime.now()
      time = DateTime.to_time(now)

      # morning active at mount (start <= now), evening not yet (ends at `time`)
      put_windows({time, Time.add(time, 30, :second)}, {~T[00:00:00], time})

      chore = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})
      {:ok, _} = Chores.complete_chore(chore, now, "kiosk")
      {:ok, _} = Chores.fail_chore(chore, now)

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#chore-#{chore.id}")
      assert has_element?(view, "#chore-#{chore.id} .hero-exclamation-triangle")
      assert has_element?(view, "#routine-penalty-#{kid.id}")

      # morning closes (zero-width); evening's window has already elapsed too
      put_windows({time, time}, {~T[00:00:00], time})
      send(view.pid, :boundary)

      assert has_element?(view, "#night-screen")
      refute has_element?(view, "#chore-#{chore.id}")
      refute has_element?(view, "#routine-penalty-#{kid.id}")
    end

    test "a failed extra returns to outstanding, stays visible in the reveal, and can be redone on a later day (AC6, D40, D49)",
         %{conn: conn, kid: kid} do
      morning_active()
      now = LocalTime.now()

      chore = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})
      {:ok, _} = Chores.complete_chore(chore, now, "kiosk")

      extra = chore_fixture(kid, %{name: "Wash Car", icon: "🚗", routine: nil, points: 8})
      {:ok, _} = Chores.complete_chore(extra, now, "kiosk")
      {:ok, _} = Chores.fail_chore(extra, now)

      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, "#chore-#{extra.id}[data-done]")
      assert has_element?(view, "#extras-#{kid.id} #chore-#{extra.id}")

      later = DateTime.add(now, 1, :day)
      assert {:ok, redone} = Chores.complete_chore(extra, later, "kiosk")
      assert redone.undone_at == nil
    end
  end

  describe "earned-value marking (Story 10, D54)" do
    alias BearCub.Chores

    setup do
      kid = kid_fixture(%{name: "Kid A", color: "#f59e0b", position: 0})

      original_windows = Application.fetch_env!(:bear_cub, :routine_windows)
      on_exit(fn -> Application.put_env(:bear_cub, :routine_windows, original_windows) end)

      %{kid: kid}
    end

    test "a completed extra in the morning reveal shows a green +N chip (AC1, D54)",
         %{conn: conn, kid: kid} do
      morning_active()
      now = LocalTime.now()

      chore = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})
      {:ok, _} = Chores.complete_chore(chore, now, "kiosk")

      extra = chore_fixture(kid, %{name: "Wash Car", icon: "🚗", routine: nil, points: 12})
      {:ok, _} = Chores.complete_chore(extra, now, "kiosk")

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#band-#{kid.id}")
      assert has_element?(view, "#chore-earned-#{extra.id}", "+12")
    end

    test "an outstanding extra shows no +N chip; a failed extra shows the −N warning instead, never both (AC2, D46, D54)",
         %{conn: conn, kid: kid} do
      morning_active()
      now = LocalTime.now()

      chore = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})
      {:ok, _} = Chores.complete_chore(chore, now, "kiosk")

      outstanding = chore_fixture(kid, %{name: "Wash Car", icon: "🚗", routine: nil, points: 12})

      failed = chore_fixture(kid, %{name: "Rake Leaves", icon: "🍂", routine: nil, points: 7})
      {:ok, _} = Chores.complete_chore(failed, now, "kiosk")
      {:ok, _} = Chores.fail_chore(failed, now)

      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#chore-earned-#{outstanding.id}")
      refute has_element?(view, "#chore-earned-#{failed.id}")
      assert has_element?(view, "#chore-penalty-#{failed.id}", "−7")
    end

    test "a completed routine chore shows no per-chore chip (AC3, D45, D54)",
         %{conn: conn, kid: kid} do
      morning_active()
      now = LocalTime.now()

      chore =
        chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning", points: 9})

      _companion = chore_fixture(kid, %{name: "Comb Hair", icon: "💇", routine: "morning"})

      {:ok, _} = Chores.complete_chore(chore, now, "kiosk")

      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#chore-#{chore.id} #chore-earned-#{chore.id}")
      refute has_element?(view, "#chore-#{chore.id}", "9")
    end
  end

  describe "points badge (Story 03, D43)" do
    alias BearCub.Chores
    alias BearCub.Chores.Completion
    alias BearCub.Repo

    defp fail_completion(%Completion{} = completion, at) do
      completion
      |> Ecto.Changeset.change(undone_at: at, failed_at: at)
      |> Repo.update!()
    end

    setup do
      kid = kid_fixture(%{name: "Kid A", color: "#f59e0b", position: 0})
      %{kid: kid}
    end

    test "the banner shows a persistent points badge at zero before any completions",
         %{conn: conn, kid: kid} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#points-badge-#{kid.id}", "0")
    end

    test "the badge shows the kid's live points total derived from completions",
         %{conn: conn, kid: kid} do
      extra = chore_fixture(kid, %{name: "Wash Car", icon: "🚗", routine: nil, points: 12})
      {:ok, _} = Chores.complete_chore(extra, LocalTime.now(), "kiosk")

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#points-badge-#{kid.id}", "12")
    end

    test "the badge never shows a negative number — a below-zero signed total displays 0 (SC-4)",
         %{conn: conn, kid: kid} do
      extra = chore_fixture(kid, %{name: "Wash Car", icon: "🚗", routine: nil, points: 12})
      {:ok, completion} = Chores.complete_chore(extra, LocalTime.now(), "kiosk")
      fail_completion(completion, ~U[2026-07-16 15:00:00Z])

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#points-badge-#{kid.id}", "0")
    end

    test "a completion from another surface updates the badge on the existing re-fetch (FR-9)",
         %{conn: conn, kid: kid} do
      extra = chore_fixture(kid, %{name: "Wash Car", icon: "🚗", routine: nil, points: 12})

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#points-badge-#{kid.id}", "0")

      {:ok, _} = Chores.complete_chore(extra, LocalTime.now(), "kiosk")

      assert has_element?(view, "#points-badge-#{kid.id}", "12")
    end

    test "a redemption from admin updates the badge live, without a reload (Story 04 AC-8, D71)",
         %{conn: conn, kid: kid} do
      extra = chore_fixture(kid, %{name: "Wash Car", icon: "🚗", routine: nil, points: 50})
      {:ok, _} = Chores.complete_chore(extra, LocalTime.now(), "kiosk")
      reward = reward_fixture(nil, %{name: "Bike", icon: "🚲", points: 10})

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#points-badge-#{kid.id}", "50")

      {:ok, _} = BearCub.Rewards.direct_redeem(kid, reward, 50, LocalTime.now())

      assert has_element?(view, "#points-badge-#{kid.id}", "40")
    end

    test "the badge stays visible across rows, collapsed band, and re-expanded rows; the night screen replaces it entirely (D56)",
         %{conn: conn, kid: kid} do
      original_windows = Application.fetch_env!(:bear_cub, :routine_windows)
      on_exit(fn -> Application.put_env(:bear_cub, :routine_windows, original_windows) end)

      Application.put_env(:bear_cub, :routine_windows,
        morning: {~T[00:00:00], ~T[23:59:59]},
        evening: {~T[23:59:59], ~T[23:59:59]}
      )

      chore = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#chores-#{kid.id}")
      assert has_element?(view, "#points-badge-#{kid.id}")

      {:ok, _} = Chores.complete_chore(chore, LocalTime.now(), "kiosk")
      # collapse-delay (Story 07): still rows until the delay elapses
      refute has_element?(view, "#band-#{kid.id}")
      assert has_element?(view, "#points-badge-#{kid.id}")
      send(view.pid, {:collapse_ready, kid.id})
      assert has_element?(view, "#band-#{kid.id}")
      assert has_element?(view, "#points-badge-#{kid.id}")

      view |> element("#completion-icon-#{kid.id}") |> render_click()
      assert has_element?(view, "#chores-#{kid.id}")
      assert has_element?(view, "#points-badge-#{kid.id}")

      Application.put_env(:bear_cub, :routine_windows,
        morning: {~T[23:59:59], ~T[23:59:59]},
        evening: {~T[23:59:59], ~T[23:59:59]}
      )

      send(view.pid, :boundary)

      assert has_element?(view, "#night-screen")
      refute has_element?(view, "#points-badge-#{kid.id}")
    end
  end

  describe "kiosk reward shop (Story 05/08, D65-D67, D75-D77)" do
    alias BearCub.Chores
    alias BearCub.Rewards

    setup do
      original_windows = Application.fetch_env!(:bear_cub, :routine_windows)
      on_exit(fn -> Application.put_env(:bear_cub, :routine_windows, original_windows) end)
      morning_active()

      kid_a = kid_fixture(%{name: "Kid A", color: "#f59e0b", position: 0})
      kid_b = kid_fixture(%{name: "Kid B", color: "#0ea5e9", position: 1})
      chore_fixture(kid_a, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})
      chore_fixture(kid_b, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})

      %{kid_a: kid_a, kid_b: kid_b}
    end

    defp earn(kid, points) do
      extra = chore_fixture(kid, %{name: "Wash Car", icon: "🚗", routine: nil, points: points})
      {:ok, _} = Chores.complete_chore(extra, LocalTime.now(), "kiosk")
      :ok
    end

    defp yesterday, do: DateTime.add(LocalTime.now(), -1, :day)

    test "AC-1: banner renders the gift button grouped beside the points badge; the badge's own tap stays unbound",
         %{conn: conn, kid_a: kid_a} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#gift-button-#{kid_a.id}")
      assert has_element?(view, "#points-badge-#{kid_a.id}")
      refute has_element?(view, "#points-badge-#{kid_a.id}[phx-click]")
    end

    test "AC-2: tapping the gift button swaps the column body to the reward catalog, keeping the banner and points badge",
         %{conn: conn, kid_a: kid_a} do
      reward = reward_fixture(nil, %{name: "Bike", icon: "🚲", points: 10})
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#gift-button-#{kid_a.id}") |> render_click()

      assert has_element?(view, "#rewards-#{kid_a.id}")
      assert has_element?(view, "#reward-card-#{reward.id}-#{kid_a.id}")
      assert has_element?(view, "#points-badge-#{kid_a.id}")
      refute has_element?(view, "#chores-#{kid_a.id}")
    end

    test "AC-3: the sibling's column is untouched and fully usable while one column is shopping",
         %{conn: conn, kid_a: kid_a, kid_b: kid_b} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#gift-button-#{kid_a.id}") |> render_click()

      assert has_element?(view, "#rewards-#{kid_a.id}")
      refute has_element?(view, "#rewards-#{kid_b.id}")
      assert has_element?(view, "#chores-#{kid_b.id}")

      chore_b = Chores.list_chores(kid_b, "morning") |> hd()
      view |> element("#chore-#{chore_b.id}") |> render_click()
      assert has_element?(view, "#chore-#{chore_b.id}[data-done]")
    end

    test "AC-3: a card's state is always evaluated for the kid whose column it is — a declined kid_a leaves the same shared reward available to kid_b",
         %{conn: conn, kid_a: kid_a, kid_b: kid_b} do
      reward = reward_fixture(nil, %{name: "Bike", points: 10})
      earn(kid_b, 10)

      {:ok, pending} = Rewards.request_redemption(kid_a, reward, LocalTime.now())
      {:ok, _} = Rewards.decline_redemption(pending, LocalTime.now())

      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#gift-button-#{kid_a.id}") |> render_click()
      assert has_element?(view, "#reward-card-#{reward.id}-#{kid_a.id}[data-card-state=declined]")

      view |> element("#gift-button-#{kid_b.id}") |> render_click()

      assert has_element?(
               view,
               "#reward-card-#{reward.id}-#{kid_b.id}[data-card-state=available]"
             )
    end

    test "AC-4: the gift button shows 🎁 idle, ⏳ once pending, and returns to 🎁 after a decline verdict",
         %{conn: conn, kid_a: kid_a} do
      reward = reward_fixture(nil, %{name: "Bike", icon: "🚲", points: 10})
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#gift-button-#{kid_a.id}", "🎁")

      {:ok, redemption} = Rewards.request_redemption(kid_a, reward, LocalTime.now())

      assert has_element?(view, "#gift-button-#{kid_a.id}", "⏳")

      {:ok, _} = Rewards.decline_redemption(redemption, LocalTime.now())

      assert has_element?(view, "#gift-button-#{kid_a.id}", "🎁")
    end

    test "AC-4: an approve verdict also returns the gift button to 🎁",
         %{conn: conn, kid_a: kid_a} do
      reward = reward_fixture(nil, %{name: "Bike", icon: "🚲", points: 10})
      {:ok, view, _html} = live(conn, ~p"/")

      {:ok, redemption} = Rewards.request_redemption(kid_a, reward, LocalTime.now())
      assert has_element?(view, "#gift-button-#{kid_a.id}", "⏳")

      {:ok, _} = Rewards.approve_redemption(redemption, 100, LocalTime.now())

      assert has_element?(view, "#gift-button-#{kid_a.id}", "🎁")
    end

    test "row 1 — a retired reward renders absent",
         %{conn: conn, kid_a: kid_a} do
      reward = reward_fixture(nil, %{name: "Bike", points: 10})
      {:ok, _} = Rewards.archive_reward(reward, LocalTime.now())
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#gift-button-#{kid_a.id}") |> render_click()

      refute has_element?(view, "#reward-card-#{reward.id}-#{kid_a.id}")
    end

    test "row 2 — a one-time reward consumed on an earlier day renders absent",
         %{conn: conn, kid_a: kid_a} do
      reward = reward_fixture(nil, %{name: "Bike", points: 10, repeatable: false})
      {:ok, _} = Rewards.direct_redeem(kid_a, reward, 100, yesterday())
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#gift-button-#{kid_a.id}") |> render_click()

      refute has_element?(view, "#reward-card-#{reward.id}-#{kid_a.id}")
    end

    test "row 3 — a pending request renders the pending glyph, tappable (its tap withdraws, D76), and is not dimmed like rows 4-6",
         %{conn: conn, kid_a: kid_a} do
      reward = reward_fixture(nil, %{name: "Bike", points: 10})
      {:ok, _} = Rewards.request_redemption(kid_a, reward, LocalTime.now())
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#gift-button-#{kid_a.id}") |> render_click()

      assert has_element?(view, "#reward-card-#{reward.id}-#{kid_a.id}[data-card-state=pending]")

      assert has_element?(
               view,
               "#reward-card-#{reward.id}-#{kid_a.id}[phx-click=withdraw-request]"
             )

      # the design scopes the shared dim treatment to rows 4-6 (declined,
      # claimed, locked) only — pending carries its own =⏳= treatment,
      # the same glyph the banner button already shows, never dimmed
      refute has_element?(view, "#reward-card-#{reward.id}-#{kid_a.id}.opacity-45")
    end

    test "row 4 — a declined request renders the declined glyph, untappable for the rest of the day (the re-ask block)",
         %{conn: conn, kid_a: kid_a} do
      reward = reward_fixture(nil, %{name: "Bike", points: 10})
      {:ok, pending} = Rewards.request_redemption(kid_a, reward, LocalTime.now())
      {:ok, _} = Rewards.decline_redemption(pending, LocalTime.now())
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#gift-button-#{kid_a.id}") |> render_click()

      assert has_element?(view, "#reward-card-#{reward.id}-#{kid_a.id}[data-card-state=declined]")
      refute has_element?(view, "#reward-card-#{reward.id}-#{kid_a.id}[phx-click]")
      assert has_element?(view, "#reward-card-#{reward.id}-#{kid_a.id}.opacity-45")
      # the declined ✕ carries color, not just glyph — an uncolored ✕
      # reads as a close control (design-language dim+glyph Ruling,
      # amended 2026-07-25)
      assert has_element?(
               view,
               "#reward-card-#{reward.id}-#{kid_a.id} .hero-x-mark.text-error"
             )
    end

    test "row 5 — a reward claimed today renders the claimed glyph, dimmed, untappable, and outranks unaffordable",
         %{conn: conn, kid_a: kid_a} do
      earn(kid_a, 10)
      reward = reward_fixture(nil, %{name: "Bike", points: 10, repeatable: true})
      {:ok, _} = Rewards.direct_redeem(kid_a, reward, 10, LocalTime.now())
      {:ok, view, _html} = live(conn, ~p"/")

      # balance has since dropped to 0 — below the price — but claimed still wins
      assert has_element?(view, "#points-badge-#{kid_a.id}", "0")

      view |> element("#gift-button-#{kid_a.id}") |> render_click()

      assert has_element?(view, "#reward-card-#{reward.id}-#{kid_a.id}[data-card-state=claimed]")
      refute has_element?(view, "#reward-card-#{reward.id}-#{kid_a.id}[phx-click]")
      assert has_element?(view, "#reward-card-#{reward.id}-#{kid_a.id}.opacity-45")
      # the claimed check carries the same success green a completed
      # extra's +N chip already carries
      assert has_element?(
               view,
               "#reward-card-#{reward.id}-#{kid_a.id} .hero-check.text-success"
             )
    end

    test "row 5 — a repeatable reward on cooldown yesterday is available again (not dimmed, not absent) today",
         %{conn: conn, kid_a: kid_a} do
      earn(kid_a, 20)
      reward = reward_fixture(nil, %{name: "Bike", points: 10, repeatable: true})
      {:ok, _} = Rewards.direct_redeem(kid_a, reward, 100, yesterday())
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#gift-button-#{kid_a.id}") |> render_click()

      # dimmed the day of the spend (proven by the test above), but never
      # hidden and never dimmed once the local day has rolled over
      assert has_element?(
               view,
               "#reward-card-#{reward.id}-#{kid_a.id}[data-card-state=available]"
             )

      refute has_element?(view, "#reward-card-#{reward.id}-#{kid_a.id}.opacity-45")
    end

    test "row 6 — an unaffordable reward renders the lock glyph, dimmed, untappable, with no negative number ever shown",
         %{conn: conn, kid_a: kid_a} do
      reward = reward_fixture(nil, %{name: "Bike", points: 10})
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#points-badge-#{kid_a.id}", "0")

      view |> element("#gift-button-#{kid_a.id}") |> render_click()

      assert has_element?(view, "#reward-card-#{reward.id}-#{kid_a.id}[data-card-state=locked]")
      refute has_element?(view, "#reward-card-#{reward.id}-#{kid_a.id}[phx-click]")
      assert has_element?(view, "#reward-card-#{reward.id}-#{kid_a.id}.opacity-45")
      # the lock glyph is the whole explanation (D63/D64) — the true
      # negative balance itself is never rendered, on this card or the badge
      refute render(view) =~ "−"
    end

    test "row 7 — an affordable reward renders full-color, not dimmed, and tappable",
         %{conn: conn, kid_a: kid_a} do
      earn(kid_a, 10)
      reward = reward_fixture(nil, %{name: "Bike", points: 10})
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#gift-button-#{kid_a.id}") |> render_click()

      refute has_element?(view, "#reward-card-#{reward.id}-#{kid_a.id}.opacity-45")

      assert has_element?(
               view,
               "#reward-card-#{reward.id}-#{kid_a.id}[data-card-state=available][phx-click][phx-throttle='1000']"
             )
    end

    test "AC-10 (D75, supersedes the shipped instant return): tapping an available card asks in one tap — no confirmation — the shop stays open and the tapped card turns pending in place",
         %{conn: conn, kid_a: kid_a} do
      earn(kid_a, 10)
      reward = reward_fixture(nil, %{name: "Bike", points: 10})
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#gift-button-#{kid_a.id}") |> render_click()
      view |> element("#reward-card-#{reward.id}-#{kid_a.id}") |> render_click()

      assert has_element?(view, "#rewards-#{kid_a.id}")
      refute has_element?(view, "#chores-#{kid_a.id}")
      assert has_element?(view, "#reward-card-#{reward.id}-#{kid_a.id}[data-card-state=pending]")
      assert has_element?(view, "#gift-button-#{kid_a.id}", "⏳")
      assert Rewards.any_pending?(kid_a.id, DateTime.to_date(LocalTime.now()))
    end

    test "AC-11 (D76, supersedes no-withdraw): a pending card's tap withdraws with no confirmation, returning to plain in the same render, shop still open",
         %{conn: conn, kid_a: kid_a} do
      earn(kid_a, 10)
      reward = reward_fixture(nil, %{name: "Bike", points: 10})
      {:ok, _} = Rewards.request_redemption(kid_a, reward, LocalTime.now())
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#gift-button-#{kid_a.id}") |> render_click()
      assert has_element?(view, "#reward-card-#{reward.id}-#{kid_a.id}[data-card-state=pending]")
      refute has_element?(view, "#reward-card-#{reward.id}-#{kid_a.id}[data-confirm]")

      view |> element("#reward-card-#{reward.id}-#{kid_a.id}") |> render_click()

      assert has_element?(view, "#rewards-#{kid_a.id}")

      assert has_element?(
               view,
               "#reward-card-#{reward.id}-#{kid_a.id}[data-card-state=available]"
             )

      refute Rewards.any_pending?(kid_a.id, DateTime.to_date(LocalTime.now()))
    end

    test "AC-12 (no longer driven through the gift button, which now closes the shop): the idle timer resets on an in-view request tap",
         %{conn: conn, kid_a: kid_a} do
      earn(kid_a, 10)
      reward = reward_fixture(nil, %{name: "Bike", points: 10})
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#gift-button-#{kid_a.id}") |> render_click()
      first_ref = :sys.get_state(view.pid).socket.assigns.rewards_timers[kid_a.id]
      assert first_ref

      view |> element("#reward-card-#{reward.id}-#{kid_a.id}") |> render_click()
      second_ref = :sys.get_state(view.pid).socket.assigns.rewards_timers[kid_a.id]

      assert second_ref
      refute second_ref == first_ref
      # the first timer was actually cancelled, not merely superseded —
      # a stray fire from it can't yank the column closed early
      assert Process.read_timer(first_ref) == false
    end

    test "AC-12: the idle timer resets on an in-view withdraw tap too",
         %{conn: conn, kid_a: kid_a} do
      reward = reward_fixture(nil, %{name: "Bike", points: 10})
      {:ok, _} = Rewards.request_redemption(kid_a, reward, LocalTime.now())
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#gift-button-#{kid_a.id}") |> render_click()
      first_ref = :sys.get_state(view.pid).socket.assigns.rewards_timers[kid_a.id]
      assert first_ref

      view |> element("#reward-card-#{reward.id}-#{kid_a.id}") |> render_click()
      second_ref = :sys.get_state(view.pid).socket.assigns.rewards_timers[kid_a.id]

      assert second_ref
      refute second_ref == first_ref
      assert Process.read_timer(first_ref) == false
    end

    test "AC-12a: an explicit dismiss control returns the column to its normal state",
         %{conn: conn, kid_a: kid_a} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#gift-button-#{kid_a.id}") |> render_click()
      assert has_element?(view, "#rewards-#{kid_a.id}")

      view |> element("#dismiss-shop-#{kid_a.id}") |> render_click()

      refute has_element?(view, "#rewards-#{kid_a.id}")
      assert has_element?(view, "#chores-#{kid_a.id}")
    end

    test "AC-12b: an idle timer returns the column to normal on its own if the kid wanders off",
         %{conn: conn, kid_a: kid_a} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#gift-button-#{kid_a.id}") |> render_click()
      assert has_element?(view, "#rewards-#{kid_a.id}")

      send(view.pid, {:rewards_idle, kid_a.id})

      refute has_element?(view, "#rewards-#{kid_a.id}")
      assert has_element?(view, "#chores-#{kid_a.id}")
    end

    test "AC-12c: dismissing cancels the idle timer — a stale idle message afterward is a harmless no-op",
         %{conn: conn, kid_a: kid_a} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#gift-button-#{kid_a.id}") |> render_click()
      view |> element("#dismiss-shop-#{kid_a.id}") |> render_click()

      send(view.pid, {:rewards_idle, kid_a.id})

      refute has_element?(view, "#rewards-#{kid_a.id}")
      assert has_element?(view, "#chores-#{kid_a.id}")
    end

    test "AC-13: :rewards membership is cleared by the routine boundary re-render",
         %{conn: conn, kid_a: kid_a} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#gift-button-#{kid_a.id}") |> render_click()
      assert has_element?(view, "#rewards-#{kid_a.id}")

      send(view.pid, :boundary)

      refute has_element?(view, "#rewards-#{kid_a.id}")
    end

    test "AC-14: at night the reward view is unreachable — no columns, no banner, no gift button — and a stray idle message is a harmless no-op",
         %{conn: conn, kid_a: _kid_a} do
      now = LocalTime.now()
      time = DateTime.to_time(now)

      put_windows(
        {Time.add(time, 60, :second), Time.add(time, 90, :second)},
        {~T[00:00:00], time}
      )

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#night-screen")
      refute render(view) =~ "gift-button"

      send(view.pid, {:rewards_idle, 999_999})

      assert has_element?(view, "#night-screen")
    end

    test "AC-15: the reward view contains no link or navigation to /admin",
         %{conn: conn, kid_a: kid_a} do
      reward = reward_fixture(nil, %{name: "Bike", points: 10})
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#gift-button-#{kid_a.id}") |> render_click()
      assert has_element?(view, "#reward-card-#{reward.id}-#{kid_a.id}")

      refute render(view) =~ "/admin"
    end

    test "the banner gift button toggles the shop closed on a second tap, whichever glyph it shows (D75)",
         %{conn: conn, kid_a: kid_a} do
      reward = reward_fixture(nil, %{name: "Bike", points: 10})
      {:ok, view, _html} = live(conn, ~p"/")

      # idle glyph (🎁): open, then close
      view |> element("#gift-button-#{kid_a.id}") |> render_click()
      assert has_element?(view, "#rewards-#{kid_a.id}")

      view |> element("#gift-button-#{kid_a.id}") |> render_click()
      refute has_element?(view, "#rewards-#{kid_a.id}")
      assert has_element?(view, "#chores-#{kid_a.id}")

      # pending glyph (⏳): open, then close — the toggle acts regardless
      # of which glyph the button is showing
      {:ok, _} = Rewards.request_redemption(kid_a, reward, LocalTime.now())
      view |> element("#gift-button-#{kid_a.id}") |> render_click()
      assert has_element?(view, "#gift-button-#{kid_a.id}", "⏳")
      assert has_element?(view, "#rewards-#{kid_a.id}")

      view |> element("#gift-button-#{kid_a.id}") |> render_click()
      refute has_element?(view, "#rewards-#{kid_a.id}")
      assert has_element?(view, "#chores-#{kid_a.id}")
      assert has_element?(view, "#gift-button-#{kid_a.id}", "⏳")
    end

    test "a kid may hold several pending requests at once, and the banner shows ⏳ until every one clears (D77)",
         %{conn: conn, kid_a: kid_a} do
      earn(kid_a, 20)
      reward_a = reward_fixture(nil, %{name: "Bike", points: 10})
      reward_b = reward_fixture(nil, %{name: "Scooter", points: 10})
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#gift-button-#{kid_a.id}") |> render_click()
      view |> element("#reward-card-#{reward_a.id}-#{kid_a.id}") |> render_click()
      view |> element("#reward-card-#{reward_b.id}-#{kid_a.id}") |> render_click()

      assert has_element?(
               view,
               "#reward-card-#{reward_a.id}-#{kid_a.id}[data-card-state=pending]"
             )

      assert has_element?(
               view,
               "#reward-card-#{reward_b.id}-#{kid_a.id}[data-card-state=pending]"
             )

      assert has_element?(view, "#gift-button-#{kid_a.id}", "⏳")

      # withdrawing one leaves the banner pending — the other is still open
      view |> element("#reward-card-#{reward_a.id}-#{kid_a.id}") |> render_click()
      assert has_element?(view, "#gift-button-#{kid_a.id}", "⏳")

      # withdrawing the last clears it
      view |> element("#reward-card-#{reward_b.id}-#{kid_a.id}") |> render_click()
      assert has_element?(view, "#gift-button-#{kid_a.id}", "🎁")
    end

    test "a pending ask locks a costlier sibling card the kid can no longer cover, and withdrawing unlocks it live (D77)",
         %{conn: conn, kid_a: kid_a} do
      earn(kid_a, 10)
      cheap = reward_fixture(nil, %{name: "Sticker", points: 10})
      costly = reward_fixture(nil, %{name: "Bike", points: 10})
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#gift-button-#{kid_a.id}") |> render_click()

      assert has_element?(
               view,
               "#reward-card-#{costly.id}-#{kid_a.id}[data-card-state=available]"
             )

      view |> element("#reward-card-#{cheap.id}-#{kid_a.id}") |> render_click()

      assert has_element?(view, "#reward-card-#{cheap.id}-#{kid_a.id}[data-card-state=pending]")
      assert has_element?(view, "#reward-card-#{costly.id}-#{kid_a.id}[data-card-state=locked]")
      # the lock stays the whole explanation — no committed/deficit figure shown
      refute render(view) =~ "−"

      view |> element("#reward-card-#{cheap.id}-#{kid_a.id}") |> render_click()

      assert has_element?(
               view,
               "#reward-card-#{cheap.id}-#{kid_a.id}[data-card-state=available]"
             )

      assert has_element?(
               view,
               "#reward-card-#{costly.id}-#{kid_a.id}[data-card-state=available]"
             )
    end
  end
end
