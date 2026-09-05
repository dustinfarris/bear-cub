defmodule BearCub.Rewards do
  @moduledoc """
  The reward economy (D57): the catalog and the request / approve /
  decline / direct-redeem / reverse write paths, plus the availability
  derivation. Owns the `rewards` and `redemptions` tables and its own
  PubSub topic; knows nothing of `BearCub.Chores` or `BearCub.Points` —
  a caller at the boundary supplies whatever balance a write path needs
  to check affordability against.
  """

  import Ecto.Query, warn: false

  alias BearCub.Repo
  alias BearCub.Chores.Kid
  alias BearCub.Rewards.Redemption
  alias BearCub.Rewards.Reward

  @topic "rewards"

  @doc """
  Subscribes the caller to reward-domain changes (D71). Every successful
  write in this context sends a payload-free `:rewards_changed`;
  subscribers re-fetch rather than patching state from a payload.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(BearCub.PubSub, @topic)
  end

  defp broadcast_change({:ok, _} = result) do
    Phoenix.PubSub.broadcast(BearCub.PubSub, @topic, :rewards_changed)
    result
  end

  defp broadcast_change(result), do: result

  ## Catalog

  @doc """
  The rewards on offer to `kid`: not retired, offered to any kid or to
  this one, in parent-controlled order (SC-1, D58). `local_date` is
  accepted for signature parity with the app's other "as of" reads;
  archiving is not day-scoped (D68), so it goes unused here.
  """
  def list_rewards(%Kid{} = kid, %Date{} = _local_date) do
    Repo.all(
      from r in Reward,
        where: is_nil(r.retired_at) and (is_nil(r.kid_id) or r.kid_id == ^kid.id),
        order_by: [asc: r.position, asc: r.id]
    )
  end

  @doc "Gets a single reward. Raises `Ecto.NoResultsError` if absent."
  def get_reward!(id), do: Repo.get!(Reward, id)

  @doc "Gets a single reward. Returns `nil` if absent, instead of raising."
  def get_reward(id), do: Repo.get(Reward, id)

  @doc """
  The whole catalog, for the admin screen that manages it (D68): every
  not-retired reward regardless of audience, in parent-controlled
  `position` order, with `:kid` preloaded so a caller can show who each
  reward is offered to. Unlike `list_rewards/2`, this is not filtered to
  one kid's audience — the parent manages the entire catalog at once.
  """
  def list_all_rewards do
    Repo.all(
      from r in Reward,
        where: is_nil(r.retired_at),
        order_by: [asc: r.position, asc: r.id],
        preload: [:kid]
    )
  end

  @doc """
  Creates a reward offered to `kid_or_nil` (`nil` = any kid), appended at
  the end of the flat position list — a single bucket, no discriminator
  to group by (D68). `kid_id` is set programmatically from the caller's
  kid selection and never cast from `attrs` (D58), matching
  `Chores.create_chore/3`.
  """
  def create_reward(kid_or_nil, attrs) do
    %Reward{kid_id: kid_id_of(kid_or_nil)}
    |> Reward.changeset(attrs)
    |> Ecto.Changeset.put_change(:position, next_position())
    |> Repo.insert()
    |> broadcast_change()
  end

  @doc """
  Updates a reward's fields and/or its audience. `kid_id` is set
  programmatically from `kid_or_nil`, never cast from `attrs` (D58).
  Reordering is the admin catalog story's job (D68), not this
  function's — `position` is untouched here.
  """
  def update_reward(%Reward{} = reward, kid_or_nil, attrs) do
    reward
    |> Reward.changeset(attrs)
    |> Ecto.Changeset.put_change(:kid_id, kid_id_of(kid_or_nil))
    |> Repo.update()
    |> broadcast_change()
  end

  @doc """
  Archives `reward` (D68) — the only removal path: stamps `retired_at`
  and removes it from `list_rewards/2`. The row and its redemptions are
  never deleted.
  """
  def archive_reward(%Reward{} = reward, %DateTime{} = local_now) do
    reward
    |> Ecto.Changeset.change(retired_at: to_utc(local_now))
    |> Repo.update()
    |> broadcast_change()
  end

  def change_reward(%Reward{} = reward, attrs \\ %{}), do: Reward.changeset(reward, attrs)

  @doc """
  Reorders `reward` one slot `:up` or `:down` (D68), written from
  `Chores.move_chore/2` as its template: the same neighbor swap inside a
  transaction, the same silent no-op at either end of the list, the same
  broadcast. The reward catalog is a single flat bucket — no
  `is_nil/1` discriminator needed (`docs/learnings.org` [2026-07-12]
  does not apply here).
  """
  def move_reward(%Reward{} = reward, direction) when direction in [:up, :down] do
    case reward_neighbor(reward, direction) do
      nil ->
        {:ok, reward}

      other ->
        {:ok, moved} =
          Repo.transaction(fn ->
            {:ok, _} =
              other |> Ecto.Changeset.change(position: reward.position) |> Repo.update()

            {:ok, moved} =
              reward |> Ecto.Changeset.change(position: other.position) |> Repo.update()

            moved
          end)

        broadcast_change({:ok, moved})
    end
  end

  defp kid_id_of(nil), do: nil
  defp kid_id_of(%Kid{id: id}), do: id

  defp next_position do
    max_position = Repo.one(from r in Reward, select: max(r.position))
    (max_position || -1) + 1
  end

  # Position-gap tolerant, mirroring Chores.neighbor/2 — the nearest
  # not-retired reward wins, ties broken by id. Archived rewards are
  # excluded so the neighbor lookup matches what the admin catalog
  # (list_all_rewards/0) actually shows.
  defp reward_neighbor(%Reward{} = reward, :up) do
    Repo.one(
      from r in Reward,
        where: is_nil(r.retired_at) and r.position < ^reward.position,
        order_by: [desc: r.position, desc: r.id],
        limit: 1
    )
  end

  defp reward_neighbor(%Reward{} = reward, :down) do
    Repo.one(
      from r in Reward,
        where: is_nil(r.retired_at) and r.position > ^reward.position,
        order_by: [asc: r.position, asc: r.id],
        limit: 1
    )
  end

  ## Redemptions — write paths (D59)

  @doc """
  Gets a single redemption. Raises `Ecto.NoResultsError` if absent.
  """
  def get_redemption!(id), do: Repo.get!(Redemption, id)

  @doc """
  The kid leg (SC-2): requests `reward` for `kid`, snapshotting its
  current price at request time (D60). No affordability or availability
  check happens here — that check is the kiosk's rendering rule (an
  unaffordable, unavailable, or already-pending card is not tappable);
  the write path's only guard is the one-open-ask-per-kid-per-reward
  index (D77, superseding D61's one-per-kid cap). A racing duplicate ask
  for the same reward hits that index and returns `{:error, changeset}`,
  which callers treat as already-asked.
  """
  def request_redemption(%Kid{} = kid, %Reward{} = reward, %DateTime{} = local_now) do
    %Redemption{kid_id: kid.id, reward_id: reward.id}
    |> Redemption.changeset(%{
      points: reward.points,
      local_date: DateTime.to_date(local_now),
      requested_at: to_utc(local_now),
      source: "kiosk"
    })
    |> Repo.insert()
    |> broadcast_change()
  end

  @doc """
  The parent-direct leg (SC-2, D68): redeems `reward` for `kid`
  immediately, with no prior request. This leg has no separate approval
  step, so it is checked here and only here — audience (a reward's
  `kid_id` is a domain semantic, not merely a display filter), then
  availability (owned by this context), then affordability against
  `balance` (the kid's current raw signed balance, supplied by the
  caller through `BearCub.Points` at the boundary, per D57) — exactly
  the rule the kid leg is bound by (D63), with no override. Returns
  `{:error, :not_offered}`, `{:error, :unavailable}`, or
  `{:error, :unaffordable}` naming the failed check, most categorical
  first.
  """
  def direct_redeem(%Kid{} = kid, %Reward{} = reward, balance, %DateTime{} = local_now)
      when is_integer(balance) do
    with :ok <- check_audience(reward, kid.id),
         :ok <- check_availability(reward, kid.id, DateTime.to_date(local_now)),
         :ok <- check_affordability(balance, reward.points) do
      %Redemption{kid_id: kid.id, reward_id: reward.id}
      |> Redemption.changeset(%{
        points: reward.points,
        local_date: DateTime.to_date(local_now),
        approved_at: to_utc(local_now),
        source: "admin"
      })
      |> Repo.insert()
      |> broadcast_change()
    end
  end

  @doc """
  Approves an open request (the kid leg's second check, D63): stamps
  `approved_at` after re-validating audience, availability, and
  affordability, because any of the three may have moved between ask
  and answer — including the same-kid interleaving where a
  direct-redeem of the same reward lands in between (D62), and a
  reward's audience narrowing after the ask (defense in depth: the
  kiosk leg is audience-correct by construction, since a kid only ever
  requests from an audience-filtered catalog, but the domain does not
  depend on that remaining true). `balance` is the caller-supplied
  current raw signed balance. Returns `{:error, :not_open}`,
  `{:error, :not_offered}`, `{:error, :unavailable}`, or
  `{:error, :unaffordable}` naming the failed check, most categorical
  first, rather than silently no-opping or stamping a second marker
  onto an already-answered row.
  """
  def approve_redemption(%Redemption{} = redemption, balance, %DateTime{} = local_now)
      when is_integer(balance) do
    reward = get_reward!(redemption.reward_id)
    today = DateTime.to_date(local_now)

    with :ok <- check_open(redemption, today),
         :ok <- check_audience(reward, redemption.kid_id),
         :ok <- check_availability(reward, redemption.kid_id, today),
         :ok <- check_affordability(balance, redemption.points) do
      redemption
      |> Ecto.Changeset.change(approved_at: to_utc(local_now))
      |> Repo.update()
      |> broadcast_change()
    end
  end

  @doc """
  Declines an open request: stamps `declined_at`. Contributes nothing
  and costs nothing (D59) — no confirmation, no re-check needed. Returns
  `{:error, :not_open}` for a request already answered, already withdrawn
  (D76), *or already lapsed* (D73), rather than stamping a second marker
  onto it.
  """
  def decline_redemption(%Redemption{} = redemption, %DateTime{} = local_now) do
    with :ok <- check_open(redemption, DateTime.to_date(local_now)) do
      redemption
      |> Ecto.Changeset.change(declined_at: to_utc(local_now))
      |> Repo.update()
      |> broadcast_change()
    end
  end

  @doc """
  The kid's own undo (D76): withdraws an open request, stamping
  `withdrawn_at` — the fourth nullable marker, the same
  `undone_at`/`failed_at`/`declined_at` pattern (D59), never a row
  deletion. Pending-only: shares `check_open/2` with `approve_redemption/3`
  and `decline_redemption/2`, so a row already answered, already
  withdrawn, or lapsed is refused with the same `{:error, :not_open}`
  family rather than stamping a second marker. No confirmation, no
  re-check — asking again is the undo.
  """
  def withdraw_redemption(%Redemption{} = redemption, %DateTime{} = local_now) do
    with :ok <- check_open(redemption, DateTime.to_date(local_now)) do
      redemption
      |> Ecto.Changeset.change(withdrawn_at: to_utc(local_now))
      |> Repo.update()
      |> broadcast_change()
    end
  end

  @doc """
  The open (pending, not lapsed) request for `kid_id` and `reward_id` as
  of `local_date`, if any (Story 08) — the kiosk's lookup ahead of a
  withdraw tap, mirroring how `request-reward` looks up its kid and
  reward before calling the write path. `nil` if none.
  """
  def get_pending_redemption(kid_id, reward_id, %Date{} = local_date) do
    Repo.one(
      from r in Redemption,
        where:
          r.kid_id == ^kid_id and r.reward_id == ^reward_id and not is_nil(r.requested_at) and
            is_nil(r.approved_at) and is_nil(r.declined_at) and is_nil(r.withdrawn_at) and
            r.local_date == ^local_date
    )
  end

  @doc """
  Reverses an approved, unreversed redemption (SC-8): stamps
  `reversed_at`, which restores the kid's balance and the reward's
  availability for free (D62) — the row is retained forever as the
  trail (D59), never deleted or otherwise mutated. Returns
  `{:error, :not_approved}` for a redemption that was never approved or
  is already reversed.
  """
  def reverse_redemption(%Redemption{} = redemption, %DateTime{} = local_now) do
    with :ok <- check_approved(redemption) do
      redemption
      |> Ecto.Changeset.change(reversed_at: to_utc(local_now))
      |> Repo.update()
      |> broadcast_change()
    end
  end

  @doc """
  Pending requests for `kid_id` as of `local_date` (Story 06, D69): the
  per-kid Requests section on `Admin.TodayLive`. Requested, no verdict
  yet, dated `local_date` — the same predicate that keeps a lapsed row
  invisible on the kiosk (D61/D73). Preloads `:reward` for the icon,
  name, and snapshot price the queue displays.
  """
  def list_pending_redemptions(kid_id, %Date{} = local_date) do
    Repo.all(
      from r in Redemption,
        where:
          r.kid_id == ^kid_id and not is_nil(r.requested_at) and is_nil(r.approved_at) and
            is_nil(r.declined_at) and is_nil(r.withdrawn_at) and r.local_date == ^local_date,
        order_by: [asc: r.requested_at],
        preload: [:reward]
    )
  end

  @doc """
  Today's approved redemptions for `kid_id` (Story 06, D69): the "day's
  redemptions" beside the reverse control — `approved_at` set, dated
  `local_date`, reversed or not (a parent can see today's answer either
  way). Preloads `:reward`.
  """
  def list_redemptions_today(kid_id, %Date{} = local_date) do
    Repo.all(
      from r in Redemption,
        where: r.kid_id == ^kid_id and not is_nil(r.approved_at) and r.local_date == ^local_date,
        order_by: [asc: r.approved_at],
        preload: [:reward]
    )
  end

  @doc """
  The redemption record (Story 07, D70): a pure read surface over rows
  that already carry a verdict — approved (and possibly reversed since,
  D59) or declined — reverse-chronological by the date that verdict
  landed, bounded to `limit` (default the 50 stated on screen, D70).
  Pending and lapsed rows carry no verdict yet, so the same predicate
  excludes both without needing to tell them apart. Preloads `:kid` and
  `:reward` — the reward row is never deleted (D68), so an archived or
  renamed reward still joins under its current name (D60).
  """
  def list_redemption_history(limit \\ 50) do
    Repo.all(
      from r in Redemption,
        where: not is_nil(r.approved_at) or not is_nil(r.declined_at),
        order_by: [desc: fragment("COALESCE(?, ?)", r.approved_at, r.declined_at)],
        limit: ^limit,
        preload: [:kid, :reward]
    )
  end

  # Pending only — requested, no verdict yet, not withdrawn, dated today.
  # One predicate, both directions (Story 08): approve_redemption/3 and
  # decline_redemption/2 refuse a withdrawn row exactly as
  # withdraw_redemption/2 refuses an answered one, all returning
  # {:error, :not_open}. Lapse is terminal at the write layer (D73): a
  # lapsed row (no verdict, dated before today) is refused here exactly
  # like an already-answered one. D61's index only ever bore on the
  # one-open-request-per-day slot; it never meant a lapsed row stays
  # answerable, and treating it as answerable would let a days-later
  # approval land outside D69's day-scoped reversal window with no
  # correction surface reaching it.
  defp check_open(
         %Redemption{
           requested_at: at,
           approved_at: nil,
           declined_at: nil,
           withdrawn_at: nil,
           local_date: local_date
         },
         %Date{} = today
       )
       when not is_nil(at) and local_date == today,
       do: :ok

  defp check_open(%Redemption{}, %Date{}), do: {:error, :not_open}

  defp check_approved(%Redemption{approved_at: at, reversed_at: nil}) when not is_nil(at),
    do: :ok

  defp check_approved(%Redemption{}), do: {:error, :not_approved}

  @doc """
  Whether `kid_id` has any open request today, across every reward (Story
  05/08, D65/D77) — the banner gift button's second state (=⏳=).
  Marker-derived, day-scoped exactly like `pending?/2`, and *not*
  reward-scoped: several requests may be open at once (D77), so this
  reports whether *any* remains rather than counting them.
  """
  def any_pending?(kid_id, %Date{} = local_date) do
    Repo.exists?(
      from r in Redemption,
        where:
          r.kid_id == ^kid_id and not is_nil(r.requested_at) and is_nil(r.approved_at) and
            is_nil(r.declined_at) and is_nil(r.withdrawn_at) and r.local_date == ^local_date
    )
  end

  @doc """
  This kid's pending requests' snapshot prices, summed as of
  `local_date` (Story 08, D77) — the reserve `card_state/5`'s lock
  condition subtracts from `balance`. *Pending* only: no verdict, not
  withdrawn, `local_date == today` — never the un-day-scoped `open`
  form. A lapsed row can never be approved (D73), so it commits nothing;
  reserving against it would be a lock against a spend that cannot
  happen. `Points.balance/2` is untouched by this — it is a rendering
  read only (D63).
  """
  def pending_total(kid_id, %Date{} = local_date) do
    Repo.aggregate(
      from(r in Redemption,
        where:
          r.kid_id == ^kid_id and not is_nil(r.requested_at) and is_nil(r.approved_at) and
            is_nil(r.declined_at) and is_nil(r.withdrawn_at) and r.local_date == ^local_date
      ),
      :sum,
      :points
    ) || 0
  end

  @doc """
  A reward card's state for `kid_id` as of `local_date` (Story 05/08,
  D66/D77): one ordered resolution, first match wins. `balance` is the
  kid's raw signed balance (D63/D64) and `pending_total` is this kid's
  reserve (`pending_total/2`), both supplied by the caller through
  `BearCub.Points`/this context at the boundary, computed once per column
  rather than once per card. Rows 1 and 2 of the design's precedence
  table both render nothing, so they collapse to `:absent`; the
  remaining five distinct renderings are `:pending`, `:declined`,
  `:claimed`, `:locked`, and `:available`.
  """
  def card_state(%Reward{} = reward, kid_id, balance, pending_total, %Date{} = local_date)
      when is_integer(balance) and is_integer(pending_total) do
    cond do
      reward.retired_at ->
        :absent

      not reward.repeatable and consumed_before?(reward.id, kid_id, local_date) ->
        :absent

      pending_today?(reward.id, kid_id, local_date) ->
        :pending

      declined_today?(reward.id, kid_id, local_date) ->
        :declined

      on_cooldown?(reward.id, kid_id, local_date) ->
        :claimed

      # Reserve-aware (D77): a pending ask on another reward already
      # committed some of the balance, so the lock condition subtracts
      # it. A card whose own request is pending never reaches here — the
      # pending_today? clause above always resolves first.
      balance - pending_total < reward.points ->
        :locked

      true ->
        :available
    end
  end

  defp consumed_before?(reward_id, kid_id, local_date) do
    reward_id
    |> spends_query(kid_id)
    |> where([r], r.local_date < ^local_date)
    |> Repo.exists?()
  end

  defp pending_today?(reward_id, kid_id, local_date) do
    !!get_pending_redemption(kid_id, reward_id, local_date)
  end

  defp declined_today?(reward_id, kid_id, local_date) do
    Repo.exists?(
      from r in Redemption,
        where:
          r.reward_id == ^reward_id and r.kid_id == ^kid_id and not is_nil(r.declined_at) and
            r.local_date == ^local_date
    )
  end

  ## Redemption state (D59) — derived from markers, never a status column

  @doc "Requested today, no verdict yet, not withdrawn (D76)."
  def pending?(%Redemption{} = r, %Date{} = today),
    do:
      !!r.requested_at and is_nil(r.approved_at) and is_nil(r.declined_at) and
        is_nil(r.withdrawn_at) and r.local_date == today

  @doc "Requested on an earlier local day, still no verdict, not withdrawn — never carries over (D61)."
  def lapsed?(%Redemption{} = r, %Date{} = today),
    do:
      !!r.requested_at and is_nil(r.approved_at) and is_nil(r.declined_at) and
        is_nil(r.withdrawn_at) and Date.compare(r.local_date, today) == :lt

  @doc "Approved and not since reversed — the live spend."
  def approved?(%Redemption{} = r), do: !!r.approved_at and is_nil(r.reversed_at)

  @doc "Approved, then reversed."
  def reversed?(%Redemption{} = r), do: !!r.approved_at and !!r.reversed_at

  @doc "Declined by a parent."
  def declined?(%Redemption{} = r), do: !!r.declined_at

  @doc "Withdrawn by the kid (D76)."
  def withdrawn?(%Redemption{} = r), do: !!r.withdrawn_at

  @doc """
  A redemption's points contribution (D59): marker-first, mirroring
  `Chores.extra_contribution/2`'s `cond` exactly — a reversed row
  contributes nothing (retained forever as the trail), an
  approved-unreversed row is the spend, everything else (pending,
  declined, lapsed, withdrawn) is zero.
  """
  def redemption_contribution(%Redemption{} = r) do
    cond do
      r.reversed_at -> 0
      r.approved_at -> -r.points
      true -> 0
    end
  end

  ## Audience (D58) — a domain semantic, not merely a display filter

  @doc """
  Whether `reward` is offered to `kid_id`: true when the reward's
  `kid_id` is `nil` (offered to any kid) or matches. Purely an
  administrative "who is this offered to" control (D58) — it carries no
  scarcity meaning, which is `available?/3`'s job.
  """
  def offered?(%Reward{kid_id: nil}, _kid_id), do: true
  def offered?(%Reward{kid_id: kid_id}, kid_id), do: true
  def offered?(%Reward{}, _kid_id), do: false

  defp check_audience(reward, kid_id) do
    if offered?(reward, kid_id), do: :ok, else: {:error, :not_offered}
  end

  ## Availability (D62) — fully derived, scoped per kid

  @doc """
  Whether `kid_id` may claim `reward` as of `local_date`: a one-time
  reward is consumed by any unreversed approval this kid holds, on any
  day; a repeatable reward is only on cooldown for an unreversed
  approval dated `local_date`. Scoped per kid — a sibling's redemptions
  never affect this (SC-5).
  """
  def available?(%Reward{repeatable: true} = reward, kid_id, %Date{} = local_date) do
    not on_cooldown?(reward.id, kid_id, local_date)
  end

  def available?(%Reward{repeatable: false} = reward, kid_id, %Date{} = _local_date) do
    not consumed?(reward.id, kid_id)
  end

  defp consumed?(reward_id, kid_id) do
    reward_id |> spends_query(kid_id) |> Repo.exists?()
  end

  defp on_cooldown?(reward_id, kid_id, local_date) do
    reward_id
    |> spends_query(kid_id)
    |> where([r], r.local_date == ^local_date)
    |> Repo.exists?()
  end

  defp spends_query(reward_id, kid_id) do
    from r in Redemption,
      where:
        r.reward_id == ^reward_id and r.kid_id == ^kid_id and not is_nil(r.approved_at) and
          is_nil(r.reversed_at)
  end

  defp check_availability(reward, kid_id, local_date) do
    if available?(reward, kid_id, local_date), do: :ok, else: {:error, :unavailable}
  end

  defp check_affordability(balance, price) do
    if balance >= price, do: :ok, else: {:error, :unaffordable}
  end

  ## The redemptions leg of the points aggregate (D57, D72)

  @doc """
  Every kid's cumulative spend as of `local_date`, keyed by kid id — the
  redemptions leg of `BearCub.Points.balances/1` (D72): one aggregate
  over approved-and-unreversed rows, already negative (the D59
  contribution), grouped by kid, so `Points` can add it to earnings
  directly. Kids with no spends are absent from the result.
  """
  def spend_totals_by_kid(%Date{} = local_date) do
    from(r in Redemption,
      where: not is_nil(r.approved_at) and is_nil(r.reversed_at) and r.local_date <= ^local_date,
      group_by: r.kid_id,
      select: {r.kid_id, fragment("-SUM(?)", r.points)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp to_utc(%DateTime{} = local) do
    local |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)
  end
end
