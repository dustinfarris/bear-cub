defmodule BearCub.Dev.Scenarios do
  @moduledoc """
  Named kiosk states for local review — the gate mechanism (CLAUDE.md,
  Workflow): a batch is judged in Chrome against the dev server at the
  tablet's CSS viewport, staged here, before anything is deployed. The
  deployed Fully Kiosk WebView is verified afterwards against the
  Android-only checklist, never used as the first look.

  Compiled in dev and test only (`elixirc_paths/1` in `mix.exs`) — this
  module does not exist in the release, which is what makes `reset/1`'s
  row deletion acceptable: it is a sandbox wipe, not domain behavior
  (completion rows are never deleted in the domain, D10).

  Every scenario runs inside the server's own VM so its config overrides
  take effect without a restart and its broadcasts re-render open
  kiosks. Use it from `iex -S mix phx.server`, or from Tidewave's
  `project_eval`:

      BearCub.Dev.Scenarios.early_bird()
      BearCub.Dev.Scenarios.open(:morning)   # review a morning state at night
      BearCub.Dev.Scenarios.reset()

  Placeholder kids and demo chores are seeded first if the database is
  empty, exactly as `priv/repo/seeds.exs` does; existing rows are never
  modified. Every scenario takes a local datetime and defaults to now —
  the one place outside the web layer that reads the clock, and it is a
  dev edge (D86).
  """

  import Ecto.Query

  alias BearCub.Chores
  alias BearCub.Chores.Completion
  alias BearCub.LocalTime
  alias BearCub.Repo

  @doc """
  One kid finished the whole morning early (07:10), the other late
  (08:30): the sun with its bonus badge on both, the sparrow with its own
  badge on the first only (D100–D103). Returns `%{early: kid, late: kid}`.
  Also makes sure the early bird config keys exist, for a dev server
  started before they were added to `config/runtime.exs`.
  """
  def early_bird(%DateTime{} = local_now \\ LocalTime.now()) do
    ensure_config(:early_bird_cutoff, ~T[07:45:00])
    ensure_config(:early_bird_bonus, 2)

    [early, late | _] = reset(local_now)
    today = DateTime.to_date(local_now)
    tz = local_now.time_zone

    for {kid, time} <- [{early, ~T[07:10:00]}, {late, ~T[08:30:00]}],
        chore <- Chores.list_chores(kid, "morning") do
      {:ok, _} = Chores.complete_chore(chore, DateTime.new!(today, time, tz), "kiosk")
    end

    %{early: early, late: late}
  end

  @doc """
  Wipes the local day's completions for every kid, seeding placeholders
  first when the database is empty. Kids, chores, rewards and past days
  are untouched. Returns the kids in display order.
  """
  def reset(%DateTime{} = local_now \\ LocalTime.now()) do
    seed_if_empty()
    today = DateTime.to_date(local_now)
    Repo.delete_all(from c in Completion, where: c.local_date == ^today)
    broadcast()
    Chores.list_kids()
  end

  @doc """
  Forces `routine` active all day in the running VM, so a morning state
  can be reviewed in the evening and vice versa. Config only — restart
  the server to get the real windows back.
  """
  def open(routine) when routine in [:morning, :evening] do
    all_day = {~T[00:00:00], ~T[23:59:59]}
    never = {~T[23:59:59], ~T[23:59:59]}
    other = BearCub.Routines.other(routine)

    Application.put_env(:bear_cub, :routine_windows, [{routine, all_day}, {other, never}])
    broadcast()
    :ok
  end

  # The same `:chores_changed` message `Chores` broadcasts after a write,
  # on the same topic, so every open kiosk and admin view re-renders. A
  # direct broadcast rather than a new public `Chores` function: the
  # domain gains nothing it needs for a dev-only consumer.
  defp broadcast, do: Phoenix.PubSub.broadcast(BearCub.PubSub, "chores", :chores_changed)

  defp seed_if_empty do
    if Chores.list_kids() == [] do
      Code.eval_file(Path.join(:code.priv_dir(:bear_cub), "repo/seeds.exs"))
    end
  end

  defp ensure_config(key, default) do
    case Application.fetch_env(:bear_cub, key) do
      {:ok, _} -> :ok
      :error -> Application.put_env(:bear_cub, key, default)
    end
  end
end
