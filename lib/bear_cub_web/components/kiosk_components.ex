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
  alias BearCub.Routines

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
  attr :points, :integer, required: true
  attr :pending_request?, :boolean, required: true

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
        <span class="relative flex items-center justify-center">
          <.icon
            name={completion_icon_name(@routine)}
            class="size-14 text-white drop-shadow-sm"
          />
          <%!-- Bonus badge (D44, D47, D104): shown only "if not
               forfeited" — forfeited? = failed?, the routine-day
               boolean. A forfeited bonus shows no badge at all rather
               than a zeroed one; the icon itself still toggles. On an
               early morning the badge carries R + E as one number
               (D104), and the EARLY pill below the sun says why. --%>
          <span
            :if={not @failed?}
            id={"completion-badge-#{@kid.id}"}
            class="absolute -right-4 -top-1 flex items-center rounded-full border-2 bg-success px-2 py-0.5 font-reward text-sm font-black text-success-content drop-shadow-sm"
            style={"border-color: #{@kid.color}"}
          >
            +{Routines.bonus() + if(@early_bird?, do: Routines.early_bird_bonus(), else: 0)}
          </span>
          <%!-- Early bird pill (D100, D104): a white EARLY pill under
               the sun in the kid's own color. Same forfeit rule as the
               badge — `early_bird?` is already false when failed. --%>
          <span
            :if={@early_bird?}
            id={"early-bird-#{@kid.id}"}
            class="absolute -bottom-1.5 left-1/2 -translate-x-1/2 rounded-full bg-white px-2 py-0.5 font-reward text-xs font-black tracking-wide drop-shadow-sm"
            style={"color: #{@kid.color}"}
          >
            EARLY
          </span>
        </span>
      </button>
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
        +{Routines.bonus()}
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

  def routine_penalty(assigns) do
    ~H"""
    <div
      id={"routine-penalty-#{@kid.id}"}
      class="row-start-1 flex items-center justify-center gap-2 bg-warning px-4 py-2 font-reward text-base font-black text-warning-content"
    >
      <.icon name="hero-exclamation-triangle" class="size-5" />
      <span>−{Routines.bonus()}</span>
    </div>
    """
  end

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
  # The persisted count and its earned/lost value (Story 05, D112): set
  # only for a done or failed-and-not-redone counted extra. `effort_count`
  # is what ×N shows; `value` is the chip's own figure — for a flat chore
  # it is plain `chore.points`, unchanged from before this story.
  attr :effort_count, :integer, default: nil
  attr :value, :integer, default: nil

  @doc """
  Shared row markup for both routine chores and extras (D34 technical
  notes: extras are chores, so this is the same tappable row) — extras
  render on the fixed neutral card surface instead of the routine tint. A
  failed-and-not-redone card (D45, D46) shows a warning icon; a failed
  extra also carries its own −N, but a failed routine chore never does —
  its impact is the single capped routine-penalty strip shown once above.
  """
  def chore_row(assigns) do
    # The ghost is a second element for the same chore, so every id it
    # carries takes its own prefix — `#chore-N` stays the real row's, the
    # one LiveView relocates into the done stack.
    assigns = assign(assigns, :dom, if(assigns.ghost?, do: "ghost", else: "chore"))

    ~H"""
    <li
      id={"#{@dom}-#{@chore.id}"}
      data-done={@done?}
      data-failed={@failed?}
      data-counting={@counting?}
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
            # Mid-beat (D106), and then the sink ghost: the slot, filled —
            # the same box as the dashed slot so nothing around it shifts.
            @done? and @slot? -> "h-24 rounded-xl border-[3px] px-3.5"
            # Done (routine or extra): kid-color fill, flush, a hairline
            # between consecutive done rows (D105). The rise ghost collapses
            # in this look.
            # Extras sit in a padded group (D116): a done extra spans that
            # padding so it stays a flush band.
            @done? and @extra? -> "-mx-2.5 h-20 border-t border-white/35 px-[27px] first:border-t-0"
            @done? -> "h-20 border-t border-white/35 px-[27px] first:border-t-0"
            # Count panel (Story 04): the row expands to hold it, in place —
            # same ownership border as the pending extra it replaces.
            @counting? -> "rounded-xl border-l-[length:var(--child-border-width)] px-6"
            # Pending extra: the fixed neutral card with the child-color
            # ownership border (docs/design-language.org).
            @extra? -> "h-24 rounded-xl border-l-[length:var(--child-border-width)] px-6"
            # Pending routine chore: a dashed slot in the routine tint (D105).
            true -> "h-24 rounded-xl border-[3px] border-dashed px-3.5"
          end
        ]
      }
      style={chore_card_style(@done?, @extra?, @slot?, @routine, @kid.color)}
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
          class="flex h-20 w-full items-center justify-center rounded-xl bg-success font-reward text-[44px] font-black text-success-content"
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
      <% end %>
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
  # the child's own color. Pending extra: fixed neutral surface plus the
  # child-color ownership border (docs/design-language.org). Pending routine
  # chore: routine tint fill with a dashed routine-colored edge (D105) — the
  # column already carries ownership, so no child-color border here.
  defp chore_card_style(true, _extra?, true, _routine, kid_color),
    do: "background-color: #{kid_color}; border-color: #{kid_color}"

  defp chore_card_style(true, _extra?, false, _routine, kid_color),
    do: "background-color: #{kid_color}"

  defp chore_card_style(false, true, _slot?, _routine, kid_color),
    do:
      "background-color: var(--extra-card-background); border-left-color: #{kid_color}; color: var(--extra-card-content)"

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
