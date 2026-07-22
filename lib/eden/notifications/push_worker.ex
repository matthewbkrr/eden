defmodule Eden.Notifications.PushWorker do
  @moduledoc """
  Delivers one already-gated notification to one user's devices of one push
  transport (#418, ADR-0001).

  `Eden.Notifications.deliver/2` runs INLINE in the message-send path, so the
  push adapters' `deliver/2` only enqueues this job and returns — the HTTP to
  Apple/Google happens here, off the send path, with Oban's durability and
  retries. The job resolves the user's registered devices itself: a recipient
  with no device rows is a cheap no-op (most users, until the apps spread).

  A token the provider reports dead is pruned and counts as success. A
  transient transport error fails the job so Oban retries it; on retry every
  device of the user is pushed again, so a multi-device user can see a
  duplicate banner after a partial failure — accepted for v1 (per-device jobs
  would trade that for N× job rows).
  """
  use Oban.Worker, queue: :push, max_attempts: 5

  alias Eden.Notifications

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "kind" => kind, "payload" => payload}}) do
    case Notifications.targets_for(user_id, kind) do
      [] ->
        :ok

      targets ->
        rendered = Notifications.render_push(payload)
        transport = transport!(kind)

        targets
        |> Enum.map(&push_one(transport, kind, &1, rendered))
        |> Enum.find(:ok, &match?({:error, _}, &1))
    end
  end

  defp push_one(transport, kind, target, rendered) do
    case transport.push(target.token, rendered) do
      :ok ->
        :ok

      :unregistered ->
        Notifications.prune_target(kind, target.token)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp transport!("apns"), do: Eden.Notifications.APNs
  defp transport!("fcm"), do: Eden.Notifications.FCM
end
