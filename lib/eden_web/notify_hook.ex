defmodule EdenWeb.NotifyHook do
  @moduledoc """
  Delivers new-message notifications to **every** authenticated LiveView, not just
  ChatLive (#272). Modeled on `EdenWeb.RailHook`: on the connected mount it subscribes
  to the user's **notifications** topic (`Chat.subscribe_notifications/1` — a dedicated
  topic carrying only `{:notify}`, NOT the full chat topic, so Settings/Admin aren't
  flooded with sidebar-sync chatter they have no handler for) and attaches a single
  `{:notify}` handler that pushes the client-side `notify` event (chime / OS banner,
  rendered by the shared `EdenWeb.Notifier` host). So a message that arrives while the
  only open tab is `/settings` or `/admin` still alerts — honoring the Settings promise
  "alerts while a browser tab is open".

  Mounted once per LiveView via the live_session `on_mount` list, AFTER `UserAuth`
  (it needs `current_scope`). The handler being here — and removed from ChatLive —
  means there's exactly one, so no double delivery.

  Gates (the rest ran server-side in `Chat.notify_recipient_ids`: self / direct-mute /
  folder-mute / DND / non-followers):
    * **focus** — suppress if you're actively viewing THIS chat (needs `selected` +
      `tab_visible`, ChatLive-only assigns; absent elsewhere ⇒ never focused ⇒ deliver).
    * **channel** — a room message is delivered only where channel-mute can be checked
      (ChatLive's `channels` rail data). Outside ChatLive there's no rail data, so room
      notifications are suppressed rather than risk leaking a muted channel — deferred
      to #235 (server-side channel-mute). DM/group messages (no `channel_id`) always
      deliver.
  """
  import Phoenix.Component, only: [assign_new: 3]
  import Phoenix.LiveView

  use EdenWeb, :verified_routes
  use Gettext, backend: EdenWeb.Gettext

  alias Eden.Chat

  def on_mount(:default, _params, _session, socket) do
    case socket.assigns[:current_scope] do
      %{user: %{}} = scope ->
        {:cont, watch(socket, scope)}

      _ ->
        # Signed-out (e.g. /settings before login): no notifications, but keep the
        # assign present so `<.notifier :if={@notify_prefs} …>` never hits a missing key.
        {:cont, assign_new(socket, :notify_prefs, fn -> nil end)}
    end
  end

  defp watch(socket, scope) do
    # notify_prefs is needed by the Notifier host on the dead render too, so assign it
    # unconditionally; subscribe + attach only on the connected socket (and once).
    socket = assign_new(socket, :notify_prefs, fn -> Chat.notification_prefs(scope) end)

    if connected?(socket) and !socket.assigns[:notify_watched?] do
      Chat.subscribe_notifications(scope)

      socket
      |> assign_new(:notify_watched?, fn -> true end)
      |> attach_hook(:notify, :handle_info, &on_notify/2)
    else
      socket
    end
  end

  defp on_notify({:notify, payload}, socket) do
    if deliver?(payload, socket.assigns) do
      {:halt, push_event(socket, "notify", notify_event(payload))}
    else
      {:halt, socket}
    end
  end

  defp on_notify(_message, socket), do: {:cont, socket}

  defp deliver?(payload, assigns),
    do: not focused?(payload, assigns) and not channel_suppressed?(payload, assigns)

  # "Am I reading THIS chat right now" → full suppression. selected/tab_visible are
  # ChatLive-only, so this is always false on /settings, /admin.
  defp focused?(payload, assigns) do
    !!(assigns[:tab_visible] && assigns[:selected] &&
         assigns[:selected].id == payload.conversation_id)
  end

  defp channel_suppressed?(%{channel_id: nil}, _assigns), do: false

  defp channel_suppressed?(%{channel_id: cid}, assigns) do
    case assigns[:channels] do
      # No rail data (not on a chat page): can't verify channel-mute, so suppress the
      # room notification rather than leak a muted channel (#272 — full room delivery
      # everywhere lands with #235's server-side channel-mute).
      nil -> true
      channels -> Enum.any?(channels, &(&1.id == cid && &1.muted))
    end
  end

  # Localize (recipient's session) the once-built broadcast payload into a client event:
  # a body line + a ready avatar URL for the OS-notification icon.
  defp notify_event(payload) do
    body =
      cond do
        payload.preview not in [nil, ""] -> payload.preview
        payload.media_kind -> media_label(payload.media_kind)
        true -> gettext("New message")
      end

    Map.merge(payload, %{
      body: body,
      avatar_url: avatar_src(payload.avatar_key, payload.sender_id)
    })
  end

  defp avatar_src(key, id) when is_binary(key),
    do: ~p"/users/#{id}/avatar?v=#{:erlang.phash2(key)}"

  defp avatar_src(_key, _id), do: nil

  defp media_label("image"), do: gettext("Photo")
  defp media_label("video"), do: gettext("Video")
  defp media_label("audio"), do: gettext("Audio")
  defp media_label(_file), do: gettext("File")
end
