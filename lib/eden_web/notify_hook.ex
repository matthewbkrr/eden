defmodule EdenWeb.NotifyHook do
  @moduledoc """
  Delivers new-message notifications to **every** authenticated LiveView, not just
  ChatLive (#272). Modeled on `EdenWeb.RailHook`: on the connected mount it subscribes
  to the user's **notifications** stream (`Eden.Notifications.subscribe/1` — a dedicated
  topic carrying only `{:notify}`, NOT the full chat topic, so Settings/Admin aren't
  flooded with sidebar-sync chatter they have no handler for) and attaches a single
  `{:notify}` handler that pushes the client-side `notify` event (chime / OS banner,
  rendered by the shared `EdenWeb.Notifier` host). So a message that arrives while the
  only open tab is `/settings` or `/admin` still alerts — honoring the Settings promise
  "alerts while a browser tab is open".

  Mounted once per LiveView via the live_session `on_mount` list, AFTER `UserAuth`
  (it needs `current_scope`). The handler being here — and removed from ChatLive —
  means there's exactly one, so no double delivery.

  Only **one** gate is left here, because it's the only per-session one: **focus** —
  suppress if you're actively viewing THIS chat right now (needs `selected` +
  `tab_visible`, ChatLive-only assigns; absent elsewhere ⇒ never focused ⇒ deliver).
  For a **thread reply** (`root_id` set) focus means the open **thread panel** of *that* thread
  (`thread_root`), not the open room (#362) — a reply never appears in the main stream, so a room
  being open isn't "seeing it"; an open room with the panel closed still delivers the chime/banner.
  Every other gate — self / direct-mute / folder-mute / DND / non-followers, and (since
  #271) **channel-mute** — is applied server-side in `Chat.notify_recipient_ids`, so the
  payload only reaches sessions that should hear it. That's why room notifications now
  deliver on `/settings` and `/admin` too: a muted channel is already filtered out
  upstream, with no rail data needed here.
  """
  import Phoenix.Component, only: [assign_new: 3]
  import Phoenix.LiveView

  use EdenWeb, :verified_routes
  use Gettext, backend: EdenWeb.Gettext

  alias Eden.Chat
  alias Eden.Notifications

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
      Notifications.subscribe(scope)

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

  defp deliver?(payload, assigns), do: not focused?(payload, assigns)

  # "Am I reading THIS chat right now" → full suppression. selected/tab_visible/thread_root are
  # ChatLive-only, so this is always false on /settings, /admin (⇒ deliver).
  #
  # A thread reply (#57) never lands in the main stream, so a room merely being open does NOT
  # mean the user sees it — focus for a reply is the OPEN THREAD PANEL of exactly that thread
  # (#362/R011), not the room. thread_root is the open thread's %Message{} (nil when the panel is
  # closed / on /settings), so a different-thread or closed panel isn't focused ⇒ deliver.
  defp focused?(%{root_id: root_id}, assigns) when not is_nil(root_id) do
    !!(assigns[:tab_visible] && match?(%{id: ^root_id}, assigns[:thread_root]))
  end

  # A normal message keeps the room-open focus: it DOES appear in the open room's main stream.
  defp focused?(payload, assigns) do
    !!(assigns[:tab_visible] && assigns[:selected] &&
         assigns[:selected].id == payload.conversation_id)
  end

  # Localize (recipient's session) the once-built broadcast payload into a client event:
  # a body line + a ready avatar URL for the OS-notification icon.
  defp notify_event(payload) do
    body =
      cond do
        payload.preview not in [nil, ""] -> display_preview(payload.preview)
        payload.media_kind -> media_label(payload.media_kind)
        true -> gettext("New message")
      end

    Map.merge(payload, %{
      body: body,
      avatar_url: avatar_src(payload.avatar_key, payload.sender_id)
    })
  end

  # Strip markdown markers (Markup is a web module) THEN fit to the banner (#273). Doing
  # it in this order means the (server-size-bounded) body is cleaned before the final cut,
  # so truncation can't leave a dangling `**` / broken token (#279 review). `String.slice`
  # is grapheme-safe, so a family emoji at the boundary is never split.
  defp display_preview(preview), do: preview |> EdenWeb.Markup.strip() |> String.slice(0, 140)

  defp avatar_src(key, id) when is_binary(key),
    do: ~p"/users/#{id}/avatar?v=#{:erlang.phash2(key)}"

  defp avatar_src(_key, _id), do: nil

  defp media_label("image"), do: gettext("Photo")
  defp media_label("video"), do: gettext("Video")
  defp media_label("audio"), do: gettext("Audio")
  defp media_label(_file), do: gettext("File")
end
