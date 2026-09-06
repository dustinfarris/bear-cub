defmodule BearCub.Notifications do
  @moduledoc """
  Parent push notifications over ntfy: one HTTP POST per event to the
  configured topic URL, from a supervised task so a kiosk tap never waits
  on the network.

  The topic URL is the secret (the public ntfy.sh instance has no other
  access control) and gets the ICS-URL treatment: never in git, never
  logged. Unset means notifications are off.

  Three events push today: a completed chore whose `notify_on_complete?`
  flag is on, a routine whose last chore was just completed (regardless
  of flags), and a kid asking for a reward from the kiosk shop. Undo,
  fail, and parent-direct redeems are silent.
  """

  require Logger

  alias BearCub.Chores
  alias BearCub.Chores.Chore
  alias BearCub.Chores.Kid
  alias BearCub.Rewards.Reward

  @title "Bear Cub"

  @doc """
  Pushes for a completion of `chore` on `local_date`: the chore's own
  line when flagged, and the routine line when the completion finished
  the kid's routine for the day (`Chores.routine_day_status/3`, D94).
  Builds each message here, in the caller, so the dispatched task
  never touches the database.
  """
  def chore_completed(%Chore{} = chore, %Date{} = local_date) do
    kid = Chores.get_kid!(chore.kid_id)

    if chore.notify_on_complete? do
      push("#{kid.name} finished #{chore.icon} #{chore.name}")
    end

    if chore.routine && routine_done?(kid, chore.routine, local_date) do
      push("#{kid.name}'s #{chore.routine} routine is done")
    end

    :ok
  end

  @doc "Pushes for a kid asking for `reward` from the kiosk shop."
  def reward_requested(%Kid{} = kid, %Reward{} = reward) do
    push("#{kid.name} asked for #{reward.icon} #{reward.name} (#{reward.points} pts)")
    :ok
  end

  @doc """
  The configured topic URL, or nil when notifications are off. Shown on
  the admin notifications page so a parent can subscribe; never logged.
  """
  def topic_url, do: Application.get_env(:bear_cub, :ntfy_url)

  @doc """
  Sends `message` to the configured topic. Returns `{:ok, pid}` of the
  task carrying the request, or `:ignore` when no topic URL is set.
  Failures are logged with the message and status only.
  """
  def push(message) when is_binary(message) do
    case topic_url() do
      nil ->
        :ignore

      url ->
        Task.Supervisor.start_child(BearCub.TaskSupervisor, fn -> post(url, message) end)
    end
  end

  defp routine_done?(kid, routine, local_date) do
    %{empty?: empty?, complete?: complete?} = Chores.routine_day_status(kid, routine, local_date)
    complete? and not empty?
  end

  defp post(url, message) do
    case Req.post(url, [body: message, headers: [title: @title]] ++ req_options()) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("ntfy push failed status=#{status} message=#{inspect(message)}")

      {:error, error} ->
        # Exception.message/1, not inspect/1: Req's transport errors
        # carry only a reason, while a full struct could echo the URL.
        Logger.warning(
          "ntfy push failed reason=#{Exception.message(error)} message=#{inspect(message)}"
        )
    end
  end

  defp req_options do
    Keyword.merge(
      [receive_timeout: 10_000, retry: false],
      Application.get_env(:bear_cub, :notifications_req_options, [])
    )
  end
end
