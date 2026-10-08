defmodule BearCubWeb.KioskWeatherTest do
  # The held reading is global state (persistent_term), so this file is
  # not async.
  use BearCubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BearCub.ChoresFixtures

  alias BearCub.Chores
  alias BearCub.LocalTime
  alias BearCub.Weather
  alias BearCub.Weather.Reading
  alias BearCubWeb.KioskComponents

  @temps %{hot: "🥵", normal: "🙂", cold: "🥶"}
  @precips %{none: "☀️", rain: "☔", snow: "❄️"}

  defp today, do: LocalTime.now() |> DateTime.to_date()

  defp put_reading(temp, precip),
    do: Weather.put(%Reading{date: today(), temp: temp, precip: precip})

  setup do
    Weather.reset()
    on_exit(&Weather.reset/0)
    morning_active()

    kid = kid_fixture(%{name: "Kid A", color: "#f59e0b", position: 0})

    flagged =
      chore_fixture(kid, %{
        name: "Get dressed",
        icon: "👕",
        routine: "morning",
        shows_weather: true
      })

    plain = chore_fixture(kid, %{name: "Brush Teeth", icon: "🪥", routine: "morning"})
    %{kid: kid, flagged: flagged, plain: plain}
  end

  test "glyph helpers spell the variation selectors out" do
    assert KioskComponents.temp_glyph(:hot) == "\u{1F975}"
    assert KioskComponents.temp_glyph(:normal) == "\u{1F642}"
    assert KioskComponents.temp_glyph(:cold) == "\u{1F976}"
    assert KioskComponents.precip_glyph(:none) == "☀️"
    assert KioskComponents.precip_glyph(:rain) == "☔"
    assert KioskComponents.precip_glyph(:snow) == "❄️"
  end

  for temp <- [:hot, :normal, :cold], precip <- [:none, :rain, :snow] do
    test "shows #{temp}/#{precip} as its two glyphs, temperature first",
         %{conn: conn, flagged: flagged} do
      put_reading(unquote(temp), unquote(precip))
      {:ok, view, _} = live(conn, ~p"/")

      expected = @temps[unquote(temp)] <> @precips[unquote(precip)]
      assert has_element?(view, "#chore-weather-#{flagged.id}")

      [{_, _, children}] =
        view
        |> element("#chore-weather-#{flagged.id}")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.to_tree()

      text = for {"span", _, [t]} <- children, into: "", do: t
      assert text == expected
    end
  end

  test "an unflagged row shows nothing", %{conn: conn, plain: plain} do
    put_reading(:cold, :snow)
    {:ok, view, _} = live(conn, ~p"/")
    refute has_element?(view, "#chore-weather-#{plain.id}")
  end

  test "a kid with no flagged chore sees no weather", %{conn: conn} do
    other = kid_fixture(%{name: "Kid B", color: "#0ea5e9", position: 1})
    chore_fixture(other, %{name: "Shoes", icon: "👟", routine: "morning"})
    put_reading(:hot, :none)
    {:ok, view, _} = live(conn, ~p"/")
    refute has_element?(view, "#kid-column-#{other.id} [id*='-weather']")
  end

  test "every kid with a flagged chore sees the same reading", %{conn: conn} do
    other = kid_fixture(%{name: "Kid B", color: "#0ea5e9", position: 1})
    c = chore_fixture(other, %{name: "Dress", icon: "👕", routine: "morning", shows_weather: true})
    put_reading(:hot, :rain)
    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#chore-weather-#{c.id}")
  end

  test "no reading renders the same as the feature off", %{conn: conn, kid: kid, flagged: flagged} do
    {:ok, view, _} = live(conn, ~p"/")
    refute has_element?(view, "#chore-weather-#{flagged.id}")
    with_flag_nil = view |> element("#kid-column-#{kid.id}") |> render()

    {:ok, _} = Chores.update_chore(flagged, %{shows_weather: false})
    {:ok, view2, _} = live(conn, ~p"/")
    assert view2 |> element("#kid-column-#{kid.id}") |> render() == with_flag_nil
  end

  test "a tap removes the weather and an undo restores it", %{conn: conn, flagged: flagged} do
    put_reading(:cold, :rain)
    {:ok, view, _} = live(conn, ~p"/")
    view |> element("#chore-#{flagged.id}") |> render_click()
    refute has_element?(view, "#chore-weather-#{flagged.id}")
    view |> element("#chore-#{flagged.id}") |> render_click()
    assert has_element?(view, "#chore-weather-#{flagged.id}")
  end

  test "a chore completed from admin shows no weather", %{conn: conn, flagged: flagged} do
    put_reading(:cold, :rain)
    {:ok, view, _} = live(conn, ~p"/")
    {:ok, _} = Chores.complete_chore(flagged, LocalTime.now(), "admin")
    _ = render(view)
    refute has_element?(view, "#chore-weather-#{flagged.id}")
  end

  test "a failed row shows no weather", %{conn: conn, flagged: flagged} do
    put_reading(:cold, :rain)
    {:ok, _} = Chores.complete_chore(flagged, LocalTime.now(), "kiosk")
    {:ok, _} = Chores.fail_chore(flagged, LocalTime.now())
    {:ok, view, _} = live(conn, ~p"/")
    refute has_element?(view, "#chore-weather-#{flagged.id}")
  end

  test "an extra never shows weather", %{conn: conn, kid: kid} do
    put_reading(:cold, :rain)

    {:ok, extra} =
      Chores.create_chore(
        kid,
        %{name: "Extra", icon: "⭐", routine: nil, shows_weather: true},
        LocalTime.now()
      )

    {:ok, view, _} = live(conn, ~p"/")
    refute has_element?(view, "#chore-weather-#{extra.id}")
  end

  test "the evening routine shows no weather", %{conn: conn, kid: kid} do
    evening_active()
    e = chore_fixture(kid, %{name: "Pajamas", icon: "🌙", routine: "evening"})
    put_reading(:cold, :rain)
    {:ok, view, _} = live(conn, ~p"/")
    refute has_element?(view, "#chore-weather-#{e.id}")
  end

  test "the night screen shows no weather", %{conn: conn, flagged: flagged} do
    put_windows({~T[00:00:00], ~T[00:00:01]}, {~T[00:00:01], ~T[00:00:02]})
    put_reading(:cold, :rain)
    {:ok, view, _} = live(conn, ~p"/")
    refute has_element?(view, "#chore-weather-#{flagged.id}")
  end

  test ":weather_changed re-renders an open kiosk", %{conn: conn, flagged: flagged} do
    {:ok, view, _} = live(conn, ~p"/")
    refute has_element?(view, "#chore-weather-#{flagged.id}")
    put_reading(:hot, :none)
    _ = render(view)
    assert has_element?(view, "#chore-weather-#{flagged.id}")
  end
end
