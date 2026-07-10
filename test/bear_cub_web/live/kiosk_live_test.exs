defmodule BearCubWeb.KioskLiveTest do
  use BearCubWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import BearCub.ChoresFixtures

  alias BearCub.LocalTime
  alias BearCub.Routines

  # Tests never mock the clock: expected outcomes are computed with the
  # same pure functions the LiveView uses, from the real current time.
  defp auto_routine do
    {_state, auto} = Routines.current(LocalTime.now())
    auto
  end

  defp label(:morning), do: "Morning"
  defp label(:evening), do: "Evening"

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

    test "renders fine with zero chores (production first boot)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#kiosk")
    end

    test "kiosk contains no links at all — Fully Kiosk's URL lock is the only fence",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "a")
    end
  end

  describe "with no kids yet (fresh production database)" do
    test "renders the empty kiosk shell without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#kiosk")
      refute has_element?(view, "[id^='kid-column-']")
    end
  end

  describe "routine selection and flip" do
    setup do
      kid = kid_fixture(%{name: "Kid A", color: "#f59e0b", position: 0})
      morning = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})
      evening = chore_fixture(kid, %{name: "Pajamas On", icon: "🌙", routine: "evening"})
      %{kid: kid, chores: %{morning: morning, evening: evening}}
    end

    test "shows the time-appropriate routine with its name on the flip control",
         %{conn: conn, chores: chores} do
      auto = auto_routine()
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#routine-flip", label(auto))
      assert has_element?(view, "#chore-#{chores[auto].id}")
      refute has_element?(view, "#chore-#{chores[Routines.other(auto)].id}")
    end

    test "dims exactly when the shown routine is not active", %{conn: conn} do
      {state, _auto} = Routines.current(LocalTime.now())
      {:ok, view, _html} = live(conn, ~p"/")

      case state do
        :active -> refute has_element?(view, "#kiosk[data-dimmed]")
        :upcoming -> assert has_element?(view, "#kiosk[data-dimmed]")
      end
    end

    test "flip shows the other routine, dimmed; flip again returns",
         %{conn: conn, chores: chores} do
      auto = auto_routine()
      other = Routines.other(auto)
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#routine-flip") |> render_click()

      assert has_element?(view, "#routine-flip", label(other))
      assert has_element?(view, "#chore-#{chores[other].id}")
      refute has_element?(view, "#chore-#{chores[auto].id}")
      # a flipped-to routine is never the active one — always dimmed (design §5)
      assert has_element?(view, "#kiosk[data-dimmed]")

      view |> element("#routine-flip") |> render_click()
      assert has_element?(view, "#chore-#{chores[auto].id}")
    end

    test "the boundary message reverts a manual flip to automatic selection (FR-4)",
         %{conn: conn, chores: chores} do
      auto = auto_routine()
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#routine-flip") |> render_click()
      refute has_element?(view, "#chore-#{chores[auto].id}")

      send(view.pid, :boundary)

      assert has_element?(view, "#chore-#{chores[auto].id}")
      refute has_element?(view, "#chore-#{chores[Routines.other(auto)].id}")
    end

    test "the kiosk still contains zero links — the flip is a button", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "a")
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

    test "a dimmed preview stays tappable (D19)", %{conn: conn, kid: kid} do
      other = Routines.other(auto_routine())

      flipped_chore =
        chore_fixture(kid, %{name: "Pajamas On", icon: "🌙", routine: Atom.to_string(other)})

      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("#routine-flip") |> render_click()

      view |> element("#chore-#{flipped_chore.id}") |> render_click()

      assert has_element?(view, "#chore-#{flipped_chore.id}[data-done]")
      assert Repo.exists?(from c in Completion, where: c.chore_id == ^flipped_chore.id)
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
  end
end
