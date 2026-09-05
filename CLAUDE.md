Bear Cub is a self-hosted family chore + calendar dashboard: a fridge-mounted tablet kiosk (Fully Kiosk Browser, Android WebView) where two kids tap through daily routines, plus a phone-first parent admin UI reached over Tailscale. Phoenix LiveView + SQLite, deployed as a NixOS module on a home server.

Active initiative: docs/2026-09-04-chore-lifecycle/

## Repo conventions (pre-kit project, adopted mid-way through the MVP initiative)

- Decision Log: this repo runs one monotonic Decision Log sequence across initiatives — historical D-entries remain in situ inside each initiative's DESIGN.org `* Decision Log` (originating in the MVP chain's §10, 'Design decision log', which extended PRD §9), but as of the workflow-kit 0.7.0 adoption, new entries mint into the shared `docs/decisions.org` instead (see Authoritative docs below). Advisories adopted per kit default.
- Early work predates the kit: no stories exist for it; git history is its record.
- Stories are batch-scoped: /workflow-kit:user-stories is always invoked with an explicit batch scope and only excerpts the DESIGN sections that batch implements. ("Phase N" is at most a decorative label an initiative puts on a batch heading — never a repo-level concept.)
- Gate close (`/workflow-kit:phase-close`) includes the PRD §7 on-device gate (Fully Kiosk rendering, 5-chore no-scroll, sleep/wake reconnect) as a manual human checklist — never CI'd, never skipped.
- Testing per DESIGN §11: LiveView integration tests are part of story ACs wherever a flow is touched, regardless of the mvp DoD.
- Brainstorm session outputs belong in docs/superpowers/specs/; initiative directories (docs/YYYY-MM-DD-<slug>/) contain only chain documents (PRD, DESIGN, PLAN, stories/).

## Weight class

personal-mvp. Personal family software with a real correctness bar: the mvp DoD applies, plus the DESIGN §11 testing expectations in Repo conventions below.

Verify command: `mix precommit`

## Authoritative docs

The live chain is the active initiative (see the `Active initiative:` line above) — resolve the current PRD/DESIGN from there, not from a hardcoded path.

Repo-level, cumulative across initiatives (not scoped to any one chain):

- `docs/learnings.org` — Repo lessons: update rather than duplicate; delete entries that prove wrong.
- `docs/backlog.org` — Repo-level backlog: deferred work swept in from initiative PLAN Deferred sections at close, plus ad-hoc discovery; input for future initiative brainstorms. Holds open work only — entries marked DONE move to `docs/completed.org`.
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

When code and these docs disagree, the docs win. DESIGN.org is amendable per the org-conventions two-log rules: a body edit surfacing new information pairs with a new D-entry in the `* Decision Log` and, post-canon, an Advisory — normally via /workflow-kit:update-design. PRD.org is locked: it is never edited by agents (the prd-lock hook enforces this); anything that conflicts with its FRs or success criteria is surfaced to me as Amendment questions, not fixed.

## Workflow

Pipeline from here: /workflow-kit:user-stories (batch-scoped) → per story: TDD implementation, then /workflow-kit:story-closeout, then /workflow-kit:update-design → /workflow-kit:phase-close (gate close). One story per session, working from the story file's embedded Design excerpt as the source of truth. Out-of-scope discoveries are recorded as Deferred (story Technical Notes → PLAN.org), never fixed inline. Chain documents are org format, never markdown.

Model routing: `.claude/settings.json` sets this repo's default model to Sonnet — builder altitude, where TDD implementation runs. Kit skills and agents pin their own model per stage (story-closeout and its verifier on Sonnet; user-stories, update-design, phase-close on Opus), so the one human routing step is the brainstorm: run `/model opus` before starting one. When a builder struggles, escalate context (the missing recipe in the story or CLAUDE.md) before escalating model.

An implementation session refuses to start work over a dirty working tree; unexplained working-tree state is surfaced to the human, never classified-and-fixed by the session itself. (A session once misattributed and silently deleted the human's uncommitted scratch code — the incident this rule exists to prevent.)

## Design invariants (do not violate)

- **Routines are app constants** (`:morning`/`:evening` — see `BearCub.Routines`), never DB rows. Windows live in `runtime.exs` (env-overridable). No routines table, no routine CRUD. (D8)
- **Day state is derived, never stored**: "done" means a `completions` row with `local_date = today AND undone_at IS NULL`. Never add a `completed` flag, a reset job, or midnight machinery. Undo sets `undone_at` — completion rows are never deleted. (D10)
- **Calendar is a degradable overlay**: `BearCub.Chores` must never depend on `BearCub.Calendars`; calendar failures serve the cached payload and may never affect chore display.
- **ICS URLs are secrets in the DB**: `redact: true` on the field; never log URLs (log calendar labels), never let them reach git or error output.
- **Kiosk/admin fence**: the kiosk (`/`) must contain zero links or navigation to `/admin` — Fully Kiosk's URL lock is the only barrier.
- **All time logic takes a local datetime argument** (configured timezone, default `America/Los_Angeles`) — no `DateTime.utc_now()` buried in domain code, no clock mocking in tests.
- **Kids and chores are data**, seeded as placeholders only when the kids table is empty; seeding never modifies existing rows. Kid names never enter git (public repo).
- **Chore icons are emoji strings** (required field) — no icon asset pipeline.
- The reference render target is **Fully Kiosk's Android WebView on the tablet**, not desktop Chrome; on-device QA gates each batch.

## Implementation conventions

- Scaffold new resources with `mix phx.gen.live` / `mix phx.gen.context`, then reshape toward the design — don't hand-roll contexts, migrations, or PubSub wiring the generators provide.
- TDD red-green-refactor at both unit and LiveView layers (see design §11 for the test map).

## Project guidelines

- Use `mix precommit` alias when you are done with all changes and fix any pending issues
- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps
- **Consult Tidewave early and often**: with `mix phx.server` running in dev, Tidewave's MCP tools (`/tidewave/mcp`) give live introspection of this running app — schema, routes, runtime state, logs, docs. Reach for it before guessing at schema/route/behavior, and while iterating to check a change against the live app rather than re-deriving from source alone.

Phoenix, Elixir, Ecto, HEEx, LiveView, JS/CSS, and UI guidelines live in `.claude/rules/phoenix.md`, loaded on demand when a matching source, test, template, or asset file is read — not on every turn.
