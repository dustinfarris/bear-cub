defmodule BearCubWeb.KioskComponents do
  @moduledoc """
  The kids' view, piece by piece: every visual unit of a kiosk column as a
  function component that renders from plain assigns — no socket, no
  database, no clock.

  `BearCubWeb.KioskLive` owns state, events and layout and composes these;
  the markup lives here so a piece can be rendered on its own (component
  tests, design previews). Semantics, invariants and rulings for anything
  in this module are in `docs/design-language.org` and are binding.
  """
  use BearCubWeb, :html

  alias BearCub.LocalTime
  alias BearCub.Messages

  @doc """
  Night screen (D56, supersedes D32's per-column Good Night message): the
  23:00–05:00 gap is a single dark screen with one large evening-colored
  moon and nothing else — no columns, no banners, no points badges (the D43
  always-visible badge is scoped to the waking windows), no events, no
  stale glyph. Corrections still go to admin; nothing here is tappable.
  """
  def night_screen(assigns) do
    ~H"""
    <div
      id="night-screen"
      class="col-span-2 flex items-center justify-center bg-stone-950"
      style="color: var(--routine-evening)"
    >
      <.icon name="hero-moon-solid" class="size-52" />
    </div>
    """
  end

  attr :kid, :map, required: true
  attr :streak, :integer, required: true

  @doc """
  The 🔥 chip (D157): a 64 px transparent target around a 40 px pill with an
  inset ring, so it reads as tappable beside the plain ★ badge. At 0 the
  flame is a dashed outline (inline SVG, D103) and there is no number.
  """
  def streak_chip(assigns) do
    ~H"""
    <button
      type="button"
      id={"streak-chip-#{@kid.id}"}
      phx-click="open-record"
      class="flex h-16 items-center justify-center bg-transparent"
    >
      <span class="flex h-10 items-center gap-1 rounded-full px-3 font-reward text-lg font-black text-white shadow-[inset_0_0_0_2px_rgb(255_255_255/0.55)]">
        <%= if @streak > 0 do %>
          🔥 {@streak}
        <% else %>
          <.flame_outline class="size-5" stroke="white" />
        <% end %>
      </span>
    </button>
    """
  end

  attr :class, :string, required: true
  attr :stroke, :string, required: true

  # The flame at a streak of 0 (D103): a dashed outline as inline SVG, so no
  # font has to cover it. The chip and the record screen's streak tile share it.
  defp flame_outline(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 24 24"
      class={@class}
      fill="none"
      stroke={@stroke}
      stroke-width="2"
      stroke-dasharray="3 2.5"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <path d="M12 3c1 3.5-3.5 5.5-3.5 10a3.5 3.5 0 0 0 7 0c0-1.8-.6-2.8-1.4-3.8-.2 1.2-.8 1.8-1.5 2 .4-3-.1-5.7-.6-8.2z" />
    </svg>
    """
  end

  attr :kids, :list, required: true

  attr :data, :map,
    required: true,
    doc: "`%{kid_id => %{current:, longest:, lifetime:}}`, loaded only while the screen is open"

  @doc """
  The record screen (D157, D159): one identical column per kid under a solid
  kid-colour banner, and the one control, a Chores button straddling the
  gutter. Each body holds the streak tile and the longest/lifetime row; a
  tile with no value yet keeps its place and size and goes dashed. Nothing
  ranks or compares the two columns.
  """
  def record_screen(assigns) do
    ~H"""
    <div id="record-screen" class="contents">
      <section
        :for={kid <- @kids}
        id={"record-column-#{kid.id}"}
        style={"--kid: #{kid.color}"}
        class="kid-scope flex flex-col overflow-hidden rounded-lg bg-base-100"
      >
        <header class="flex h-20 items-center justify-center" style={"background-color: #{kid.color}"}>
          <h1 class="font-reward text-[40px] font-black leading-none text-white">{kid.name}</h1>
        </header>
        <div class="flex flex-col gap-4 p-5">
          <.streak_tile
            kid={kid}
            current={@data[kid.id].current}
            longest={@data[kid.id].longest}
          />
          <div class="grid h-28 grid-cols-2 gap-4">
            <.longest_tile kid={kid} longest={@data[kid.id].longest} />
            <.lifetime_tile kid={kid} lifetime={@data[kid.id].lifetime} />
          </div>
        </div>
      </section>
      <button
        type="button"
        id="record-back"
        phx-click="close-record"
        class="absolute left-[532px] top-5 z-10 flex h-[72px] w-[216px] items-center justify-center gap-3 rounded-full bg-base-100"
      >
        <span class="flex size-12 items-center justify-center rounded-full bg-base-content text-base-100">
          <.icon name="hero-home" class="size-7" />
        </span>
        <span class="font-reward text-[30px] font-black leading-none text-base-content">Chores</span>
      </button>
    </div>
    """
  end

  attr :kid, :map, required: true
  attr :current, :integer, required: true
  attr :longest, :integer, required: true

  defp streak_tile(assigns) do
    ~H"""
    <div
      id={"streak-tile-#{@kid.id}"}
      class="relative flex h-48 items-center gap-6 rounded-2xl border-[3px] px-8"
      style="background-color: var(--kid-tint); border-color: var(--kid-edge)"
    >
      <div
        :if={@current > 0 and @current == @longest}
        id={"best-ever-#{@kid.id}"}
        class="absolute -top-[19px] right-5 flex items-center gap-1.5 rounded-full border-[3px] bg-base-100 px-3 py-0.5"
        style="border-color: var(--kid)"
      >
        <span class="text-[22px] leading-none">🏆</span>
        <span class="font-reward text-[19px] font-extrabold leading-none text-base-content">
          Best ever!
        </span>
      </div>
      <span :if={@current > 0} class="text-[108px] leading-none">🔥</span>
      <.flame_outline :if={@current == 0} class="size-[108px]" stroke="var(--kid)" />
      <div class="flex flex-col">
        <span
          class="font-reward text-[140px] font-black leading-[.86]"
          style="color: var(--kid)"
        >
          {@current}
        </span>
        <span class="mt-2 font-reward text-[28px] font-extrabold leading-none text-base-content">
          {streak_label(@current, @longest)}
        </span>
      </div>
    </div>
    """
  end

  defp streak_label(0, 0), do: "Start today!"
  defp streak_label(0, _longest), do: "Start again today!"
  defp streak_label(1, _longest), do: "day in a row"
  defp streak_label(_current, _longest), do: "days in a row"

  attr :kid, :map, required: true
  attr :longest, :integer, required: true

  # Identical in every state but one: only while the longest streak is 0 does
  # the border go dashed and faint. A reset never touches it (D159).
  defp longest_tile(assigns) do
    ~H"""
    <div
      id={"longest-tile-#{@kid.id}"}
      class={[
        "flex items-center gap-3 rounded-2xl border-4 bg-base-100 px-5",
        if(@longest == 0, do: "border-dashed", else: "border-solid")
      ]}
      style={"border-color: #{if @longest == 0, do: "var(--kid-edge)", else: "var(--kid)"}"}
    >
      <span class="text-[48px] leading-none">🏆</span>
      <div class="flex flex-col">
        <div class="flex items-baseline gap-2">
          <span class="font-reward text-[52px] font-black leading-none">{@longest}</span>
          <span class="font-reward text-[22px] font-extrabold leading-none">
            {if @longest == 1, do: "day", else: "days"}
          </span>
        </div>
        <span class="mt-1 text-[17px] font-bold leading-none">longest ever</span>
      </div>
    </div>
    """
  end

  attr :kid, :map, required: true
  attr :lifetime, :integer, required: true

  # Points earned in all, never lowered by spending. The paid family is the
  # "earned something" signal (design-language entry 7).
  defp lifetime_tile(assigns) do
    ~H"""
    <div
      id={"lifetime-tile-#{@kid.id}"}
      class={[
        "flex items-center gap-3 rounded-2xl border-4 px-5",
        if(@lifetime == 0, do: "border-dashed", else: "border-solid")
      ]}
      style="background-color: var(--paid-tint); border-color: var(--paid-edge); color: var(--paid-content)"
    >
      <.icon name="hero-star-solid" class="size-12 shrink-0" />
      <div class="flex flex-col">
        <span class="font-reward text-[52px] font-black leading-none">{@lifetime}</span>
        <span class="mt-1 text-[17px] font-bold leading-none">earned in all</span>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :routine, :atom, required: true
  attr :color, :string, required: true
  slot :inner_block, required: true

  # The reward pill with the bird or bear climbing out of its upper-right
  # corner (D149): pill and glyph are one signal, rendered together. The
  # glyph sits behind the pill (the pill is z-index 1) so it appears to
  # peek out from behind it.
  defp bonus_pill(assigns) do
    ~H"""
    <span class="absolute bottom-[6px] left-0 block">
      <span
        id={"#{@id}-glyph"}
        class="absolute -right-[15px] -top-4 block text-white"
        style="line-height: 0"
      >
        <.bonus_glyph routine={@routine} width={if @routine == :morning, do: 26, else: 30} />
      </span>
      <span
        id={@id}
        class="relative z-[1] block whitespace-nowrap rounded-full bg-white px-[9px] py-1 font-reward text-sm font-black leading-none tracking-wide drop-shadow-sm"
        style={"color: #{@color}"}
      >
        {render_slot(@inner_block)}
      </span>
    </span>
    """
  end

  attr :routine, :atom, required: true
  attr :width, :integer, required: true
  attr :class, :string, default: nil

  # The bird (morning) or the bear (evening) as inline SVG, coloured through
  # currentColor, for the reward and, in the countdown dial, the banner
  # (D103, D151).
  defp bonus_glyph(%{routine: :morning} = assigns) do
    ~H"""
    <%!-- Bird: SVG Repo, vectordoodle (https://www.svgrepo.com/author/vectordoodle/),
         CC BY 4.0 — cropped viewBox, stroke for Bear Cub --%>
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="80 95 280 215"
      width={@width}
      fill="none"
      stroke="currentColor"
      stroke-width="20"
      stroke-linecap="round"
      stroke-linejoin="round"
      class={@class}
      aria-hidden="true"
    >
      <path d="M191.179 273.824C240.235 297.511 305.516 282.723 327.848 235.07C343.653 201.345 294.142 174.478 268.869 180.597C249.795 185.215 238.443 210.424 226.139 201.065C216.677 165.605 199.9 119.51 135.192 107.37C114.091 103.412 83.5311 110.64 102.336 135.815C116.496 154.766 137.36 163.983 158.442 173.765C164.792 176.714 169.78 183.842 176.581 185.72C178.199 186.166 181.717 185.007 181.525 186.671C181.105 190.238 113.899 155.977 108.125 179.498C103.955 196.484 152.426 206.208 162.693 208.177C163.338 208.3 167.696 208.583 167.631 209.126C167.291 212.044 128.996 205.366 122.548 219.126C113.925 237.519 146.169 239.099 156.097 238.053C164.394 237.176 172.809 236.947 180.889 235.438C181.156 235.389 194.153 233.997 169.23 238.769C147.16 242.995 90.4779 253.756 88.9641 262.487C87.4503 271.218 95.0462 273.682 99.275 281.556C103.504 289.429 106.52 291.001 110.939 295.051C115.357 299.1 142.753 259.14 172.051 268.915M323.418 199.974C348.126 209.727 352.589 199.404 329.977 213.31M291.997 210.007C291.781 209.411 291.563 208.813 291.345 208.215">
      </path>
    </svg>
    """
  end

  defp bonus_glyph(%{routine: :evening} = assigns) do
    ~H"""
    <%!-- Bear: SVG Repo, CC0 — cropped viewBox, plus a 22-unit stroke of
         the same colour to thicken it --%>
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="-12 83 536 336"
      width={@width}
      fill="currentColor"
      stroke="currentColor"
      stroke-width="22"
      stroke-linejoin="round"
      class={@class}
      aria-hidden="true"
    >
      <path d="M507.675,191.611c-8.298-4.523-16.834-10.372-19.115-13.041c-0.059-0.561-0.112-1.189-0.169-1.872 c-1.005-11.850-2.874-33.797-49.601-53.729c-1.287-2.679-3.049-5.224-5.343-7.362c-5.64-5.255-13.02-6.75-20.781-4.219 c-6.564,2.144-10.734,5.34-13.397,8.592c-8.108,0.59-14.155,2.815-19.572,4.817c-5.631,2.079-10.493,3.875-17.535,3.875 c-3.374,0-7.529-2.758-12.338-5.952c-7.879-5.231-17.686-11.742-31.895-11.742c-15.988,0-27.036,5.205-37.722,10.24 c-14.719,6.935-28.619,13.484-57.964,7.615c-35.18-7.035-91.351,6.294-112.053,18.714 c-18.997,11.399-40.327,45.677-63.399,101.886c-14.632,35.644-25.465,69.339-28.109,77.74L2.429,343.42 c-2.345,2.347-3.068,5.865-1.836,8.945l17.693,44.233c1.261,3.149,4.310,5.214,7.701,5.214h26.54c4.581,0,8.294-3.712,8.294-8.294 c0-4.581-3.712-8.294-8.294-8.294h-0.554v-10.488c26.402-3.249,59.225-20.73,76.944-37.043c2.33-2.144,4.631-4.138,6.913-6.016 c2.477,4.775,5.601,8.919,8.665,12.95c7.582,9.979,14.744,19.406,14.744,40.044c0,5.245,4.024,7.32,7.258,8.987 c1.529,0.788,3.638,1.833,6.268,3.107c4.471,2.165,8.942,4.262,8.942,4.262c1.101,0.516,2.303,0.784,3.521,0.784h44.233 c4.581,0,8.294-3.712,8.294-8.294c0-4.581-3.712-8.294-8.294-8.294h-16.93c2.395-8.51,7.746-18.546,13.335-29.017 c3.42-6.409,7-13.122,10.205-20.049c2.695,7.75,6.476,15.893,11.637,24.343v17.916c0,6.25,2.434,12.127,6.852,16.543 c4.419,4.418,10.295,6.852,16.544,6.852h46.823c4.581,0,8.294-3.712,8.294-8.294c0-4.581-3.712-8.294-8.294-8.294h-8.426 l7.317-65.848c2.988-1.53,7.27-3.888,12.257-7.114c4.495,14.033,19.662,51.536,55.882,62.274l34.154,25.615 c1.435,1.077,3.181,1.659,4.976,1.659h53.08c4.581,0,8.294-3.712,8.294-8.294c0-4.581-3.712-8.294-8.294-8.294h-8.847 c-6.816,0-15.195-16.576-23.298-32.609c-7.657-15.148-17.102-33.833-30.32-50.481c-0.004-11.875-0.717-44.067-7.932-59.561h35.011 c2.535,0,4.93-1.159,6.503-3.146c4.512-5.701,14.23-5.701,20.036-5.701c21.078,0,30.004-3.741,31.58-4.492 c2.06-0.982,3.626-2.769,4.327-4.942l7.373-22.854C512.822,197.645,511.173,193.519,507.675,191.611z M211.231,348.398 c-6.879,12.89-13.444,25.202-15.739,36.827h-8.412c-4.082-1.926-8.428-4.02-11.376-5.494c-1.172-22.99-10.449-35.2-18.001-45.138 c-3.415-4.494-6.408-8.446-8.214-12.814c25.194-15.795,49.114-17.274,79.797-17.28 C226.917,318.965,218.974,333.888,211.231,348.398z M430.216,360.098c4.798,9.492,9.185,18.172,13.851,25.127h-17.217 l-33.175-24.881c-0.843-0.631-1.796-1.097-2.812-1.371c-35.568-9.613-47.068-55.402-47.178-55.849 c-0.104-0.435-0.25-0.848-0.416-1.25c12.225-10.095,25.336-24.256,33.76-42.894c4.2-1.215,10.343-3.371,15.885-6.765 c3.49,10.201,5.393,33.494,5.184,52.747c-0.021,1.958,0.652,3.863,1.9,5.372C413.048,326.133,422.17,344.178,430.216,360.098z M489.753,215.126c-3.608,0.864-10.468,2.013-21.435,2.013c-6.907,0-20.558,0-30.13,8.847h-32.123 c-6.123,0-11.439-4.357-12.64-10.361l-3.671-18.359c-0.899-4.491-5.268-7.398-9.759-6.507c-4.491,0.899-7.405,5.268-6.507,9.759 l3.671,18.359c1.373,6.861,5.096,12.781,10.223,16.989c-3.436,2.959-10.879,6.366-18.177,8.011 c-2.668,0.593-4.873,2.464-5.894,4.999c-15.61,38.771-57.117,57.233-57.523,57.41c-2.735,1.181-4.625,3.738-4.953,6.698 l-8.027,72.242h-21.707c-1.819,0-3.529-0.709-4.815-1.996c-1.286-1.284-1.994-2.993-1.994-4.813v-20.285 c0-1.573-0.447-3.112-1.289-4.441c-35.207-55.539-2.282-94.512-0.783-96.234c3.02-3.427,2.703-8.653-0.717-11.687 c-3.428-3.04-8.67-2.728-11.708,0.698c-0.455,0.512-11.195,12.781-16.543,33.268c-0.68,2.605-1.285,5.427-1.772,8.435 c-0.648-0.163-1.324-0.259-2.021-0.259c-41.548,0-73.886,2.696-111.777,37.578c-21.567,19.856-55.676,33.195-74.002,33.195 c-4.581,0-8.294,3.712-8.294,8.294v18.246h-3.784l-13.577-33.941l13.827-13.826c0.959-0.96,1.669-2.14,2.066-3.437 c12.662-41.354,52.581-152.915,84.803-172.248c16.125-9.675,68.321-23.065,100.267-16.673c34.714,6.941,52.550-1.461,68.287-8.874 c9.861-4.646,18.376-8.658,30.652-8.658c9.204,0,15.770,4.358,22.721,8.974c6.457,4.286,13.133,8.719,21.512,8.719 c10.007,0,17.060-2.604,23.281-4.902c3.146-1.161,6.068-2.223,9.264-2.957c0.941,6.784,4.172,12.055,4.707,12.888 c1.589,2.476,4.280,3.835,7.023,3.835c1.528,0,3.072-0.421,4.451-1.306c3.856-2.472,4.994-7.578,2.520-11.433 c-1.143-1.845-3.152-6.624-2.055-9.625c0.854-2.340,3.985-3.795,6.464-4.604c2.480-0.811,3.491-0.160,4.244,0.512 c2.275,2.030,3.078,6.069,2.829,7.285c-1.110,4.444,1.591,8.947,6.035,10.059c3.468,0.865,6.961-0.594,8.861-3.383 c30.203,14.611,31.330,27.616,32.080,36.469c0.116,1.367,0.226,2.657,0.417,3.948c0.370,2.499,1.303,8.790,21.460,20.727 L489.753,215.126z">
      </path>
    </svg>
    """
  end

  attr :kid, :map, required: true
  attr :routine, :atom, required: true
  attr :mode, :atom, values: [:minutes, :seconds], required: true
  attr :remaining_ms, :integer, required: true
  attr :fraction, :float, required: true

  @doc """
  The bonus countdown in a kid's banner (D148, D151): renders from assigns
  only, no clock. Minutes and seconds are separate elements so the grow
  runs once, when the seconds pill mounts; between ticks only the text and
  the dial's inline style are patched. The time is set in the system sans,
  never `font-reward`, and no bonus amount appears in either mode.
  """
  def countdown(%{mode: :minutes} = assigns) do
    assigns = assign_countdown(assigns)

    ~H"""
    <div
      id={"countdown-min-#{@kid.id}"}
      data-mode="minutes"
      phx-remove={
        JS.transition("animate-cd-fade motion-reduce:animate-none motion-reduce:opacity-0", time: 600)
      }
      class="col-start-1 row-start-1 flex h-[60px] items-center gap-[10px] rounded-full bg-white/20 pl-[6px] pr-[18px] text-white"
    >
      <span
        class="flex size-[50px] shrink-0 items-center justify-center rounded-full"
        style={"background: conic-gradient(#fff 0deg #{@angle}deg, rgba(255,255,255,.3) #{@angle}deg 360deg)"}
      >
        <span
          id={"countdown-glyph-#{@kid.id}"}
          class="flex size-10 items-center justify-center rounded-full"
          style={"background-color: var(--routine-#{@routine}); color: #{if @routine == :morning, do: "var(--routine-morning-content)", else: "#fff"}; line-height: 0"}
        >
          <.bonus_glyph routine={@routine} width={30} />
        </span>
      </span>
      <span class="flex items-baseline">
        <span class="font-sans text-[40px] font-extrabold tabular-nums leading-none">
          {@text}
        </span>
        <span class="ml-[10px] self-end pb-[14px] font-sans text-[22px] font-bold leading-none">
          min
        </span>
      </span>
    </div>
    """
  end

  def countdown(%{mode: :seconds} = assigns) do
    assigns = assign_countdown(assigns)

    ~H"""
    <div
      id={"countdown-sec-#{@kid.id}"}
      data-mode="seconds"
      phx-remove={
        JS.transition("animate-cd-fade motion-reduce:animate-none motion-reduce:opacity-0", time: 600)
      }
      class="animate-cd-grow col-start-1 row-start-1 flex h-[70px] items-center gap-[10px] rounded-full border-[3px] border-solid border-white pl-[5px] pr-5 motion-reduce:animate-none"
      style={"background-color: var(--routine-#{@routine}); color: var(--routine-#{@routine}-content)"}
    >
      <span
        class="flex size-[58px] shrink-0 items-center justify-center rounded-full"
        style={"background: conic-gradient(var(--routine-#{@routine}-content) 0deg #{@angle}deg, color-mix(in oklab, var(--routine-#{@routine}-content) 22%, transparent) #{@angle}deg 360deg)"}
      >
        <span
          id={"countdown-glyph-#{@kid.id}"}
          class="animate-cd-beat flex size-11 items-center justify-center rounded-full motion-reduce:animate-none"
          style={"background-color: var(--color-base-100); color: #{if @routine == :morning, do: "var(--routine-morning-content)", else: "var(--routine-evening)"}; line-height: 0"}
        >
          <.bonus_glyph routine={@routine} width={34} />
        </span>
      </span>
      <span class="font-sans text-[56px] font-extrabold tabular-nums leading-none">
        {@text}
      </span>
    </div>
    """
  end

  defp assign_countdown(assigns) do
    assigns
    |> assign(:angle, Float.round(assigns.fraction * 360, 1))
    |> assign(:text, BearCub.Countdown.display(assigns))
  end

  @doc """
  Header band: the color block, not the name, is the primary identifier
  (FR-5a) — a pre-reader finds their column by color. Never dimmed:
  identity stays legible across the kitchen. The points badge belongs to
  the child, not the routine (D43): it renders unconditionally here,
  independent of the routine card's collapse/expand and of any routine
  state below. The completion icon (D44) is the retired routine header
  bar's replacement: it is now the routine card's collapse/expand
  affordance, so it renders whenever the routine is complete and
  reveal-eligible (`reveal?`), in both the collapsed band and the manually
  re-expanded rows (D47).
  """
  attr :kid, :map, required: true
  attr :routine, :atom, required: true
  attr :reveal?, :boolean, required: true
  attr :failed?, :boolean, required: true
  attr :early_bird?, :boolean, required: true
  attr :night_owl?, :boolean, required: true
  attr :r, :integer, required: true, doc: "the routine bonus as priced for this routine-day"
  attr :e, :integer, required: true, doc: "the early bird bonus as priced for this routine-day"
  attr :n, :integer, required: true, doc: "the Night Owl bonus as priced for this routine-day"
  attr :points, :integer, required: true
  attr :streak, :integer, required: true, doc: "the current good-standing streak (D157)"
  attr :pending_request?, :boolean, required: true

  attr :countdown, :map,
    default: nil,
    doc: "`Countdown.state/5`, or nil; the left slot shows it when the reward is not due"

  def banner(assigns) do
    ~H"""
    <header
      class="relative flex items-center justify-center py-5"
      style={"background-color: #{@kid.color}"}
    >
      <button
        :if={@reveal?}
        type="button"
        id={"completion-icon-#{@kid.id}"}
        phx-click="toggle-band"
        phx-value-kid-id={@kid.id}
        class="absolute left-5 flex items-center justify-center transition active:scale-[0.99]"
      >
        <span class="relative block h-20 w-24">
          <.icon
            name={completion_icon_name(@routine)}
            class="absolute left-[20px] top-[4px] size-14 text-white drop-shadow-sm"
          />
          <%!-- Bonus badge (D44, D47, D104, D149): shown only "if not
               forfeited" — forfeited? = failed?, the routine-day
               boolean. A forfeited bonus shows no badge at all rather
               than a zeroed one; the icon itself still toggles. On an
               early morning the badge carries R + E as one number
               (D104); an evening before the kid's Sleepy Bear cutoff is
               the mirror, R + N (D136, D150). --%>
          <span
            :if={not @failed?}
            id={"completion-badge-#{@kid.id}"}
            class="absolute left-[62px] top-[4px] z-[1] flex items-center rounded-full border-2 bg-success px-[7px] py-1 font-reward text-sm font-black text-success-content drop-shadow-sm"
            style={"border-color: #{@kid.color}"}
          >
            +{@r + if(@early_bird?, do: @e, else: 0) + if(@night_owl?, do: @n, else: 0)}
          </span>
          <%!-- EARLY BIRD / SLEEPY BEAR pill (D100, D104, D136, D149,
               D150): a white pill in the kid's own color with the bird or
               bear peeking out of it. Same forfeit rule as the badge —
               both flags are already false when failed — and pill and
               glyph render together. The night-owl-{id} id is a kept
               test anchor (D150). --%>
          <.bonus_pill
            :if={@early_bird?}
            id={"early-bird-#{@kid.id}"}
            routine={:morning}
            color={@kid.color}
          >
            EARLY BIRD
          </.bonus_pill>
          <.bonus_pill
            :if={@night_owl?}
            id={"night-owl-#{@kid.id}"}
            routine={:evening}
            color={@kid.color}
          >
            SLEEPY BEAR
          </.bonus_pill>
        </span>
      </button>
      <%!-- Left slot (D148): reward, countdown or nothing — the countdown
           needs the routine incomplete, the reward complete, so never both. --%>
      <%!-- Always present, empty when there is nothing to show: phx-remove
           runs only on the element morphdom discards, so the fade has to
           sit on a pill that leaves, not on a wrapper that leaves with it.
           The grid stacks a leaving pill under the arriving one. --%>
      <div class="absolute left-4 top-1/2 grid -translate-y-1/2 items-center">
        <.countdown
          :if={@countdown && not @reveal?}
          kid={@kid}
          routine={@routine}
          mode={@countdown.mode}
          remaining_ms={@countdown.remaining_ms}
          fraction={@countdown.fraction}
        />
      </div>
      <h1 class="font-reward text-4xl font-black tracking-tight text-white drop-shadow-sm">
        {@kid.name}
      </h1>
      <%!-- Points badge + gift button (Story 05, D65): grouped on the
           right — badge and shop are the same economy, so they read
           as one unit. The badge's own tap gesture stays unbound
           (the deferred points-stats affordance is not precluded);
           the gift button is a distinct gesture, always tappable,
           opening the shop regardless of the pending state its own
           glyph shows. --%>
      <div class="absolute right-5 flex items-center gap-2">
        <.streak_chip kid={@kid} streak={@streak} />
        <span
          id={"points-badge-#{@kid.id}"}
          class="flex items-center gap-1 rounded-full bg-white/20 px-3 py-1 font-reward text-lg font-black text-white drop-shadow-sm"
        >
          <.icon name="hero-star-solid" class="size-4" />
          {@points}
        </span>
        <button
          type="button"
          id={"gift-button-#{@kid.id}"}
          phx-click="open-shop"
          phx-value-kid-id={@kid.id}
          data-pending={@pending_request?}
          class="flex size-9 items-center justify-center rounded-full bg-white/20 text-xl leading-none transition active:scale-[0.99]"
        >
          <%= if @pending_request? do %>
            ⏳
          <% else %>
            🎁
          <% end %>
        </button>
      </div>
    </header>
    """
  end

  @doc """
  Standing band (Story 05, D95, D97, D98, D99): never text, just stars, so
  it reads for a pre-reader across the room. Thirteen uniform size-9 stars
  (D99, dropping D98's five/three/five size arc after on-screen review).
  The caller renders it only while the kid is in standing.
  """
  attr :kid, :map, required: true

  def standing_band(assigns) do
    ~H"""
    <div
      id={"standing-band-#{@kid.id}"}
      class="row-start-2 flex h-16 min-w-full items-center justify-center gap-4 bg-success overflow-visible"
    >
      <div class="w-max whitespace-nowrap">
        <.icon
          :for={_ <- 1..13}
          name="hero-star-solid"
          class="size-9 text-success-content"
        />
      </div>
    </div>
    """
  end

  @doc """
  Events strip: chronological, blended per-kid + family list (FR-19).
  All-day events pin to the top (FR-22); a family event renders as a
  neutral chip + house glyph in every column, a personal event as the
  kid-color dot.
  """
  attr :kid, :map, required: true
  attr :events, :list, required: true

  def events_strip(assigns) do
    ~H"""
    <div id={"events-#{@kid.id}"} class="border-b border-base-300 px-5 py-3">
      <p :if={@events == []} class="text-sm text-base-content/40">No events today</p>
      <ul :if={@events != []} class="flex flex-col gap-1.5">
        <li
          :for={event <- @events}
          id={"event-#{@kid.id}-#{event.uid}"}
          class="flex items-center gap-2 text-sm"
        >
          <span
            :if={!event.family?}
            class="size-2.5 shrink-0 rounded-full"
            style={"background-color: #{@kid.color}"}
          />
          <span
            :if={event.family?}
            class="flex size-4 shrink-0 items-center justify-center rounded-full bg-base-300"
          >
            <.icon name="hero-home" class="size-3 text-base-content/60" />
          </span>
          <span class="shrink-0 text-base-content/40">{event_time_label(event)}</span>
          <span class="truncate font-medium">{event.summary}</span>
        </li>
      </ul>
    </div>
    """
  end

  @doc """
  Stake bar (D105): the routine's all-or-nothing prize and progress toward
  it, with no words — a routine-colored icon, one segment per chore filling
  in the kid's color, and the single +R chip (routine chores carry no
  per-chore number). Paid (every chore done): segments, chip and ground all
  go success-green, the app's one "you earned something" color. Forfeited
  (a routine chore failed): the chip disappears, exactly as the header
  badge does (D47); the segments stay. Present in the rows and band states
  alike — the band is the paid state, not a different card — and absent in
  the shop.
  """
  attr :kid, :map, required: true
  attr :routine, :atom, required: true
  attr :chores, :list, required: true
  attr :complete?, :boolean, required: true
  attr :failed?, :boolean, required: true

  attr :r, :integer,
    required: true,
    doc: "the routine bonus: live while unpaid, as priced once paid"

  def stake_bar(assigns) do
    ~H"""
    <div
      id={"stake-bar-#{@kid.id}"}
      data-paid={@complete?}
      class={[
        "flex items-center gap-3 border-b px-4 py-3 transition-colors duration-300",
        @complete? && "border-[color:var(--paid-edge)] bg-[color:var(--paid-tint)]"
      ]}
      style={
        if(@complete?,
          do: nil,
          else:
            "background-color: var(--routine-#{@routine}-tint); border-color: var(--routine-#{@routine}-edge)"
        )
      }
    >
      <span class="flex shrink-0" style={"color: var(--routine-#{@routine})"}>
        <.icon name={completion_icon_name(@routine)} class="size-8" />
      </span>
      <%!-- Filled segments lead, left to right, as a progress bar
           fills — the segments count completions, they are not the
           rows (which sink done-last). --%>
      <div class="grid flex-1 auto-cols-fr grid-flow-col gap-1.5">
        <span
          :for={done? <- Enum.sort_by(@chores, &(not &1.done?)) |> Enum.map(& &1.done?)}
          data-segment
          data-filled={done?}
          class={[
            "block h-3.5 rounded transition-colors duration-300",
            @complete? && "bg-success"
          ]}
          style={stake_segment_style(done?, @complete?, @routine, @kid.color)}
        />
      </div>
      <span
        :if={not @failed?}
        id={"stake-chip-#{@kid.id}"}
        class={[
          "flex shrink-0 items-center rounded-full px-3 py-0.5 font-reward text-lg font-black transition-colors duration-300",
          if(@complete?,
            do: "bg-success text-success-content drop-shadow-sm",
            else: "bg-base-content/10 text-base-content/80"
          )
        ]}
      >
        +{@r}
      </span>
    </div>
    """
  end

  @doc """
  Routine-penalty strip: a single capped −R shown once while any routine
  chore is failed-and-not-redone (D45, D46) — never a per-chore sum (two
  fails still show one −R, not −2R). Explicit row-start so the chore list
  below always lands in the 1fr track, strip present or not.
  """
  attr :kid, :map, required: true
  attr :penalty, :integer, required: true, doc: "the routine bonus as priced at the first fail"

  def routine_penalty(assigns) do
    ~H"""
    <div
      id={"routine-penalty-#{@kid.id}"}
      class="row-start-1 flex items-center justify-center gap-2 bg-warning px-4 py-2 font-reward text-base font-black text-warning-content"
    >
      <.icon name="hero-exclamation-triangle" class="size-5" />
      <span>−{@penalty}</span>
    </div>
    """
  end

  @doc "The temperature band's emoji (D141)."
  def temp_glyph(:hot), do: "\u{1F975}"
  def temp_glyph(:normal), do: "\u{1F642}"
  def temp_glyph(:cold), do: "\u{1F976}"

  @doc """
  The precipitation type's emoji (D141); snow wins over rain upstream. ☀ and
  ❄ default to text presentation, so U+FE0F is spelled out.
  """
  def precip_glyph(:none), do: "\u2600\uFE0F"
  def precip_glyph(:rain), do: "\u2614"
  def precip_glyph(:snow), do: "\u2744\uFE0F"

  attr :chore, :map, required: true
  attr :done?, :boolean, required: true
  attr :failed?, :boolean, default: false
  attr :kid, :map, required: true
  attr :routine, :atom, required: true
  attr :extra?, :boolean, default: false
  # In the slot group: a done row here is mid-beat (D106) — it keeps the
  # slot's size and corners, filled and solid-edged, until it sinks; the
  # sink ghost then collapses in that same look.
  attr :slot?, :boolean, default: false
  # The move animation's two halves (D107), each set for the one render
  # where the row sank or rose (see `sink_done/5`): `grow?` on the real
  # row in its new stack, which grows open from nothing; `ghost?` on its
  # inert copy left in the old one, which collapses to nothing at the same
  # time.
  attr :grow?, :boolean, default: false
  attr :ghost?, :boolean, default: false
  # The count panel (Story 04): only ever true for a pending counted
  # extra. While set, the row carries no `phx-click` of its own at all —
  # the structural trap named in the design: a ±tap or the name-row close inside
  # an `<li phx-click="toggle-chore">` would otherwise bubble into a
  # completion.
  attr :counting?, :boolean, default: false
  attr :count, :integer, default: nil
  # The confirm beat (D117): the panel has been tapped to completion and
  # holds its pressed look, inert, until the row lands as done.
  attr :confirmed?, :boolean, default: false
  # The persisted count and its earned/lost value (Story 05, D112): set
  # only for a done or failed-and-not-redone counted extra. `effort_count`
  # is what ×N shows; `value` is the chip's own figure — for a flat chore
  # it is plain `chore.points`, unchanged from before this story.
  attr :effort_count, :integer, default: nil
  attr :value, :integer, default: nil
  # Today's household reading (D141), passed only to flagged routine rows
  # while the morning is active; the row decides whether it still shows.
  attr :weather, :map, default: nil

  @doc """
  Shared row markup for both routine chores and extras (D34 technical
  notes: extras are chores, so this is the same tappable row) — extras
  render as a slot in the kid's own color (D117) and never take a routine
  tint. A failed-and-not-redone card (D45, D46) shows a warning icon; a
  failed extra also carries its own −N, but a failed routine chore never
  does — its impact is the single capped routine-penalty strip shown once
  above.
  """
  def chore_row(assigns) do
    # The ghost is a second element for the same chore, so every id it
    # carries takes its own prefix — `#chore-N` stays the real row's, the
    # one LiveView relocates into the done stack.
    assigns = assign(assigns, :dom, if(assigns.ghost?, do: "ghost", else: "chore"))

    assigns =
      assign(
        assigns,
        :show_weather?,
        assigns.weather != nil and not assigns.done? and not assigns.failed? and
          not assigns.ghost? and not assigns.extra?
      )

    ~H"""
    <li
      id={"#{@dom}-#{@chore.id}"}
      data-done={@done? and not @counting?}
      data-failed={@failed?}
      data-counting={@counting?}
      phx-hook=".ScrollIntoView"
      phx-click={(not @ghost? and not @counting?) && "toggle-chore"}
      phx-value-chore-id={@chore.id}
      phx-throttle="1000"
      class={
        [
          "select-none overflow-hidden transition-all",
          if(@counting?,
            do: "flex flex-col items-stretch gap-1 py-4",
            else: "flex cursor-pointer items-center gap-4 active:scale-[0.97]"
          ),
          # Move animation (D107), sink and rise alike: the real row grows
          # open from height 0 in its new stack, pushing the rows beneath
          # it down, while its ghost collapses in the place it left. The
          # real row is the *same* DOM node LiveView relocates between the
          # two lists (matched by id — confirmed against the patch, not
          # assumed), so a CSS transition has no before-state to run from
          # across the move and `phx-remove`/`phx-mounted` never fire; a
          # CSS animation starts the moment its class lands, exactly like
          # the check disc's `animate-pop`. One render only: the next patch
          # drops the class and the ghost, which is also what snaps a tap
          # mid-animation to its end state. `overflow-hidden` above keeps
          # the content clipped while the box is short. Under reduced
          # motion the ghost is simply not shown.
          @grow? && "animate-sink-grow motion-reduce:animate-none",
          @ghost? && "animate-sink-collapse motion-reduce:hidden",
          cond do
            # Count panel (Story 04): the row expands to hold it, in place —
            # the pending slot's own ground, its dashed edge turned solid
            # (D117). Ahead of the done branches: a confirmed panel is
            # already `done?` but holds its look through the beat.
            @counting? -> "rounded-xl border-[3px] border-solid px-3.5"
            # Mid-beat (D106), and then the sink ghost: the slot, filled —
            # the same box as the dashed slot so nothing around it shifts.
            @done? and @slot? -> "h-24 rounded-xl border-[3px] px-3.5"
            # Done extra (D117): a row of the joined mass at the top of the
            # extras group. The mass's wrapper clips the outer corners; 17px
            # (14 padding + 3 border) lines the emoji up with the slots.
            @done? and @extra? -> "h-20 border-t border-white/35 px-[17px] first:border-t-0"
            # Done routine row: kid-color fill, flush, a hairline between
            # consecutive done rows (D105). The rise ghost collapses in this
            # look.
            @done? -> "h-20 border-t border-white/35 px-[27px] first:border-t-0"
            # Pending extra (D117): a dashed slot in the kid's own color,
            # exactly as a routine slot is one in the routine's.
            @extra? -> "h-24 rounded-xl border-[3px] border-dashed px-3.5"
            # Pending routine chore: a dashed slot in the routine tint (D105).
            true -> "h-24 rounded-xl border-[3px] border-dashed px-3.5"
          end
        ]
      }
      style={chore_card_style(@done? and not @counting?, @extra?, @slot?, @routine, @kid.color)}
    >
      <%= if @counting? do %>
        <%!-- The count panel (D111 as amended by D116): two rows on the
             extra's own surface. The name area is the close target and the
             stepper sits *beside* it, not inside it, so a ± tap never
             reaches the close binding. Both discs stay tappable at their
             bounds (opacity only, never `disabled`) — the server clamps. --%>
        <div class="flex h-18 items-center gap-4">
          <div
            id={"count-name-#{@chore.id}"}
            phx-click="count-cancel"
            phx-value-kid-id={@kid.id}
            class="flex h-full min-w-0 flex-1 cursor-pointer items-center gap-4"
          >
            <span class="text-[2.5rem] leading-none">{@chore.icon}</span>
            <span class="truncate text-2xl font-bold">{@chore.name}</span>
          </div>
          <div class="flex shrink-0 items-center gap-2">
            <button
              type="button"
              id={"count-dec-#{@chore.id}"}
              phx-click="count-step"
              phx-value-kid-id={@kid.id}
              phx-value-dir="dec"
              aria-label="Fewer"
              class={[
                "flex size-16 items-center justify-center rounded-full",
                @count <= 1 && "opacity-30"
              ]}
              style="background: var(--extra-card-control)"
            >
              <svg
                viewBox="0 0 24 24"
                class="size-8"
                fill="none"
                stroke="currentColor"
                stroke-width="3"
                stroke-linecap="round"
                aria-hidden="true"
              >
                <path d="M5 12h14" />
              </svg>
            </button>
            <span
              id={"count-value-#{@chore.id}"}
              class="min-w-20 text-center text-[56px] font-extrabold leading-none tabular-nums"
            >
              {@count}
            </span>
            <button
              type="button"
              id={"count-inc-#{@chore.id}"}
              phx-click="count-step"
              phx-value-kid-id={@kid.id}
              phx-value-dir="inc"
              aria-label="More"
              class={[
                "flex size-16 items-center justify-center rounded-full",
                @count >= @chore.unit_max && "opacity-30"
              ]}
              style="background: var(--extra-card-control)"
            >
              <svg
                viewBox="0 0 24 24"
                class="size-8"
                fill="none"
                stroke="currentColor"
                stroke-width="3"
                stroke-linecap="round"
                aria-hidden="true"
              >
                <path d="M12 5v14M5 12h14" />
              </svg>
            </button>
          </div>
        </div>
        <button
          type="button"
          id={"count-confirm-#{@chore.id}"}
          phx-click="count-confirm"
          phx-value-kid-id={@kid.id}
          phx-throttle="1000"
          class={[
            "flex h-20 w-full items-center justify-center rounded-xl border-[3px] font-reward text-[44px] font-black transition-all",
            if(@confirmed?,
              do:
                "scale-[0.97] border-transparent bg-success text-success-content ring-[6px] ring-success/25",
              else:
                "border-[color:var(--paid-edge)] bg-[color:var(--paid-tint)] text-[color:var(--paid-content)]"
            )
          ]}
        >
          +{@chore.points + @count * @chore.unit_rate}
        </button>
      <% else %>
        <span class="text-[2.5rem] leading-none">{@chore.icon}</span>
        <span class={["text-2xl font-bold", @done? && "text-white drop-shadow-sm"]}>
          {@chore.name}
        </span>
        <%!-- The count on a completed/failed counted extra (Story 05,
             D112): informational, off font-reward — the system sans, muted
             against whichever surface the row is on. A flat extra's
             `effort_count` is nil, so nothing renders here for it. --%>
        <span
          :if={@effort_count}
          id={"#{@dom}-effort-#{@chore.id}"}
          class={[
            "text-lg font-medium",
            if(@done?, do: "text-white/70", else: "text-base-content/50")
          ]}
        >
          ×{@effort_count}
        </span>
        <span
          :if={@done? and @extra?}
          id={"#{@dom}-earned-#{@chore.id}"}
          class="ml-auto flex items-center rounded-full bg-success px-3 py-1 font-reward font-black text-success-content drop-shadow-sm"
        >
          +{@value}
        </span>
        <%!-- Circled check (D105): a white disc carrying the check in the
             kid's own color — it reads as "earned", not as a target, which is
             also why a pending row has nothing in this column. --%>
        <span
          :if={@done?}
          id={"#{@dom}-check-#{@chore.id}"}
          class={
            [
              "flex size-9 shrink-0 items-center justify-center rounded-full bg-white drop-shadow-sm",
              not @extra? && "ml-auto",
              # The disc springs in as the just-sunk row grows open — moved
              # there from D106's hold once the beat got shorter than the
              # pop — and only then: a done row at page load or after a
              # reconnect is a re-inserted element, and re-popping below the
              # fold is noise. The ghost is a new element too, mid-collapse:
              # no re-pop.
              @grow? && "animate-pop"
            ]
          }
          style={"color: #{@kid.color}"}
        >
          <.icon name="hero-check" class="size-6" />
        </span>
        <.icon
          :if={@failed? and not @extra?}
          name="hero-exclamation-triangle"
          class="ml-auto size-10 text-warning"
        />
        <span
          :if={@failed? and @extra?}
          id={"#{@dom}-penalty-#{@chore.id}"}
          class="ml-auto flex items-center gap-2 text-warning"
        >
          <.icon name="hero-exclamation-triangle" class="size-8" />
          <span class="font-reward text-2xl font-black">−{@value}</span>
        </span>
        <span
          :if={@show_weather?}
          id={"#{@dom}-weather-#{@chore.id}"}
          class="ml-auto flex shrink-0 items-center gap-3 pr-1.5"
          aria-hidden="true"
        >
          <span class="text-[46px] leading-none">{temp_glyph(@weather.temp)}</span>
          <span class="text-[46px] leading-none">{precip_glyph(@weather.precip)}</span>
        </span>
      <% end %>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollIntoView">
        // An extra row that opens as the count panel scrolls itself into view
        // inside the extras list (D117). The row is the same <li> as the
        // pending slot, so `mounted` never sees the panel open — `updated`
        // acts when data-counting turns on. Every row carries the hook (the
        // name is only expanded from a literal attribute); only a counting
        // extra ever sets data-counting, so the rest never scroll.
        export default {
          mounted() {
            this.counting = this.el.hasAttribute("data-counting")
            if (this.counting) this.reveal()
          },
          updated() {
            const counting = this.el.hasAttribute("data-counting")
            if (counting && !this.counting) this.reveal()
            this.counting = counting
          },
          // The row is still opening when data-counting flips, so a single
          // scroll measures a short row and stops before the panel's foot.
          // Scroll now, then once more when the expansion has settled.
          reveal() {
            const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches
            this.el.scrollIntoView({block: "nearest", behavior: reduce ? "auto" : "smooth"})
            clearTimeout(this.settle)
            this.settle = setTimeout(() => this.el.scrollIntoView({block: "nearest"}), 400)
          },
          destroyed() {
            clearTimeout(this.settle)
          }
        }
      </script>
    </li>
    """
  end

  @doc """
  Collapse band (states 2/3, D33/D34): a single bounded card — message
  inside, no tint fill (dropped, D98); no header bar edge (retired, D44,
  D48). `self-start` keeps it hugging its own content height instead of
  stretching to fill the column (docs/design-language.org). The banner
  completion icon is the tap target back to the rows, not the card itself
  (D44).
  """
  attr :kid, :map, required: true
  attr :routine, :atom, required: true

  def band(assigns) do
    ~H"""
    <div id={"band-#{@kid.id}"} class="flex flex-col self-start">
      <span class="px-4 py-3 text-center font-reward text-lg font-extrabold">
        {band_message(@routine)}
      </span>
    </div>
    """
  end

  @doc """
  Reward card (Story 05/08, D65-D67, D75-D77): one tap to ask, one tap to
  take it back — no modal, no confirmation either way — the seven-row
  precedence table (D66/D77) is the whole guard, so an
  unaffordable/unavailable/claimed/declined card carries no phx-click at
  all and is inert under a tap; a pending card's phx-click withdraws rather
  than re-asking.
  """
  attr :reward, :map, required: true
  attr :state, :atom, required: true
  attr :kid, :map, required: true

  def reward_card(assigns) do
    ~H"""
    <li
      id={"reward-card-#{@reward.id}-#{@kid.id}"}
      data-card-state={@state}
      phx-click={reward_card_click(@state)}
      phx-value-kid-id={@kid.id}
      phx-value-reward-id={@reward.id}
      phx-throttle="1000"
      class={
        [
          "flex h-24 items-center gap-5 px-6 transition-all",
          # Pending (row 3) is tappable too — its tap withdraws
          # (D76) — so it shares the tappable treatment with
          # available (row 7).
          @state in [:available, :pending] && "cursor-pointer active:scale-[0.99]",
          # Rows 4-6 (declined/claimed/locked) share one dim
          # treatment (D66) — pending (row 3) is its own untappable
          # treatment, carrying the banner's own =⏳= glyph rather
          # than joining the dim group.
          @state in [:declined, :claimed, :locked] && "opacity-45"
        ]
      }
      style="background-color: var(--extra-card-background); color: var(--extra-card-content)"
    >
      <span class="text-[2.5rem] leading-none">{@reward.icon}</span>
      <span class="font-reward text-2xl font-extrabold">{@reward.name}</span>
      <span class="ml-auto flex items-center gap-1 font-reward text-lg font-black">
        <.icon name="hero-star-solid" class="size-4" />
        {@reward.points}
      </span>
      <span :if={@state == :pending} class="text-3xl leading-none">⏳</span>
      <%!-- Declined/claimed carry color, not just glyph (design-
           language dim+glyph Ruling, amended 2026-07-25): an
           uncolored ✕ reads as a close control on a surface that
           has one, so declined is error red; claimed is success
           green, the same family the +N chip carries. Locked
           stays neutral — it is a state, not a verdict. --%>
      <.icon :if={@state == :declined} name="hero-x-mark" class="size-9 text-error" />
      <.icon :if={@state == :claimed} name="hero-check" class="size-9 text-success" />
      <.icon
        :if={@state == :locked}
        name="hero-lock-closed"
        class="size-9 text-base-content/60"
      />
    </li>
    """
  end

  defp reward_card_click(:available), do: "request-reward"
  defp reward_card_click(:pending), do: "withdraw-request"
  defp reward_card_click(_), do: nil

  # Done: full kid-color fill, no border of any kind — the fill is already
  # the child's own color. Pending routine chore: routine tint fill with a
  # dashed routine-colored edge (D105) — the column already carries
  # ownership, so no child-color border here.
  defp chore_card_style(true, _extra?, true, _routine, kid_color),
    do: "background-color: #{kid_color}; border-color: #{kid_color}"

  defp chore_card_style(true, _extra?, false, _routine, kid_color),
    do: "background-color: #{kid_color}"

  # Pending extra (D117): the kid's color at 12% ground and 45% edge, mixed
  # into the page surface like the routine tints. The column's `kid-scope`
  # derives both from its one `--kid`, so they are tokens here.
  defp chore_card_style(false, true, _slot?, _routine, _kid_color),
    do:
      "background-color: var(--kid-tint); border-color: var(--kid-edge); color: var(--extra-card-content)"

  defp chore_card_style(false, false, _slot?, routine, _kid_color),
    do:
      "background-color: var(--routine-#{routine}-tint); border-color: var(--routine-#{routine}-edge)"

  # Stake segment (D105): paid rows take the class-level bg-success; a done
  # segment before payout is the kid's color; an empty one the routine edge.
  defp stake_segment_style(_done?, true, _routine, _kid_color), do: nil
  defp stake_segment_style(true, false, _routine, kid_color), do: "background-color: #{kid_color}"

  defp stake_segment_style(false, false, routine, _kid_color),
    do: "background-color: var(--routine-#{routine}-edge)"

  defp completion_icon_name(:morning), do: "hero-sun-solid"
  defp completion_icon_name(:evening), do: "hero-moon-solid"

  defp band_message(:morning), do: Messages.morning_complete()
  defp band_message(:evening), do: Messages.evening_complete()

  # FR-22: an event clipped at the start of today's window (it started
  # before today) shows only its end — "until 2:00 PM" — rather than a
  # start time that isn't actually today's.
  defp event_time_label(%{all_day: true}), do: "All day"

  defp event_time_label(%{clipped_start?: true, ends_at: ends_at}),
    do: "until #{format_time(ends_at)}"

  defp event_time_label(%{starts_at: starts_at}), do: format_time(starts_at)

  defp format_time(%DateTime{} = utc_time) do
    utc_time
    |> DateTime.shift_zone!(LocalTime.timezone())
    |> Calendar.strftime("%-I:%M %p")
  end
end
