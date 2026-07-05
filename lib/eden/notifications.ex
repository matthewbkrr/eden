defmodule Eden.Notifications do
  @moduledoc """
  Notification delivery seam (ADR-0001 step 1).

  `Eden.Chat` decides **who** should hear about a message — the #213 gating (mute / DND /
  thread-following) — and builds a locale-neutral payload; this context takes that
  already-gated `(recipient_ids, payload)` and fans it out to each recipient across the
  configured delivery **adapters** (`Eden.Notifications.Adapter`). Chat stays unaware of
  transports; Notifications stays unaware of *who* should hear. Modeled on the
  `Eden.Storage` seam.

  Today the only transport is the in-tab `Eden.Notifications.Web` adapter (a live
  LiveView/PubSub push, no stored device row). Future push transports (native desktop
  app, APNs, FCM, RuStore/VK) are added to the adapter list with no caller changes — see
  ADR-0001.

  ## The contract (documented here, in one place)

  A notification is a plain map, delivered by the Web adapter as `{:notify, payload}`.
  `Eden.Chat` is the sole producer (`notify_payload/1`); adapters are consumers that
  render it. The payload is **locale-neutral** — the recipient's session formats titles
  and localizes media labels. Shape:

      %{
        conversation_id: integer,
        message_id: integer,
        root_id: integer | nil,        # non-nil ⇒ a thread reply
        channel_id: integer | nil,     # non-nil ⇒ a room (corporate layer)
        kind: "dm" | "group" | "room",
        conv_title: String.t() | nil,  # group title / room name; nil for a DM
        sender_id: integer,
        sender_name: String.t(),
        avatar_key: String.t() | nil,
        preview: String.t(),           # message body; "" when the message is media-only
        media_kind: "image" | "video" | "audio" | "file" | nil
      }

  The in-tab stream is always the Web transport: a LiveView subscribes via `subscribe/1`
  (topic `Eden.Notifications.Web.topic/1`, `"user:<id>:notify"`) regardless of which push
  adapters are configured.
  """
  alias Eden.Accounts.Scope
  alias Eden.Notifications.Web

  @type payload :: map

  @doc """
  Deliver an already-gated `payload` to each of `recipient_ids`, fanned out across every
  configured adapter. A no-op for an empty recipient list.
  """
  @spec deliver([integer], payload) :: :ok
  def deliver(recipient_ids, payload) do
    # Read the adapter list once, not per recipient: a comprehension re-evaluates a
    # generator expression on every iteration of the preceding one.
    adapters = adapters()
    for uid <- recipient_ids, adapter <- adapters, do: adapter.deliver(uid, payload)
    :ok
  end

  @doc "Subscribe the scoped user's session to their in-tab notification stream."
  def subscribe(%Scope{user: user}), do: Web.subscribe(user.id)

  @doc "The in-tab notification topic for `user_id` (Web transport)."
  def topic(user_id), do: Web.topic(user_id)

  defp adapters, do: Application.fetch_env!(:eden, __MODULE__)[:adapters]
end
