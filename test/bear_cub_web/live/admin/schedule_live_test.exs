defmodule BearCubWeb.Admin.ScheduleLiveTest do
  use BearCubWeb.ConnCase

  import Phoenix.LiveViewTest

  import BearCub.ChoresFixtures
  import BearCub.SchedulesFixtures

  alias BearCub.Schedules

  # The suite's default pin (D126) is a window the changeset would refuse
  # (an evening that never opens), and this page re-validates the whole
  # schedule on every save. So each test starts from version 0's real
  # timings, R = 5, E = 2, identical on all seven days: every card starts
  # alike and a one-field edit is the whole diff.
  setup do
    version_fixture(DateTime.add(DateTime.utc_now(), -30, :minute))
    :ok
  end

  defp day_params(view_params) do
    Map.new(0..6, fn i -> {to_string(i), Map.get(view_params, i, %{})} end)
  end

  defp submit_change(view, params), do: view |> form("#schedule-form", schedule: params)

  defp versions, do: length(Schedules.versions())

  describe "navigation (SC-3)" do
    test "the bottom tab bar has a Schedule entry beside the others, active on the page",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/schedule")

      assert has_element?(view, "#admin-tabs a[aria-current='page']", "Schedule")

      for path <- ~w(/admin /admin/chores /admin/kids /admin/calendars /admin/rewards) do
        assert has_element?(view, "#admin-tabs a[href='#{path}']")
      end

      assert has_element?(view, "#admin-tabs a[href='/admin/schedule']")
    end
  end

  describe "layout (SC-2, SC-3)" do
    test "shows both bonuses, then seven day cards Monday to Sunday, prefilled", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/schedule")

      assert has_element?(view, "#schedule-form input[name='schedule[routine_bonus]'][value='5']")

      assert has_element?(
               view,
               "#schedule-form input[name='schedule[early_bird_bonus]'][value='2']"
             )

      assert html =~ "0 turns it off"

      for weekday <- 1..7 do
        assert has_element?(view, "#day-card-#{weekday}")

        for field <- ~w(morning_start morning_end evening_start evening_end early_bird_cutoff) do
          assert has_element?(
                   view,
                   "#day-card-#{weekday} input[type='time'][name='schedule[days][#{weekday - 1}][#{field}]']"
                 )
        end
      end

      assert has_element?(view, "#day-card-1 #{day_input_selector(1)}[value='05:00']")

      names = ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)

      order =
        Regex.scan(~r/id="day-card-(\d)"/, html)
        |> Enum.map(fn [_, d] -> String.to_integer(d) end)

      assert order == Enum.to_list(1..7)

      for {name, weekday} <- Enum.with_index(names, 1) do
        assert has_element?(view, "#day-card-#{weekday}", name)
      end

      # bonuses sit above the first card
      assert :binary.match(html, "routine_bonus") < :binary.match(html, "day-card-1")
    end

    test "no day card is marked custom while all seven match Monday", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/schedule")

      refute has_element?(view, "[data-custom]")
    end
  end

  describe "save (SC-3)" do
    test "changed values record a new version in force now and say so", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/schedule")
      before = versions()

      html = view |> submit_change(%{routine_bonus: "9"}) |> render_submit()

      assert html =~ "Saved — in effect now"
      assert versions() == before + 1
      assert Schedules.current().routine_bonus == 9
    end

    test "a save broadcasts :schedule_changed so an open kiosk follows", %{conn: conn} do
      Schedules.subscribe()
      {:ok, view, _html} = live(conn, ~p"/admin/schedule")

      view |> submit_change(%{early_bird_bonus: "0"}) |> render_submit()

      assert_receive :schedule_changed
      assert Schedules.current().early_bird_bonus == 0
    end

    test "saving with no changes records nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/schedule")
      before = versions()
      Schedules.subscribe()

      view |> form("#schedule-form") |> render_submit()

      assert versions() == before
      refute_received :schedule_changed
    end

    test "a day's edited time is what gets recorded for that weekday only", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/schedule")

      view
      |> submit_change(%{days: day_params(%{5 => %{morning_start: "06:00"}})})
      |> render_submit()

      current = Schedules.current()
      assert Enum.find(current.days, &(&1.weekday == 6)).morning_start == ~T[06:00:00]
      assert Enum.find(current.days, &(&1.weekday == 1)).morning_start == ~T[05:00:00]
    end
  end

  describe "validation errors (SC-2)" do
    test "an error lands on the specific card and field, and records nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/schedule")
      before = versions()

      # Wednesday's cutoff after the morning window ends
      html =
        view
        |> submit_change(%{
          days: day_params(%{2 => %{morning_end: "10:00", early_bird_cutoff: "11:00"}})
        })
        |> render_submit()

      assert versions() == before
      refute html =~ "Saved — in effect now"

      assert has_element?(
               view,
               "#day-card-3 [data-field='early_bird_cutoff']",
               "must fall inside the morning window"
             )

      refute has_element?(view, "#day-card-2", "must fall inside")
      refute has_element?(view, "#day-card-4", "must fall inside")
    end

    test "validate shows the error while typing, before Save", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/schedule")

      view
      |> submit_change(%{days: day_params(%{0 => %{morning_end: "04:00"}})})
      |> render_change()

      assert has_element?(view, "#day-card-1", "must be after the start")
    end

    test "a negative bonus is refused on the bonus field", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/schedule")
      before = versions()

      view |> submit_change(%{routine_bonus: "-1"}) |> render_submit()

      assert versions() == before
      assert has_element?(view, "#schedule-form", "must be greater than or equal to 0")
    end
  end

  describe "custom marker (SC-2)" do
    test "a card differing from Monday carries it, updating as the form is edited",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/schedule")

      view
      |> submit_change(%{days: day_params(%{5 => %{morning_start: "06:00"}})})
      |> render_change()

      assert has_element?(view, "#day-card-6 [data-custom]", "custom")
      refute has_element?(view, "#day-card-5 [data-custom]")
      refute has_element?(view, "#day-card-1 [data-custom]")

      view
      |> submit_change(%{days: day_params(%{5 => %{morning_start: "05:00"}})})
      |> render_change()

      refute has_element?(view, "[data-custom]")
    end

    test "the page marks a saved varying weekend on load", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/schedule")

      view
      |> submit_change(%{
        days: day_params(%{5 => %{morning_start: "06:00"}, 6 => %{morning_start: "06:00"}})
      })
      |> render_submit()

      {:ok, view, _html} = live(conn, ~p"/admin/schedule")

      assert has_element?(view, "#day-card-6 [data-custom]")
      assert has_element?(view, "#day-card-7 [data-custom]")
      refute has_element?(view, "#day-card-2 [data-custom]")
    end
  end

  describe "copy to (SC-2)" do
    setup %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/schedule")

      # Saturday's unsaved edit is the source
      view
      |> submit_change(%{
        days: day_params(%{5 => %{morning_start: "08:00", early_bird_cutoff: "09:00"}})
      })
      |> render_change()

      %{view: view}
    end

    test "weekend copies to Sunday only, writes nothing", %{view: view} do
      before = versions()

      view |> element("#copy-6-weekend") |> render_click()

      assert has_element?(view, "#day-card-7 #{day_input_selector(7)}[value='08:00']")
      assert has_element?(view, "#day-card-7 input[value='09:00']")
      refute has_element?(view, "#day-card-1 #{day_input_selector(1)}[value='08:00']")
      assert has_element?(view, "#day-card-7 [data-custom]")
      assert versions() == before
    end

    test "weekdays overwrites Monday to Friday, leaving the weekend", %{view: view} do
      before = versions()

      view |> element("#copy-6-weekdays") |> render_click()

      for weekday <- 1..5 do
        assert has_element?(
                 view,
                 "#day-card-#{weekday} #{day_input_selector(weekday)}[value='08:00']"
               )
      end

      refute has_element?(view, "#day-card-7 #{day_input_selector(7)}[value='08:00']")
      assert versions() == before
    end

    test "all days overwrites every card", %{view: view} do
      before = versions()

      view |> element("#copy-6-all") |> render_click()

      for weekday <- 1..7 do
        assert has_element?(
                 view,
                 "#day-card-#{weekday} #{day_input_selector(weekday)}[value='08:00']"
               )
      end

      refute has_element?(view, "[data-custom]")
      assert versions() == before
    end

    test "nothing is recorded until Save, and Save then records the copy", %{view: view} do
      view |> element("#copy-6-all") |> render_click()
      before = versions()

      assert view |> form("#schedule-form") |> render_submit() =~ "Saved — in effect now"

      assert versions() == before + 1
      assert Enum.all?(Schedules.current().days, &(&1.morning_start == ~T[08:00:00]))
    end
  end

  describe "Night Owl (SC-1, SC-2, SC-5)" do
    setup do
      # Created in reverse id order so position, not id, drives the display order.
      second = kid_fixture(%{name: "Second Kid", color: "#10b981", position: 1})
      first = kid_fixture(%{name: "First Kid", color: "#f59e0b", position: 0})
      %{first: first, second: second}
    end

    defp cutoff_input(weekday, kid),
      do: "#day-card-#{weekday} [data-kid='#{kid.id}'] input[type='time']"

    defp cutoffs(weekday, kid_ids \\ nil) do
      day = Enum.find(Schedules.current().days, &(&1.weekday == weekday))

      day.night_owl_cutoffs
      |> Map.new(&{&1.kid_id, &1.cutoff})
      |> then(&if(kid_ids, do: Map.take(&1, kid_ids), else: &1))
    end

    test "the Bonuses row has a Night owl bonus beside R and E, saved in effect at once",
         %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/schedule")

      assert has_element?(view, "#bonuses input[name='schedule[night_owl_bonus]'][value='0']")
      assert html =~ "Night owl bonus"

      view |> submit_change(%{night_owl_bonus: "4"}) |> render_submit()

      assert Schedules.current().night_owl_bonus == 4
    end

    test "each card has one time input per kid in position order, with the kid's dot and name",
         %{conn: conn, first: first, second: second} do
      {:ok, view, html} = live(conn, ~p"/admin/schedule")

      for weekday <- 1..7, kid <- [first, second] do
        assert has_element?(view, cutoff_input(weekday, kid))
      end

      assert has_element?(view, "#day-card-1 [data-kid='#{first.id}']", "First Kid")

      assert has_element?(
               view,
               "#day-card-1 [data-kid='#{first.id}'] [data-dot][style*='#f59e0b']"
             )

      assert has_element?(
               view,
               "#day-card-1 [data-kid='#{second.id}'] [data-dot][style*='#10b981']"
             )

      [card_one | _] = String.split(html, ~s(id="day-card-2"))
      assert :binary.match(card_one, "First Kid") < :binary.match(card_one, "Second Kid")
    end

    test "a kid with no saved cutoff shows a blank field and the label says blank means none",
         %{conn: conn, first: first} do
      {:ok, view, _html} = live(conn, ~p"/admin/schedule")

      assert has_element?(view, "#day-card-1", "blank = no Night Owl")
      refute has_element?(view, "#{cutoff_input(1, first)}[value]")
    end

    test "a save records each kid's cutoff, one kid differing without touching the other",
         %{conn: conn, first: first, second: second} do
      {:ok, view, _html} = live(conn, ~p"/admin/schedule")

      view
      |> form("#schedule-form")
      |> render_change(%{
        "schedule" => %{
          "days" => %{
            "4" => %{"night_owl_cutoffs" => %{"0" => %{"cutoff" => "20:30"}}},
            "5" => %{
              "night_owl_cutoffs" => %{
                "0" => %{"cutoff" => "19:00"},
                "1" => %{"cutoff" => "21:15"}
              }
            }
          }
        }
      })

      assert view |> form("#schedule-form") |> render_submit() =~ "Saved — in effect now"

      assert cutoffs(5) == %{first.id => ~T[20:30:00]}
      assert cutoffs(6) == %{first.id => ~T[19:00:00], second.id => ~T[21:15:00]}
      assert cutoffs(1) == %{}

      {:ok, view, _html} = live(conn, ~p"/admin/schedule")
      assert has_element?(view, "#{cutoff_input(5, first)}[value='20:30']")
      refute has_element?(view, "#{cutoff_input(5, second)}[value]")
    end

    test "a blank cutoff saves as no entry for that kid", %{
      conn: conn,
      first: first,
      second: second
    } do
      {:ok, view, _html} = live(conn, ~p"/admin/schedule")

      view
      |> form("#schedule-form")
      |> render_change(%{
        "schedule" => %{
          "days" => %{
            "0" => %{
              "night_owl_cutoffs" => %{"0" => %{"cutoff" => "20:00"}, "1" => %{"cutoff" => ""}}
            }
          }
        }
      })

      view |> form("#schedule-form") |> render_submit()

      assert cutoffs(1) == %{first.id => ~T[20:00:00]}
      refute Map.has_key?(cutoffs(1), second.id)
    end

    test "a cutoff outside the evening window errors on that kid's field in that card",
         %{conn: conn, first: first, second: second} do
      {:ok, view, _html} = live(conn, ~p"/admin/schedule")
      before = versions()

      html =
        view
        |> form("#schedule-form")
        |> render_submit(%{
          "schedule" => %{
            "days" => %{
              "2" => %{"night_owl_cutoffs" => %{"1" => %{"cutoff" => "23:30"}}}
            }
          }
        })

      assert versions() == before
      refute html =~ "Saved — in effect now"

      assert has_element?(
               view,
               "#day-card-3 [data-kid='#{second.id}']",
               "must fall inside the evening window"
             )

      refute has_element?(view, "#day-card-3 [data-kid='#{first.id}']", "must fall inside")
      refute has_element?(view, "#day-card-2", "must fall inside")
      refute has_element?(view, "#day-card-4", "must fall inside")
    end

    test "a card whose cutoffs differ from Monday's is marked custom",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/schedule")
      refute has_element?(view, "[data-custom]")

      view
      |> form("#schedule-form")
      |> render_change(%{
        "schedule" => %{
          "days" => %{"2" => %{"night_owl_cutoffs" => %{"0" => %{"cutoff" => "20:00"}}}}
        }
      })

      assert has_element?(view, "#day-card-3 [data-custom]")
      refute has_element?(view, "#day-card-2 [data-custom]")
      refute has_element?(view, "#day-card-1 [data-custom]")
    end

    test "Copy to carries cutoffs with the rest of the day, unsaved only",
         %{conn: conn, first: first, second: second} do
      {:ok, view, _html} = live(conn, ~p"/admin/schedule")

      view
      |> form("#schedule-form")
      |> render_change(%{
        "schedule" => %{
          "days" => %{
            "5" => %{
              "night_owl_cutoffs" => %{
                "0" => %{"cutoff" => "20:00"},
                "1" => %{"cutoff" => "21:00"}
              }
            }
          }
        }
      })

      before = versions()
      view |> element("#copy-6-weekend") |> render_click()

      assert has_element?(view, "#{cutoff_input(7, first)}[value='20:00']")
      assert has_element?(view, "#{cutoff_input(7, second)}[value='21:00']")
      refute has_element?(view, "#{cutoff_input(1, first)}[value]")
      assert versions() == before

      view |> form("#schedule-form") |> render_submit()
      assert cutoffs(7) == %{first.id => ~T[20:00:00], second.id => ~T[21:00:00]}
    end

    test "Copy to overwrites the target's cutoff with a blank source field",
         %{conn: conn, first: first} do
      {:ok, view, _html} = live(conn, ~p"/admin/schedule")

      view
      |> form("#schedule-form")
      |> render_change(%{
        "schedule" => %{
          "days" => %{"6" => %{"night_owl_cutoffs" => %{"0" => %{"cutoff" => "20:00"}}}}
        }
      })

      view |> element("#copy-1-all") |> render_click()

      refute has_element?(view, "#{cutoff_input(7, first)}[value]")
      refute has_element?(view, "[data-custom]")
    end

    test "an untouched form with kids present saves nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/schedule")
      before = versions()
      Schedules.subscribe()

      assert view |> form("#schedule-form") |> render_submit() =~ "No changes to save"

      assert versions() == before
      refute_received :schedule_changed
    end

    test "saving cutoffs then saving again untouched writes nothing more",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/schedule")

      view
      |> form("#schedule-form")
      |> render_change(%{
        "schedule" => %{
          "days" => %{"0" => %{"night_owl_cutoffs" => %{"0" => %{"cutoff" => "20:00"}}}}
        }
      })

      view |> form("#schedule-form") |> render_submit()
      before = versions()

      assert view |> form("#schedule-form") |> render_submit() =~ "No changes to save"
      assert versions() == before
    end
  end

  describe "concurrent saves (SC-3)" do
    test "a same-second collision says to try again and records nothing more", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/schedule")

      # The save stamps the real clock (D119), so the other phone's save has
      # to land in the same wall-clock second: wait for the start of one.
      wait_for_second_start()
      {:ok, _} = Schedules.change(%{"routine_bonus" => "7"}, DateTime.utc_now())
      before = versions()

      html = view |> submit_change(%{routine_bonus: "8"}) |> render_submit()

      assert html =~ "try again"
      refute html =~ "Saved — in effect now"
      assert versions() == before
    end
  end

  defp day_input_selector(weekday),
    do: "input[name='schedule[days][#{weekday - 1}][morning_start]']"

  defp wait_for_second_start do
    if DateTime.utc_now().microsecond |> elem(0) > 300_000 do
      Process.sleep(50)
      wait_for_second_start()
    end
  end
end
