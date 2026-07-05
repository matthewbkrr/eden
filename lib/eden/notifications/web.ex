defmodule Eden.Notifications.Web do
  @moduledoc """
  In-tab notification transport — the first `Eden.Notifications.Adapter` (ADR-0001).

  Delivers `{:notify, payload}` over `Phoenix.PubSub` on a per-user topic that open
  LiveViews subscribe to (`EdenWeb.NotifyHook`), which renders it as a chime / OS banner
  per the viewer's prefs. Unlike the future push transports it has **no stored device
  row** — it rides the live LiveView/PubSub connection, so there's nothing to register or
  prune. This is the reference adapter; push transports mirror its `deliver/2`.
  """
  @behaviour Eden.Notifications.Adapter

  @pubsub Eden.PubSub

  @impl true
  def deliver(user_id, payload) do
    Phoenix.PubSub.broadcast(@pubsub, topic(user_id), {:notify, payload})
    :ok
  end

  @doc "Subscribe the caller to `user_id`'s in-tab notification stream."
  def subscribe(user_id), do: Phoenix.PubSub.subscribe(@pubsub, topic(user_id))

  @doc "The per-user notification topic carrying `{:notify, payload}`."
  def topic(user_id), do: "user:#{user_id}:notify"
end
