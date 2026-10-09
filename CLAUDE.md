Bear Cub is a self-hosted family chore + calendar dashboard: a fridge-mounted tablet kiosk (Fully Kiosk Browser, Android WebView) where two kids tap through daily routines, plus a phone-first parent admin UI reached over Tailscale. Phoenix LiveView + SQLite, deployed as a NixOS module on a home server.

Active initiative: docs/2026-10-08-bonus-countdown/ (previously: docs/2026-10-07-weather-indicator/)

## Repo conventions (pre-kit project, adopted mid-way through the MVP initiative)

- Decision Log: this repo runs one monotonic Decision Log sequence across initiatives — historical D-entries remain in situ inside each initiative's DESIGN.org `* Decision Log` (originating in the MVP chain's §10, 'Design decision log', which extended PRD §9), but as of the workflow-kit 0.7.0 adoption, new entries mint into the shared `docs/decisions.org` instead (see Authoritative docs below). Advisories adopted per kit default.
- Early work predates the kit: no stories exist for it; git history is its record.
- Stories are batch-scoped: /workflow-kit:user-stories is always invoked with an explicit batch scope and only excerpts the DESIGN sections that batch implements. ("Phase N" is at most a decorative label an initiative puts on a batch heading — never a repo-level concept.)
- Gate close (`/workflow-kit:phase-close`) is judged on **localhost QA** [2026-09-06, revised 2026-10-07]: the dev server, a kiosk state staged with `BearCub.Dev.Scenarios` (`dev/`, dev/test only — run it from `iex -S mix phx.server` or Tidewave so it acts inside the server VM), viewed in Chrome or Safari at **1280 × 800 CSS px** (the Lenovo IdeaTab's viewport; its 2560 × 1600 panel is 2× DPR). Screenshots at that size are the gate evidence, and the gate is the only pre-deploy check. There is no tablet checklist: the former PRD §7 on-device gate (Fully Kiosk rendering, 5-chore no-scroll, sleep/wake reconnect) became a post-deploy verification on 2026-09-06 and was ruled optional on 2026-10-07, after three gates in a row wrote tablet items as "still to run" and none was ever recorded as run. A gate record may note what only the tablet could confirm, but lists nothing as owed, and no backlog entry is made for it; anyone who happens to look at the tablet after a deploy and finds a defect files it as a bug. Delivered PRDs do not bind ops process; the human ruled this on 2026-09-06.
- Testing per MVP DESIGN §11 (`docs/2026-07-09-mvp/DESIGN.org`): LiveView integration tests are part of story ACs wherever a flow is touched, regardless of the mvp DoD.
- Brainstorm session outputs belong in docs/superpowers/specs/; initiative directories (docs/YYYY-MM-DD-<slug>/) contain only chain documents (PRD, DESIGN, PLAN, stories/) plus SKETCH.org — the scratch file the PRD conversation parks design material in, kit-authored, committed with the PRD lock, never cited by a chain document.

## Weight class

personal-mvp. Personal family software with a real correctness bar: the mvp DoD applies, plus the MVP DESIGN §11 testing expectations in Repo conventions below.

Verify command: `mix precommit`

Local review: 1280 × 800 CSS px via `BearCub.Dev.Scenarios`

If the Chrome MCP extension is not connected, the gate review runs through the Playwright MCP tools (`browser_resize` to 1280 × 800, then `browser_take_screenshot` into the initiative directory); the first resize may not take effect on an already-loaded page (one measured 1200 × 817), so read `window.innerWidth` / `innerHeight` before capturing and check the file with `sips` afterwards; a full-page screenshot catches the fixed bottom tab bar mid-image, which is expected. Screenshots are committed to this public repo, so they carry no household data: no kid names, no calendar event text and no parent-entered chore names; the seeded routine names are fine. Until the review-mask scenario on the backlog exists, hide them in the page before capturing, and check the completed-routine states, where the extras list shows [2026-10-08]. Stage calendar events through `BearCub.Dev.Scenarios` (an events scenario is on the backlog) and never capture with the live dev cache in view, since it holds the family's real calendar [2026-10-08].

## Authoritative docs

The live chain is the active initiative (see the `Active initiative:` line above; `none` means no chain is open) — resolve the current PRD/DESIGN from there, not from a hardcoded path.

Repo-level, cumulative across initiatives (not scoped to any one chain):

- `docs/learnings.org` — Repo lessons: update rather than duplicate; delete entries that prove wrong.
- `docs/backlog.org` — Repo-level backlog: deferred work swept in from initiative PLAN Deferred sections at close, plus ad-hoc discovery; input for future initiative brainstorms. Ideas the PRD conversation sets aside land here too, one dated heading each. Holds open work only — entries marked DONE move to `docs/completed.org`.
- `docs/completed.org` — Completed backlog items, full capture/triage/done trail intact; append-only archive.
- `docs/decisions.org` — Repo-level Decision Log: one monotonic D-sequence across all initiatives, never inside an initiative directory; each DESIGN.org's `* Decision Log` section is a pointer to it, with entry rules living in the workflow-kit org-conventions skill.

Any change touching kids' view styling, colors, or component visuals: read `docs/design-language.org` first; its invariants and rulings are binding.

Closed / historical — record for each initiative's era, superseded wherever a later initiative's decisions say so:

- `docs/2026-07-09-mvp/PRD.org` — MVP requirements (FR-x), success criteria, decision log §9
- `docs/2026-07-09-mvp/DESIGN.org` — MVP schema, topology, decision log §10 (D-entries D1–D26)
- `docs/2026-07-11-extras/PRD.org` — Extras requirements, success criteria (invariant contract)
- `docs/2026-07-11-extras/DESIGN.org` — Extras schema, topology, `* Decision Log` (D-entries D27–D38)
- `docs/2026-07-15-gamification-points/PRD.org` — Gamification: Points requirements, success criteria
- `docs/2026-07-15-gamification-points/DESIGN.org` — Points derivation, fail-on-inspection, `* Decision Log` (D-entries D39–D55)
- `docs/2026-07-25-rewards-redemption/PRD.org` — Rewards / Redemption requirements, success criteria
- `docs/2026-07-25-rewards-redemption/DESIGN.org` — Rewards/redemptions schema, kiosk shop, approval queue, `* Decision Log` (D-entries D57–D77)
- `docs/2026-09-04-chore-lifecycle/` — Date-bounded roster (`active_from`/`archived_on`), closes D72 roster drift; decisions in `docs/decisions.org`
- `docs/2026-09-05-good-standing/` — Good-standing band and ring; decisions in `docs/decisions.org`
- `docs/2026-09-20-effort-multiplier/` — Counted chores (base + rate × count, frozen at creation); decisions in `docs/decisions.org`
- `docs/2026-10-04-routine-schedule/` — Append-only `schedule_versions`, each points term priced by the version in force at its instant, admin Schedule page; decisions in `docs/decisions.org`

When code and these docs disagree, the docs win. DESIGN.org is amendable per the org-conventions two-log rules: a body edit surfacing new information pairs with a new D-entry in the `* Decision Log` and, post-canon, an Advisory — normally via /workflow-kit:update-design. PRD.org is locked: it is never edited by agents (the prd-lock hook enforces this); anything that conflicts with its FRs or success criteria is surfaced to me as Amendment questions, not fixed.

## Workflow

Pipeline: /workflow-kit:create-prd (the conversation that turns an idea into PRD.org) → design brainstorm (Superpowers, from PRD.org and SKETCH.org) → /workflow-kit:promote-design → /workflow-kit:user-stories (batch-scoped) → per story: TDD implementation, then /workflow-kit:story-closeout, then /workflow-kit:update-design → /workflow-kit:phase-close (gate close). One story per session, working from the story file's embedded Design excerpt as the source of truth. Out-of-scope discoveries are recorded as Deferred (story Technical Notes → PLAN.org), never fixed inline. Chain documents are org format, never markdown.

A request for a new feature, capability, or initiative goes to `/workflow-kit:create-prd` first, whether or not the request names it: that skill is the conversation that settles what is wanted, and a session does not invoke `superpowers:brainstorming` for such a request. Brainstorming is the design conversation: it runs once PRD.org exists, treats the PRD's Success Criteria as settled, and starts from SKETCH.org in the initiative directory. Bugs, bounded changes to existing behavior, and refactors go straight to Superpowers.

Model routing: `.claude/settings.json` sets this repo's default model to Sonnet — builder altitude, where TDD implementation runs. Kit skills and agents pin their own model per stage (story-closeout and its verifier on Sonnet; create-prd, promote-design, user-stories, update-design, phase-close on Opus), so the one human routing step is the brainstorm: run `/model opus` before starting one. When a builder struggles, escalate context (the missing recipe in the story or CLAUDE.md) before escalating model.

An implementation session refuses to start work over a dirty working tree; unexplained working-tree state is surfaced to the human, never classified-and-fixed by the session itself. (A session once misattributed and silently deleted the human's uncommitted scratch code — the incident this rule exists to prevent.)

## Design invariants (do not violate)

- **Routines are app constants** (`:morning`/`:evening` — see `BearCub.Routines`), never DB rows. Their timings and bonuses are append-only data in `schedule_versions` (`BearCub.Schedules`), and each points term is priced by the version in force at its instant. No routines table, no routine CRUD. (D8, D120)
- **Day state is derived, never stored**: "done" means a `completions` row with `local_date = today AND undone_at IS NULL`. Never add a `completed` flag, a reset job, or midnight machinery. Undo sets `undone_at` — completion rows are never deleted. (D10)
- **Calendar is a degradable overlay**: `BearCub.Chores` must never depend on `BearCub.Calendars`; calendar failures serve the cached payload and may never affect chore display.
- **ICS URLs are secrets in the DB**: `redact: true` on the field; never log URLs (log calendar labels), never let them reach git or error output.
- **Kiosk/admin fence**: the kiosk (`/`) must contain zero links or navigation to `/admin` — Fully Kiosk's URL lock is the only barrier.
- **All time logic takes a local datetime argument** (configured timezone, default `America/Los_Angeles`) — no `DateTime.utc_now()` buried in domain code, no clock mocking in tests.
- **Kids and chores are data**, seeded as placeholders only when the kids table is empty; seeding never modifies existing rows. Kid names never enter git (public repo).
- **Chore icons are emoji strings** (required field) — no icon asset pipeline.
- The reference render target is **Fully Kiosk's Android WebView on the tablet**, not desktop Chrome — but the *gate* is localhost QA at 1280 × 800 (Repo conventions above), and nothing is owed to the tablet after deploy. Anything that only Android can answer (font coverage, box-shadow rendering) is therefore designed out, not checked later — glyphs outside the emoji set ship as inline SVG, never as text relying on a font (D103).

## Implementation conventions

- Scaffold new resources with `mix phx.gen.live` / `mix phx.gen.context`, then reshape toward the design — don't hand-roll contexts, migrations, or PubSub wiring the generators provide.
- TDD red-green-refactor at both unit and LiveView layers (see MVP DESIGN §11 for the test map).

## Project guidelines

- Use `mix precommit` alias when you are done with all changes and fix any pending issues
- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps
- **Consult Tidewave early and often**: with `mix phx.server` running in dev, Tidewave's MCP tools (`/tidewave/mcp`) give live introspection of this running app — runtime state (`project_eval`), the database (`execute_sql_query`; as of Tidewave 0.9 the `get_ecto_schemas` tool is gone, so read schemas from source or `project_eval`), logs, docs, source locations. Reach for it before guessing at schema/route/behavior, and while iterating to check a change against the live app rather than re-deriving from source alone.
- **Stage kiosk states, don't hand-poke the dev database**: `BearCub.Dev.Scenarios` (`dev/bear_cub/dev/scenarios.ex`) holds one named scenario per reviewable kiosk state (`early_bird/1`, `midway/2` for a half-filled stake bar with sunk done rows, `effort/1` for done mornings each holding one counted extra (one untouched, one completed at x8), `reset/1`, `open/1` to force a routine window all day, `cutoff/1` to move the early bird cutoff so live taps count as early, `night_owl/1` for the evening mirror (sets `N`, every kid's cutoff for today two hours out; pair with `open(:evening)`), `countdown/2` to put a bonus cutoff minutes from now (`countdown(:morning, 10)`; `countdown(:evening, 20)` for every kid; `countdown(:evening, [{kid_id, 5}])` as the whole evening picture, an unlisted kid losing their cutoff; pair with `open/1`), `weather/1` to put a reading (`{:cold, :snow}` and the other eight combinations, `nil` for none) into the store and broadcast it, with `weather_chore/0,1` flagging each kid's first morning chore (or every one named) `shows_weather`; pair both with `open(:morning)`, and the Refresher overwrites a staged reading on its next tick when coordinates are set, `restore/0` to bring back the schedule from before the first of those two, `slow_weekend/0` for a valid custom weekend to review the admin Schedule page). `open/1` and `cutoff/1` write a real schedule version in force now and broadcast `:schedule_changed`, so they reach an already-open kiosk with no restart. `open/1` writes a zero-length window the Schedule page refuses to save back, so raise `R` for review with a version insert through `project_eval`, not from the page. Add a scenario when a feature adds a state worth looking at; run them through Tidewave `project_eval` so re-render broadcasts land in the running server. A server started before `dev/` joined `elixirc_paths` has no `Scenarios` module at all; `Code.require_file("dev/bear_cub/dev/scenarios.ex")` in `project_eval` loads it without a restart.

Phoenix, Elixir, Ecto, HEEx, LiveView, JS/CSS, and UI guidelines live in `.claude/rules/phoenix.md`, loaded on demand when a matching source, test, template, or asset file is read — not on every turn.
