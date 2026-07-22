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
  `Eden.Chat` builds it for messages (`notify_payload/1`); `Eden.Channels` builds the
  `kind: "knock"` variant for a private-room join request (#363/R029) — a knock has no
  `%User{}` message sender, so it can't go through `notify_payload/1`. Adapters are
  consumers that render whichever variant they receive. The payload is **locale-neutral** —
  the recipient's session formats titles and localizes media labels. Shape:

      %{
        conversation_id: integer,
        message_id: integer,
        root_id: integer | nil,           # non-nil ⇒ a thread reply
        channel_id: integer | nil,        # non-nil ⇒ a room (corporate layer)
        kind: "dm" | "group" | "room" | "knock",
        conv_title: String.t() | nil,     # group title / room name; nil for a DM
        sender_id: integer,               # for "knock", the requester
        sender_name: String.t(),
        avatar_key: String.t() | nil,
        preview: String.t(),              # message body; "" for media-only OR a knock
        media_kind: "image" | "video" | "audio" | "file" | nil
      }

  For `kind: "knock"` the room is the `conv_title`, the requester rides the `sender_*`
  fields, `preview` is `""` and the recipient's session words it as a join request.

  The web layer DROPS the internal `:preview` (size-guard body) and `:avatar_key`
  (storage key) when localizing the map into the client `notify` event (#363/R203) — the
  client uses only the fitted `:body` and a ready `:avatar_url`.

  **Reactions do not notify.** Toggling an emoji reaction (`Chat.toggle_reaction/3`)
  broadcasts `{:reaction_changed, message}` on the conversation topic for live chip
  updates, but deliberately does NOT deliver a `{:notify}` to the message's author
  (#363/R144). Adding a `kind: "reaction"` here is a future product decision (it would
  need its own per-user opt-out); until then reactions stay a passive, in-view signal.

  The in-tab stream is always the Web transport: a LiveView subscribes via `subscribe/1`
  (topic `Eden.Notifications.Web.topic/1`, `"user:<id>:notify"`) regardless of which push
  adapters are configured.
  """
  import Ecto.Query, warn: false

  alias Eden.Accounts.Scope
  alias Eden.Notifications.Target
  alias Eden.Notifications.Web
  alias Eden.Repo

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

  ## Push devices (#418)

  @doc """
  Register (or refresh) the scoped user's push device: `kind` names the
  transport (`apns | fcm | rustore | vk`), `token` is the device's push token.
  Re-registering the same device is an upsert that re-enables it and touches
  `last_seen_at` — the mobile shell calls this on every app start.
  """
  def upsert_target(%Scope{user: user}, kind, token) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %Target{user_id: user.id, last_seen_at: now}
    |> Target.changeset(%{"kind" => kind, "token" => token})
    |> Repo.insert(
      on_conflict: [set: [enabled: true, last_seen_at: now, updated_at: now]],
      conflict_target: [:user_id, :kind, :token],
      returning: true
    )
  end

  @doc """
  Drop a device token the provider reported dead (APNs 410 `Unregistered`, FCM
  `UNREGISTERED`). No user scope on purpose: the provider's verdict is about
  the token itself, and the transports have no `%Scope{}` to offer.
  """
  def prune_target(kind, token) do
    Repo.delete_all(from t in Target, where: t.kind == ^kind and t.token == ^token)
    :ok
  end

  @doc """
  Remove every push device of a user — offboarding hygiene for deactivation and
  permanent deletion (#303). Delivery already excludes deactivated users at the
  gating layer (#363/R150), so this only stops orphaned tokens from lingering.
  """
  def delete_user_targets(user_id) do
    Repo.delete_all(from t in Target, where: t.user_id == ^user_id)
    :ok
  end

  @doc "The user's enabled devices for one transport kind."
  def targets_for(user_id, kind) do
    Repo.all(from t in Target, where: t.user_id == ^user_id and t.kind == ^kind and t.enabled)
  end

  @doc """
  Whether the user has any enabled device of `kind` — the adapters' cheap
  inline gate before enqueueing a push job (an index-only probe on the unique
  triple; most recipients have no device rows until the apps spread).
  """
  def has_targets?(user_id, kind) do
    Repo.exists?(from t in Target, where: t.user_id == ^user_id and t.kind == ^kind and t.enabled)
  end

  @doc """
  Render the locale-neutral payload (the moduledoc contract) into the push
  notification's `%{title, body, data}`.

  Wording mirrors the in-tab banner: DM → sender as title; group/room →
  "sender — conversation"; a knock (#41) → the room as title, "<requester>
  просится в комнату". A media message leads with its marker, caption after it
  (#363/R202/R203), and the body is trimmed like the web banner.

  v1 renders RU only — deliberately hardcoded, not Gettext: the user's locale
  lives in the web session (`EdenWeb.Locale`), which a background push job
  can't see, and reaching for the web layer's Gettext backend from a context
  would cross the web↔context boundary. A persisted per-user locale is the
  epic's follow-up; when it lands, these strings move behind it.

  Accepts atom- or string-keyed maps (Oban args arrive string-keyed).
  """
  def render_push(payload) do
    p = Map.new(payload, fn {k, v} -> {to_string(k), v} end)

    title =
      case p["kind"] do
        "dm" -> p["sender_name"]
        "knock" -> p["conv_title"] || p["sender_name"]
        _group_or_room -> "#{p["sender_name"]} — #{p["conv_title"]}"
      end

    body =
      case p["kind"] do
        "knock" -> "#{p["sender_name"]} просится в комнату"
        _ -> media_body(media_marker(p["media_kind"]), p["preview"] || "")
      end

    %{title: title, body: trim(body), data: push_data(p)}
  end

  # FCM requires the data map to be string→string; nil channel_id is omitted
  # (a DM/group has none) — the client routes on its presence (#419).
  defp push_data(p) do
    data = %{
      "conversation_id" => to_string(p["conversation_id"]),
      "message_id" => to_string(p["message_id"] || "")
    }

    case p["channel_id"] do
      nil -> data
      cid -> Map.put(data, "channel_id", to_string(cid))
    end
  end

  defp media_marker(nil), do: nil
  defp media_marker("image"), do: "📷 Фото"
  defp media_marker("video"), do: "🎥 Видео"
  # `sniff/2` never emits "audio" today (#373) — tolerated for forward-compat.
  defp media_marker("audio"), do: "🎤 Аудио"
  defp media_marker(_file_or_unknown), do: "📄 Файл"

  defp media_body(nil, preview), do: preview
  defp media_body(marker, ""), do: marker
  defp media_body(marker, caption), do: "#{marker} · #{caption}"

  # Same cap as the in-tab banner (#363/R202): push services truncate anyway,
  # but a consistent cut keeps the two surfaces reading identically.
  @body_max 140
  defp trim(body) when byte_size(body) <= @body_max, do: body

  defp trim(body) do
    if String.length(body) <= @body_max,
      do: body,
      else: String.slice(body, 0, @body_max - 1) <> "…"
  end

  defp adapters, do: Application.fetch_env!(:eden, __MODULE__)[:adapters]
end
