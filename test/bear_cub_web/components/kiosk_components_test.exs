defmodule BearCubWeb.KioskComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BearCubWeb.KioskComponents

  # The kiosk's function components rendered in isolation, with plain maps
  # standing in for the kid/chore/reward structs — the point of the module
  # is that nothing here needs a socket, a database or a clock.
  @kid %{id: 1, name: "Kid A", color: "#2563eb"}

  defp chore(attrs \\ %{}) do
    Map.merge(%{id: 7, name: "Make bed", icon: "🛏️", points: 2, unit_max: 5, unit_rate: 1}, attrs)
  end

  defp doc(html), do: LazyHTML.from_fragment(html)
  defp count(html, selector), do: html |> doc() |> LazyHTML.query(selector) |> Enum.count()
  defp has?(html, selector), do: count(html, selector) > 0
  defp text(html, selector), do: html |> doc() |> LazyHTML.query(selector) |> LazyHTML.text()

  describe "night_screen/1" do
    test "renders the single evening-colored moon" do
      html = render_component(&KioskComponents.night_screen/1, %{})

      assert has?(html, "#night-screen .hero-moon-solid")
    end
  end

  describe "countdown/1" do
    defp countdown(attrs) do
      render_component(
        &KioskComponents.countdown/1,
        Map.merge(
          %{kid: @kid, routine: :morning, mode: :minutes, remaining_ms: 600_000, fraction: 0.5},
          attrs
        )
      )
    end

    test "minutes mode: whole minutes and the unit, in the minutes element only" do
      html = countdown(%{})

      assert has?(html, "#countdown-min-1[data-mode=minutes]")
      refute has?(html, "#countdown-sec-1")
      assert text(html, "#countdown-min-1") =~ "10"
      assert text(html, "#countdown-min-1") =~ "min"
    end

    test "seconds mode: m:ss with no unit, in the seconds element only" do
      html = countdown(%{mode: :seconds, remaining_ms: 125_000, fraction: 0.4})

      assert has?(html, "#countdown-sec-1[data-mode=seconds]")
      refute has?(html, "#countdown-min-1")
      assert text(html, "#countdown-sec-1") =~ "2:05"
      refute text(html, "#countdown-sec-1") =~ "min"
    end

    test "the dial angle is the fraction of a circle, in both modes" do
      assert countdown(%{fraction: 0.5}) =~ "180.0deg"

      assert countdown(%{mode: :seconds, remaining_ms: 60_000, fraction: 0.25}) =~ "90.0deg"
    end

    test "the bird in the morning, the bear in the evening" do
      assert has?(countdown(%{}), "#countdown-glyph-1 svg[stroke=currentColor]")

      evening = countdown(%{routine: :evening})
      assert has?(evening, "#countdown-glyph-1 svg[fill=currentColor]")
      refute has?(evening, "#countdown-glyph-1 svg[stroke-width='20']")
    end

    test "never renders a bonus amount, and keeps time off the reward font" do
      for mode <- [:minutes, :seconds] do
        html = countdown(%{mode: mode})

        refute html =~ "+"
        refute html =~ "font-reward"
      end
    end
  end

  describe "banner/1 left slot" do
    test "shows the countdown when one is given" do
      html =
        render_component(&KioskComponents.banner/1, %{
          kid: @kid,
          routine: :morning,
          reveal?: false,
          failed?: false,
          early_bird?: false,
          night_owl?: false,
          r: 5,
          e: 2,
          n: 3,
          points: 12,
          pending_request?: false,
          countdown: %{mode: :minutes, remaining_ms: 600_000, fraction: 0.5}
        })

      assert has?(html, "#countdown-min-1")
    end
  end

  describe "banner/1" do
    defp banner(attrs) do
      render_component(
        &KioskComponents.banner/1,
        Map.merge(
          %{
            kid: @kid,
            routine: :morning,
            reveal?: false,
            failed?: false,
            early_bird?: false,
            night_owl?: false,
            r: 5,
            e: 2,
            n: 3,
            points: 12,
            pending_request?: false
          },
          attrs
        )
      )
    end

    test "carries the name, the points badge and the idle gift button" do
      html = banner(%{})

      assert text(html, "h1") =~ "Kid A"
      assert text(html, "#points-badge-1") =~ "12"
      assert text(html, "#gift-button-1") =~ "🎁"
      refute has?(html, "#completion-icon-1")
    end

    test "shows the pending glyph while a request is open" do
      assert banner(%{pending_request?: true}) |> text("#gift-button-1") =~ "⏳"
    end

    test "a revealed routine shows the completion icon with its +R badge" do
      html = banner(%{reveal?: true})

      assert has?(html, "#completion-icon-1 .hero-sun-solid")
      assert text(html, "#completion-badge-1") =~ "+5"
      refute has?(html, "#early-bird-1")
    end

    test "an early morning folds E into the badge and adds the EARLY BIRD pill" do
      html = banner(%{reveal?: true, early_bird?: true})

      assert text(html, "#completion-badge-1") =~ "+7"

      assert text(html, "#early-bird-1") =~ "EARLY BIRD"
      assert has?(html, "#early-bird-1-glyph svg")
      refute has?(html, "#night-owl-1")
    end

    test "a Night Owl evening folds N into the badge and adds the SLEEPY BEAR pill" do
      html = banner(%{reveal?: true, night_owl?: true, routine: :evening})

      assert has?(html, "#completion-icon-1 .hero-moon-solid")
      assert text(html, "#completion-badge-1") =~ "+8"
      assert text(html, "#night-owl-1") =~ "SLEEPY BEAR"
      assert has?(html, "#night-owl-1-glyph svg")
      refute has?(html, "#early-bird-1")
    end

    test "the badge shows the r and e it is given, not any configured figure" do
      html = banner(%{reveal?: true, early_bird?: true, r: 8, e: 3})

      assert text(html, "#completion-badge-1") =~ "+11"
    end

    test "a forfeited routine keeps the icon and drops the badge" do
      html = banner(%{reveal?: true, failed?: true, routine: :evening})

      assert has?(html, "#completion-icon-1 .hero-moon-solid")
      refute has?(html, "#completion-badge-1")
    end

    test "pill and glyph render together or not at all" do
      html = banner(%{reveal?: true, early_bird?: false, night_owl?: false})

      refute has?(html, "#early-bird-1")
      refute has?(html, "#early-bird-1-glyph")
      refute has?(html, "#night-owl-1")
      refute has?(html, "#night-owl-1-glyph")
    end
  end

  describe "standing_band/1" do
    test "renders thirteen stars and no text" do
      html = render_component(&KioskComponents.standing_band/1, %{kid: @kid})

      assert count(html, "#standing-band-1 .hero-star-solid") == 13
      assert text(html, "#standing-band-1") |> String.trim() == ""
    end
  end

  describe "events_strip/1" do
    test "renders the empty state" do
      html = render_component(&KioskComponents.events_strip/1, %{kid: @kid, events: []})

      assert text(html, "#events-1") =~ "No events today"
    end

    test "renders an all-day family event with the house glyph" do
      event = %{uid: "e1", family?: true, all_day: true, summary: "Picnic"}
      html = render_component(&KioskComponents.events_strip/1, %{kid: @kid, events: [event]})

      assert has?(html, "#event-1-e1 .hero-home")
      assert text(html, "#event-1-e1") =~ "All day"
      assert text(html, "#event-1-e1") =~ "Picnic"
    end
  end

  describe "stake_bar/1" do
    defp stake_bar(attrs) do
      render_component(
        &KioskComponents.stake_bar/1,
        Map.merge(
          %{
            kid: @kid,
            routine: :morning,
            chores: [%{done?: false}, %{done?: true}, %{done?: false}],
            complete?: false,
            failed?: false,
            r: 5
          },
          attrs
        )
      )
    end

    test "one segment per chore, filled segments leading, and the +R chip" do
      html = stake_bar(%{})

      assert count(html, "#stake-bar-1 [data-segment]") == 3
      assert count(html, "#stake-bar-1 [data-segment][data-filled]") == 1
      assert has?(html, "#stake-bar-1 [data-segment]:first-child[data-filled]")
      assert text(html, "#stake-chip-1") =~ "+5"
      assert stake_bar(%{r: 8}) |> text("#stake-chip-1") =~ "+8"
      refute has?(html, "#stake-bar-1[data-paid]")
    end

    test "paid once every chore is done" do
      html = stake_bar(%{chores: [%{done?: true}], complete?: true})

      assert has?(html, "#stake-bar-1[data-paid]")
      assert has?(html, "#stake-chip-1.bg-success")
    end

    test "forfeited hides the chip and keeps the segments" do
      html = stake_bar(%{failed?: true})

      refute has?(html, "#stake-chip-1")
      assert count(html, "#stake-bar-1 [data-segment]") == 3
    end
  end

  describe "routine_penalty/1" do
    test "renders the single capped −R" do
      html = render_component(&KioskComponents.routine_penalty/1, %{kid: @kid, penalty: 8})

      assert text(html, "#routine-penalty-1") =~ "−8"
    end
  end

  describe "chore_row/1" do
    defp chore_row(attrs) do
      render_component(
        &KioskComponents.chore_row/1,
        Map.merge(%{chore: chore(), done?: false, kid: @kid, routine: :morning}, attrs)
      )
    end

    test "a pending routine chore is a tappable dashed slot with no check" do
      html = chore_row(%{slot?: true})

      assert has?(html, "#chore-7.border-dashed[phx-click=toggle-chore]")
      refute has?(html, "#chore-check-7")
    end

    test "a done row carries the check disc" do
      assert chore_row(%{done?: true}) |> has?("#chore-7[data-done] #chore-check-7 .hero-check")
    end

    test "a done extra carries its earned chip and count" do
      html = chore_row(%{done?: true, extra?: true, effort_count: 3, value: 5})

      assert text(html, "#chore-earned-7") =~ "+5"
      assert text(html, "#chore-effort-7") =~ "×3"
    end

    test "a failed extra carries its −N" do
      html = chore_row(%{failed?: true, extra?: true, value: 2})

      assert text(html, "#chore-penalty-7") =~ "−2"
    end

    test "a counting row holds the count panel and no tap of its own" do
      html = chore_row(%{extra?: true, counting?: true, count: 2})

      assert has?(html, "#chore-7[data-counting] #count-name-7[phx-click=count-cancel]")
      assert text(html, "#count-confirm-7") =~ "+4"
      assert text(html, "#count-value-7") =~ "2"
      refute has?(html, "#chore-7[phx-click]")
    end

    test "the count panel is buttons only: no slider, no form, no ✕" do
      html = chore_row(%{extra?: true, counting?: true, count: 2})

      refute has?(html, "#count-form-7")
      refute has?(html, "input[type=range]")
      refute has?(html, "#count-cancel-7")
      refute html =~ "✕"
    end

    test "the stepper discs are inline SVG on the control token, not text glyphs" do
      html = chore_row(%{extra?: true, counting?: true, count: 2})

      assert has?(html, "#count-dec-7.size-16 svg")
      assert has?(html, "#count-inc-7.size-16 svg")
      assert html =~ "var(--extra-card-control)"
      refute text(html, "#count-dec-7") =~ "−"
      refute text(html, "#count-inc-7") =~ "+"
    end

    test "the stepper dims at its bounds but is never HTML-disabled" do
      at_min = chore_row(%{extra?: true, counting?: true, count: 1, chore: chore(%{unit_max: 5})})
      assert has?(at_min, "#count-dec-7.opacity-30")
      refute has?(at_min, "#count-inc-7.opacity-30")
      refute has?(at_min, "#count-dec-7[disabled]")

      at_max = chore_row(%{extra?: true, counting?: true, count: 5, chore: chore(%{unit_max: 5})})
      assert has?(at_max, "#count-inc-7.opacity-30")
      refute has?(at_max, "#count-dec-7.opacity-30")
    end

    test "a pending extra is a rounded dashed slot and a done extra is a flush row of the mass" do
      assert has?(chore_row(%{extra?: true}), "#chore-7.rounded-xl.border-dashed")
      assert has?(chore_row(%{extra?: true, done?: true}), "#chore-7.px-\\[17px\\]")
      refute has?(chore_row(%{extra?: true, done?: true}), "#chore-7.-mx-2\\.5")
    end

    test "a ghost takes its own id prefix and is inert" do
      html = chore_row(%{done?: true, ghost?: true})

      assert has?(html, "#ghost-7.animate-sink-collapse")
      refute has?(html, "#ghost-7[phx-click]")
    end
  end

  describe "band/1" do
    test "renders the routine's praise line" do
      html = render_component(&KioskComponents.band/1, %{kid: @kid, routine: :evening})

      assert text(html, "#band-1") =~ BearCub.Messages.evening_complete()
    end
  end

  describe "reward_card/1" do
    @reward %{id: 3, name: "Movie night", icon: "🎬", points: 40}

    defp reward_card(state) do
      render_component(&KioskComponents.reward_card/1, %{reward: @reward, state: state, kid: @kid})
    end

    test "an available card asks on tap" do
      html = reward_card(:available)

      assert has?(html, "#reward-card-3-1[data-card-state=available][phx-click=request-reward]")
      assert text(html, "#reward-card-3-1") =~ "40"
    end

    test "a pending card withdraws on tap and is not dimmed" do
      html = reward_card(:pending)

      assert has?(html, "#reward-card-3-1[phx-click=withdraw-request]")
      assert text(html, "#reward-card-3-1") =~ "⏳"
      refute has?(html, "#reward-card-3-1.opacity-45")
    end

    test "declined, claimed and locked share the dim and differ by glyph" do
      for {state, glyph} <- [
            declined: ".hero-x-mark.text-error",
            claimed: ".hero-check.text-success",
            locked: ".hero-lock-closed"
          ] do
        html = reward_card(state)

        assert has?(html, "#reward-card-3-1.opacity-45 #{glyph}")
        refute has?(html, "#reward-card-3-1[phx-click]")
      end
    end
  end
end
