defmodule EdenWeb.ChatLive do
  @moduledoc """
  The chat: a conversation list (sidebar) and the selected conversation's message
  window. Realtime via Chat PubSub; the message collection is a LiveView stream
  with backward pagination. Everything is authorized through the Chat context
  using `current_scope`.
  """
  use EdenWeb, :live_view

  require Logger

  on_mount EdenWeb.RailHook

  import EdenWeb.ShellComponents

  alias Eden.{Accounts, Channels, Chat}
  alias EdenWeb.Markup

  @page 50

  # Typing indicator (#11): throttle outgoing "typing" broadcasts to at most one
  # per this window while composing; each received broadcast keeps the indicator
  # alive for the (longer) TTL, after which it auto-expires. TTL > throttle so a
  # continuous typer never flickers off between broadcasts.
  @typing_throttle_ms 2_000
  @typing_ttl_ms 4_000

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket) do
      EdenWeb.Presence.track_user(self(), scope.user.id)
      Phoenix.PubSub.subscribe(Eden.PubSub, EdenWeb.Presence.topic())
      Chat.subscribe_user(scope)
      Accounts.subscribe_user_updates()
    end

    socket =
      socket
      |> assign(
        page_title: gettext("Chats"),
        selected: nil,
        subscribed_id: nil,
        show_new: false,
        show_members: false,
        profile: nil,
        forward_id: nil,
        forward_targets: [],
        people: [],
        has_more: false,
        oldest_id: nil,
        other_read_at: nil,
        online_ids: EdenWeb.Presence.online_ids(),
        # Typing indicator (#11): user_id => %{name, token} for everyone currently
        # typing in the open conversation; `last_typing_at` throttles our own
        # outgoing broadcasts (monotonic ms, nil until first keystroke).
        typing_users: %{},
        last_typing_at: nil,
        # Thread typing (#103): separate from the room indicator — a thread typer
        # shows only inside the open thread panel (keyed by the root via the typing
        # event's root_id), with its own throttle.
        thread_typing_users: %{},
        last_thread_typing_at: nil,
        # DM peers in the sidebar (#94 review): lets presence_diff skip the
        # per-diff re-query when no peer's online status actually changed. Plain
        # list (not MapSet) — it's tiny and read back from assigns as an opaque
        # term, so MapSet ops would trip dialyzer's opaqueness check.
        sidebar_peer_ids: [],
        # True between a media send's submit and its server consume (#95): hides
        # the preview overlay immediately so the in-stream node takes over, instead
        # of the overlay lingering for the whole upload. Reset once consumed.
        sending_media: false,
        # FIFO of client_ids for in-flight media sends (#95): the hook pushes one on
        # media_sending just before each upload submit; send_attachment pops the
        # oldest to stamp the real message so its optimistic twin swaps out.
        media_client_ids: [],
        # Last upload percent pushed to the ring; gates redundant media_progress
        # frames so a slow link isn't flooded with no-op diffs (#95).
        last_media_pct: nil,
        composer: empty_composer(),
        folders: [],
        folder_tabs: [],
        folder_id: nil,
        folder_chat_id: nil,
        folder_checked: MapSet.new(),
        search: "",
        search_results: nil,
        # Channel mode (corporate layer): non-nil @channel switches the sidebar
        # to the channel's rooms; the message pane is shared as-is.
        channel: nil,
        channel_topic_id: nil,
        rooms: [],
        show_channel_edit: false,
        channel_form: nil,
        room_modal: nil,
        room_form: nil,
        members_open: false,
        members: [],
        add_open: false,
        addable: [],
        add_selected: MapSet.new(),
        invites_open: false,
        invites: [],
        new_invite_url: nil,
        # Threads: the open thread's root message + reply composer state; the
        # facepile (root_id => repliers) and the compact-run tracker for the
        # flat room layout.
        thread_root: nil,
        reply_composer: to_form(%{"body" => ""}, as: "reply"),
        thread_participants: %{},
        # Thread following (#57): whether the viewer follows the open thread, the
        # room's Threads-list panel + its rows, and per-thread unread counts
        # (root_id => unread) seeding the toolbar badge and per-footer indicators.
        thread_following: false,
        thread_list_open: false,
        thread_list: [],
        thread_unreads: %{},
        last_flat: nil,
        # The newest run tracker for the THREAD panel, mirroring last_flat for the
        # main stream — lets a live thread reply continue/break the compact run (#105).
        thread_last_flat: nil,
        # The currently-oldest on-screen message, so paginating older can re-stitch
        # the compact run across the page seam (#105).
        oldest_msg: nil,
        # Per-id compact flag, so re-streaming a row (reaction / thumbnail) keeps
        # the flat layout instead of re-showing the avatar/name (#67).
        compacts: %{},
        # The viewer's personal quick-react row (#67), shown in every message menu;
        # set in Settings, read once here (a remount on navigation picks up changes).
        my_quick: Chat.quick_reactions(scope),
        # Quote-reply (#71): the message currently being replied to (or nil). Shown
        # in the composer tray; its id rides the next send. `thread_reply_to` is the
        # same for the thread panel's own composer (a quote within the thread).
        reply_to: nil,
        thread_reply_to: nil,
        # Knock window (#41): a private room you're not in, reached by link.
        knock_room: nil,
        knock_pending: false,
        # Room add-members modal (#42).
        room_add: nil,
        room_addable: [],
        room_add_selected: MapSet.new(),
        room_invite_url: nil,
        # Corporate search (#43): channel-wide (sidebar) and in-room (header).
        channel_search: "",
        channel_results: nil,
        room_search_open: false,
        room_search: "",
        room_results: nil
      )
      |> stream(:thread, [])
      |> refresh_folders()
      |> stream(:conversations, Chat.list_conversations(scope))
      |> stream(:messages, [])
      # Accept anything: the server classifies by magic bytes and enforces the
      # per-kind size cap; the client cap is the largest (video). Images/video get
      # special rendering, everything else becomes a downloadable file.
      |> allow_upload(:attachment,
        accept: :any,
        max_entries: Chat.max_album_entries(),
        max_file_size: Chat.max_attachment_bytes(),
        # Feed the in-stream optimistic node a determinate progress ring (#95) —
        # Telegram-style, instead of an indeterminate spinner that can't show how
        # far a slow cross-border upload has gotten.
        progress: &handle_attachment_progress/3
      )
      # Channel avatar (#70): a single image, processed server-side to a square.
      |> allow_upload(:channel_avatar,
        accept: ~w(.png .jpg .jpeg .gif .webp),
        max_entries: 1,
        max_file_size: 5_000_000
      )

    {:ok, socket}
  end

  @impl true
  # Channel mode: /channels/:channel_id[/r/:id[/m/:message_id]]. These match
  # first — their params carry "channel_id", which the /app routes never do.
  def handle_params(%{"channel_id" => channel_id} = params, _uri, socket) do
    # #41: channels are never closed — following any link auto-joins (general).
    # :not_found only when the channel truly doesn't exist.
    case Channels.ensure_member(socket.assigns.current_scope, channel_id) do
      {:ok, channel} ->
        socket = enter_channel(socket, channel)

        case params do
          %{"id" => room_id, "message_id" => message_id} ->
            open_room(socket, channel, room_id, message_id)

          %{"id" => room_id} ->
            open_room(socket, channel, room_id, nil)

          _ ->
            # No auto-open: /channels/:cid is the room list (mobile "back"
            # must land here, not bounce into the first room again).
            {:noreply, socket |> unsubscribe() |> assign(selected: nil)}
        end

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Channel not found."))
         |> push_navigate(to: ~p"/app")}
    end
  end

  def handle_params(%{"id" => id, "message_id" => message_id}, _uri, socket) do
    case Chat.get_conversation(socket.assigns.current_scope, id) do
      # A room reached via the DM permalink shape — bounce to its channel home.
      {:ok, %{channel_id: cid} = conversation} when not is_nil(cid) ->
        {:noreply,
         push_navigate(socket, to: ~p"/channels/#{cid}/r/#{conversation.id}/m/#{message_id}")}

      {:ok, conversation} ->
        # The client scrolls to and highlights the message if it's on the page,
        # otherwise reports back so we can say it's unavailable (deleted/old).
        # A reply permalink opens its thread panel and focuses inside it.
        socket =
          socket
          |> leave_channel_mode()
          |> select_conversation(conversation)
          |> focus_message_target(message_id)

        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, conversation_gone(socket)}
    end
  end

  def handle_params(%{"id" => id}, _uri, socket) do
    case Chat.get_conversation(socket.assigns.current_scope, id) do
      {:ok, %{channel_id: cid} = conversation} when not is_nil(cid) ->
        {:noreply, push_navigate(socket, to: ~p"/channels/#{cid}/r/#{conversation.id}")}

      {:ok, conversation} ->
        {:noreply, socket |> leave_channel_mode() |> select_conversation(conversation)}

      {:error, :not_found} ->
        {:noreply, conversation_gone(socket)}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> leave_channel_mode()
     |> unsubscribe()
     |> assign(selected: nil)
     |> refresh_sidebar()}
  end

  # #41 access matrix: a room link auto-joins an open room, opens one you're in,
  # or (private, not a member) lands you in the channel. get_room is trusted
  # (no membership filter) — we resolve access explicitly, then materialize.
  defp open_room(socket, channel, room_id, message_id) do
    user_id = socket.assigns.current_scope.user.id
    room = Chat.get_room(room_id)

    if is_nil(room) or room.channel_id != channel.id do
      {:noreply,
       socket
       |> put_flash(:error, gettext("Conversation not found."))
       |> push_navigate(to: ~p"/channels/#{channel.id}")}
    else
      verdict =
        Chat.resolve_room_access(%{
          room_member?: Chat.room_member?(room.id, user_id),
          visibility: room.visibility
        })

      open_room_verdict(socket, channel, room, message_id, verdict)
    end
  end

  defp open_room_verdict(socket, _channel, room, message_id, :open_join) do
    :ok = Chat.join_room(room.id, socket.assigns.current_scope.user.id)
    finish_open_room(socket, room, message_id)
  end

  defp open_room_verdict(socket, _channel, room, message_id, :member) do
    finish_open_room(socket, room, message_id)
  end

  defp open_room_verdict(socket, _channel, room, _message_id, :knock) do
    # Land in the channel (no room selected) and show the knock window for this
    # private room — request access, or wait for an admin to add you.
    pending = Chat.pending_join_request(room.id, socket.assigns.current_scope.user.id) != nil

    {:noreply,
     socket
     |> unsubscribe()
     |> assign(selected: nil, knock_room: room, knock_pending: pending)}
  end

  defp finish_open_room(socket, room, message_id) do
    # Reload through the scoped path now that membership is guaranteed (fills
    # unread/preload consistently with the rest of the message pane). A race
    # (admin deletes the room between the access check and here) bounces to the
    # channel home rather than crashing on a hard match.
    case Chat.get_conversation(socket.assigns.current_scope, room.id) do
      {:ok, loaded} ->
        # Remember this as the channel's last room (#81) before select_conversation —
        # its refresh_rail re-reads list_channels, so the rail's entry link updates.
        Channels.record_last_room(socket.assigns.current_scope, loaded.channel_id, loaded.id)
        socket = socket |> refresh_rooms() |> select_conversation(loaded)
        socket = if message_id, do: focus_message_target(socket, message_id), else: socket
        {:noreply, socket}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Conversation not found."))
         |> push_navigate(to: ~p"/channels/#{room.channel_id}")}
    end
  end

  defp enter_channel(socket, channel) do
    old = socket.assigns.channel_topic_id
    if old && old != channel.id, do: Channels.unsubscribe_channel(old)
    if old != channel.id, do: Channels.subscribe_channel(channel.id)

    assign(socket,
      channel: channel,
      channel_topic_id: channel.id,
      rooms: Chat.list_rooms(socket.assigns.current_scope, channel.id),
      page_title: channel.name,
      # Cleared on every channel entry; the :knock verdict re-sets it after.
      knock_room: nil,
      knock_pending: false,
      # The room-add modal can't legitimately survive a channel patch (the
      # scrim blocks room switches) — but a {:room_deleted} patch could leave
      # it referencing a dead room; reset defensively.
      room_add: nil,
      room_invite_url: nil,
      channel_search: "",
      channel_results: nil
    )
  end

  defp leave_channel_mode(socket) do
    if old = socket.assigns.channel_topic_id, do: Channels.unsubscribe_channel(old)

    # Modal flags reset too — otherwise a members/invites modal left open
    # would auto-reopen on the next visit to any channel.
    assign(socket,
      channel: nil,
      channel_topic_id: nil,
      rooms: [],
      members_open: false,
      add_open: false,
      invites_open: false,
      new_invite_url: nil,
      room_add: nil,
      room_invite_url: nil,
      # A staged quote-reply (#71) belonged to a room — drop it on the way out.
      reply_to: nil,
      thread_reply_to: nil,
      # Threads (#57) are a rooms feature — clear the panel + badges leaving channel mode.
      thread_root: nil,
      thread_following: false,
      thread_list_open: false,
      thread_list: [],
      thread_unreads: %{}
    )
  end

  defp conversation_gone(socket) do
    socket
    |> put_flash(:error, gettext("Conversation not found."))
    |> push_navigate(to: ~p"/app")
  end

  # Whether the given conversation is the one currently open.
  defp open?(socket, conversation_id) do
    match?(%{id: ^conversation_id}, socket.assigns.selected)
  end

  @impl true
  def handle_event("composer_changed", %{"message" => %{"body" => body}}, socket) do
    # Track the value server-side so resetting to "" after send produces a real
    # diff that clears the input.
    {:noreply,
     socket
     |> assign(composer: to_form(%{"body" => body}, as: "message"))
     |> maybe_broadcast_typing(body)}
  end

  # Fired the instant a media send is submitted (#95): close the preview overlay
  # now (the in-stream node takes over) AND stash the send's client_id FIFO. The id
  # rides this fire-and-forget push, which reaches us BEFORE the upload's "send"
  # (same channel → ordered), so `send_attachment` can stamp the real message and
  # its optimistic twin swaps out — without the old two-pass gating the upload.
  def handle_event("media_sending", %{"id" => id}, socket) when is_binary(id) do
    {:noreply, assign(socket, sending_media: true, media_client_ids: stash_cid(socket, id))}
  end

  def handle_event("media_sending", _params, socket),
    do: {:noreply, assign(socket, sending_media: true)}

  # The watchdog hook fires this when an upload stalled (no real row, no error): the
  # entry is still staged, so clearing the flag re-shows the overlay (with its
  # cancel affordance) and the user can retry or cancel (#95).
  def handle_event("media_send_reset", _params, socket),
    do: {:noreply, assign(socket, sending_media: false)}

  # A client on cached PRE-redesign JS still uses the old two-pass and pushes the
  # id on this event instead of media_sending. Stash it the same way so its send
  # still correlates during the deploy window; a malformed payload is ignored.
  # Safe to delete (this clause + the catch-all below) once no client can still be
  # serving cached pre-#95 JS — i.e. one asset-cache lifetime after the deploy.
  def handle_event("media_client_id", %{"id" => id}, socket) when is_binary(id) do
    {:noreply, assign(socket, media_client_ids: stash_cid(socket, id))}
  end

  def handle_event("media_client_id", _params, socket), do: {:noreply, socket}

  def handle_event("send", %{"message" => %{"body" => body} = msg}, socket) do
    %{current_scope: scope, selected: conversation} = socket.assigns
    client_id = msg["client_id"]
    reply_to_id = msg["reply_to_id"]

    cond do
      is_nil(conversation) ->
        {:noreply, socket}

      socket.assigns.uploads.attachment.entries != [] ->
        # The media client_id rode the socket (media_sending), not the form; pop the
        # oldest queued one to stamp this send so its optimistic twin swaps out (#95).
        {cid, rest} = pop_media_client_id(socket.assigns.media_client_ids)
        socket = assign(socket, media_client_ids: rest)
        send_attachment(socket, scope, conversation, body, reply_to_id, cid)

      String.trim(body) == "" ->
        {:noreply, assign(socket, composer: empty_composer())}

      true ->
        send_text(socket, scope, conversation, body, client_id, reply_to_id)
    end
  end

  # Ignore malformed send payloads (e.g. a crafted event) instead of crashing.
  def handle_event("send", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :attachment, ref)}
  end

  def handle_event("cancel_all_uploads", _params, socket) do
    {:noreply, cancel_staged_attachments(socket)}
  end

  def handle_event("load_more", _params, socket) do
    %{current_scope: scope, selected: conversation, oldest_id: oldest_id} = socket.assigns

    case conversation && oldest_id &&
           Chat.list_messages(scope, conversation.id, limit: @page, before: oldest_id) do
      {:ok, older} when older != [] ->
        # Compact the paged-in batch (the bug was streaming it raw, so a whole page
        # of older messages re-showed avatar+name — #105), then re-stitch the run
        # across the seam: the message that WAS the top may now continue the newest
        # older message's run.
        {marked, _} = mark_compact(older, conversation)

        {:noreply,
         socket
         |> restitch_seam(conversation, marked)
         |> stream(:messages, marked, at: 0)
         |> assign(
           has_more: length(older) == @page,
           oldest_id: hd(marked).id,
           oldest_msg: List.first(marked),
           # Record their (now-correct) compact flags so a later reaction/thumbnail
           # re-stream restores them instead of falling back to the struct default.
           compacts: Map.merge(socket.assigns.compacts, Map.new(marked, &{&1.id, &1.compact}))
         )}

      _ ->
        {:noreply, assign(socket, has_more: false)}
    end
  end

  def handle_event("toggle_new", _params, socket) do
    people =
      if socket.assigns.show_new,
        do: socket.assigns.people,
        else: Accounts.list_other_users(socket.assigns.current_scope)

    {:noreply, assign(socket, show_new: !socket.assigns.show_new, people: people)}
  end

  def handle_event("close_new", _params, socket) do
    {:noreply, assign(socket, show_new: false)}
  end

  # Open a profile popover. Your own card opens too (no Message button — an
  # "Edit profile" link instead); others are authorized by a shared conversation
  # in the context. The members modal (if open) stays open underneath.
  def handle_event("show_profile", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    if id == to_string(scope.user.id) do
      {:noreply, assign(socket, profile: scope.user)}
    else
      case Chat.get_shared_user(scope, id) do
        {:ok, user} ->
          {:noreply, assign(socket, profile: user)}

        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, gettext("Profile unavailable."))}
      end
    end
  end

  def handle_event("close_profile", _params, socket) do
    {:noreply, assign(socket, profile: nil)}
  end

  def handle_event("show_members", _params, socket) do
    {:noreply, assign(socket, show_members: true)}
  end

  def handle_event("close_members", _params, socket) do
    {:noreply, assign(socket, show_members: false)}
  end

  # --- Message actions -------------------------------------------------------

  def handle_event("delete_for_me", %{"id" => id}, socket) do
    Chat.delete_message_for_me(socket.assigns.current_scope, id)
    {:noreply, socket}
  end

  def handle_event("delete_for_both", %{"id" => id}, socket) do
    case Chat.delete_message_for_both(socket.assigns.current_scope, id) do
      :ok ->
        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't delete that message."))}
    end
  end

  def handle_event("delete_chat", %{"id" => id}, socket) do
    # Removal from the sidebar (and navigating away if it's the open one) is driven
    # by the {:conversation_left} broadcast on the user's own topic, so every one of
    # their sessions stays in sync.
    case Chat.delete_conversation(socket.assigns.current_scope, id) do
      :ok ->
        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't delete that chat."))}
    end
  end

  def handle_event("select_folder", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(folder_id: parse_folder_id(id))
     |> stream_conversations(reset: true)}
  end

  def handle_event("search", %{"q" => query}, socket) do
    trimmed = String.trim(query)

    cond do
      trimmed == "" ->
        {:noreply, assign(socket, search: "", search_results: nil)}

      # Too short to search: keep the panel open with a hint (nil results),
      # not a false "no results".
      String.length(trimmed) < Chat.search_min_chars() ->
        {:noreply, assign(socket, search: query, search_results: nil)}

      true ->
        {:noreply,
         assign(socket,
           search: query,
           search_results: Chat.search(socket.assigns.current_scope, query)
         )}
    end
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply,
     socket
     |> assign(search: "", search_results: nil)
     |> push_event("clear-search", %{})}
  end

  # Sidebar/tab refreshes are driven by the :folders_changed broadcast both
  # toggles emit on the user topic, so every session stays in sync.
  # Mark a chat/room read from its row menu (#42). mark_read is a 0-row no-op
  # for non-members; normalize first (a garbage id would CastError in the query).
  def handle_event("mark_as_read", %{"id" => id}, socket) do
    case Eden.Ids.normalize(id) do
      n when is_integer(n) ->
        Chat.mark_read(socket.assigns.current_scope, n)

        {:noreply,
         socket
         |> put_sidebar_conversation(n)
         |> refresh_folders()
         |> refresh_rooms()
         |> refresh_rail()}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_mute", %{"id" => id}, socket) do
    case Chat.toggle_conversation_mute(socket.assigns.current_scope, id) do
      {:ok, _} -> {:noreply, socket}
      {:error, _} -> {:noreply, put_flash(socket, :error, gettext("Couldn't update that chat."))}
    end
  end

  def handle_event("toggle_folder_mute", %{"id" => id}, socket) do
    case Chat.toggle_folder_mute(socket.assigns.current_scope, id) do
      {:ok, _} ->
        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't update that folder."))}
    end
  end

  ## Channel mode: channel edit/delete + room CRUD (context re-checks roles)

  def handle_event("open_channel_edit", _params, socket) do
    if socket.assigns.channel.role in ~w(owner admin) do
      form = to_form(Channels.change_channel(socket.assigns.channel))
      {:noreply, assign(socket, show_channel_edit: true, channel_form: form)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_channel_edit", _params, socket) do
    # Drop any staged (incl. errored) avatar entry so it can't linger or apply to
    # the wrong channel later.
    socket =
      Enum.reduce(socket.assigns.uploads.channel_avatar.entries, socket, fn entry, acc ->
        cancel_upload(acc, :channel_avatar, entry.ref)
      end)

    {:noreply, assign(socket, show_channel_edit: false)}
  end

  def handle_event("cancel_channel_avatar", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :channel_avatar, ref)}
  end

  # Live-upload + form validation for the edit modal (#70): registers the staged
  # avatar entry and keeps the name/about inputs controlled while typing.
  def handle_event("validate_channel", %{"channel" => params}, socket) do
    form = to_form(Channels.change_channel(socket.assigns.channel, params))
    {:noreply, assign(socket, channel_form: form)}
  end

  def handle_event("save_channel", %{"channel" => params}, socket) do
    scope = socket.assigns.current_scope

    case Channels.update_channel(scope, socket.assigns.channel.id, params) do
      {:ok, channel} ->
        # A staged avatar (#70) rides the same save.
        {channel, avatar_err} = consume_channel_avatar(socket, scope, channel)

        socket =
          socket
          |> assign(channel: channel, show_channel_edit: false, page_title: channel.name)
          |> then(
            &if(avatar_err,
              do: put_flash(&1, :error, gettext("Couldn't process that image.")),
              else: &1
            )
          )

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, channel_form: to_form(changeset))}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(show_channel_edit: false)
         |> put_flash(:error, gettext("Couldn't update that channel."))}
    end
  end

  # Admin+ removes the channel avatar from the open edit modal (keeps it open).
  def handle_event("remove_channel_avatar", _params, socket) do
    case Channels.remove_channel_avatar(socket.assigns.current_scope, socket.assigns.channel.id) do
      {:ok, channel} -> {:noreply, assign(socket, channel: channel)}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_event("delete_channel", _params, socket) do
    case Channels.delete_channel(socket.assigns.current_scope, socket.assigns.channel.id) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Channel deleted."))
         |> push_navigate(to: ~p"/app")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't delete that channel."))}
    end
  end

  def handle_event("open_new_room", _params, socket) do
    if socket.assigns.channel.role in ~w(owner admin) do
      {:noreply,
       assign(socket, room_modal: :new, room_form: to_form(Chat.change_room(), as: :room))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("open_room_rename", %{"id" => id}, socket) do
    with true <- socket.assigns.channel.role in ~w(owner admin),
         %{} = room <- Enum.find(socket.assigns.rooms, &(to_string(&1.id) == id)) do
      form = to_form(Chat.change_room(room), as: :room)
      {:noreply, assign(socket, room_modal: {:rename, room.id}, room_form: form)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("close_room_modal", _params, socket) do
    {:noreply, assign(socket, room_modal: nil)}
  end

  def handle_event("save_room", %{"room" => params}, socket) do
    result =
      case socket.assigns.room_modal do
        :new ->
          Channels.create_room(socket.assigns.current_scope, socket.assigns.channel.id, params)

        {:rename, room_id} ->
          Channels.rename_room(socket.assigns.current_scope, room_id, params)

        nil ->
          {:error, :not_found}
      end

    case result do
      {:ok, _room} ->
        # The room list refreshes via the channel-topic broadcast.
        {:noreply, assign(socket, room_modal: nil)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, room_form: to_form(changeset, as: :room))}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(room_modal: nil)
         |> put_flash(:error, gettext("Couldn't save that room."))}
    end
  end

  def handle_event("delete_room", %{"id" => id}, socket) do
    case Channels.delete_room(socket.assigns.current_scope, id) do
      :ok ->
        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't delete that room."))}
    end
  end

  ## Room menu (#42): favorites, reorder, add-members

  def handle_event("toggle_room_favorite", %{"id" => id}, socket) do
    # The :folders_changed broadcast refreshes the rooms list in all sessions.
    Chat.toggle_room_favorite(socket.assigns.current_scope, id)
    {:noreply, socket}
  end

  def handle_event("reorder_rooms", %{"ids" => ids}, socket) when is_list(ids) do
    case socket.assigns.channel do
      %{id: channel_id, role: role} when role in ["owner", "admin"] ->
        # The displayed sequence becomes the canonical order; the context
        # filters foreign ids and broadcasts :rooms_reordered.
        Channels.reorder_rooms(socket.assigns.current_scope, channel_id, ids)
        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("open_room_add", %{"id" => id}, socket) do
    with true <- socket.assigns.channel.role in ~w(owner admin),
         %{} = room <- Enum.find(socket.assigns.rooms, &(to_string(&1.id) == id)) do
      member_ids = MapSet.new(Chat.room_member_ids(room.id))

      addable =
        socket.assigns.current_scope
        |> Accounts.list_other_users()
        |> Enum.reject(&MapSet.member?(member_ids, &1.id))

      {:noreply,
       assign(socket,
         room_add: room,
         room_addable: addable,
         room_add_selected: MapSet.new(),
         room_invite_url: nil
       )}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("close_room_add", _params, socket) do
    {:noreply, assign(socket, room_add: nil, room_invite_url: nil)}
  end

  def handle_event("toggle_room_add_user", %{"id" => id}, socket) do
    case Integer.parse(id) do
      {user_id, ""} ->
        selected = socket.assigns.room_add_selected

        selected =
          if MapSet.member?(selected, user_id),
            do: MapSet.delete(selected, user_id),
            else: MapSet.put(selected, user_id)

        {:noreply, assign(socket, room_add_selected: selected)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("confirm_room_add", _params, socket) do
    case socket.assigns.room_add do
      %{id: room_id} ->
        ids = MapSet.to_list(socket.assigns.room_add_selected)

        case Channels.add_room_members(socket.assigns.current_scope, room_id, ids) do
          {:ok, _added} ->
            {:noreply, socket |> assign(room_add: nil) |> refresh_rooms()}

          {:error, _} ->
            {:noreply,
             socket
             |> assign(room_add: nil)
             |> put_flash(:error, gettext("Couldn't add those members."))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("create_room_invite", _params, socket) do
    case socket.assigns.room_add do
      %{id: room_id} ->
        case Channels.create_room_invite(socket.assigns.current_scope, room_id) do
          {:ok, _invite, raw} ->
            {:noreply, assign(socket, room_invite_url: url(~p"/channels/join/#{raw}"))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Couldn't create an invite link."))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # Admin declines a join request from the room's system message (#42/E5).
  def handle_event("decline_join", %{"id" => id}, socket) do
    case Channels.decline_room_join(socket.assigns.current_scope, id) do
      :ok -> {:noreply, socket}
      {:error, _} -> {:noreply, put_flash(socket, :error, gettext("Couldn't decline."))}
    end
  end

  ## Corporate search (#43)

  def handle_event("channel_search", %{"q" => q}, socket) do
    case socket.assigns.channel do
      %{id: channel_id} ->
        results = run_room_search(socket, {:channel, channel_id}, q)
        {:noreply, assign(socket, channel_search: q, channel_results: results)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("clear_channel_search", _params, socket) do
    {:noreply, assign(socket, channel_search: "", channel_results: nil)}
  end

  def handle_event("toggle_room_search", _params, socket) do
    open = !socket.assigns.room_search_open
    {:noreply, assign(socket, room_search_open: open, room_search: "", room_results: nil)}
  end

  def handle_event("room_search", %{"q" => q}, socket) do
    case socket.assigns.selected do
      %{channel_id: cid, id: room_id} when not is_nil(cid) ->
        results = run_room_search(socket, {:room, room_id}, q)
        {:noreply, assign(socket, room_search: q, room_results: results)}

      _ ->
        {:noreply, socket}
    end
  end

  ## Knock to join a private room (#41)

  def handle_event("request_join", _params, socket) do
    case socket.assigns.knock_room do
      %{id: room_id} ->
        case Channels.request_room_join(socket.assigns.current_scope, room_id) do
          {:ok, _} ->
            {:noreply, assign(socket, knock_pending: true)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Couldn't send the request."))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # Admin approves a join request from the room's system message.
  def handle_event("approve_join", %{"id" => id}, socket) do
    case Channels.approve_room_join(socket.assigns.current_scope, id) do
      :ok -> {:noreply, socket}
      {:error, _} -> {:noreply, put_flash(socket, :error, gettext("Couldn't add that member."))}
    end
  end

  ## Channel access: members, add-members, invite links, leave

  def handle_event("open_channel_members", _params, socket) do
    case Channels.list_members(socket.assigns.current_scope, socket.assigns.channel.id) do
      {:ok, members} -> {:noreply, assign(socket, members_open: true, members: members)}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_event("close_channel_members", _params, socket) do
    {:noreply, assign(socket, members_open: false)}
  end

  def handle_event("open_add_members", _params, socket) do
    with true <- socket.assigns.channel.role in ~w(owner admin),
         {:ok, members} <-
           Channels.list_members(socket.assigns.current_scope, socket.assigns.channel.id) do
      member_ids = MapSet.new(members, & &1.user.id)

      addable =
        socket.assigns.current_scope
        |> Accounts.list_other_users()
        |> Enum.reject(&MapSet.member?(member_ids, &1.id))

      {:noreply, assign(socket, add_open: true, addable: addable, add_selected: MapSet.new())}
    else
      # Not an admin anymore / kicked between render and click — no modal.
      _ -> {:noreply, socket}
    end
  end

  def handle_event("close_add_members", _params, socket) do
    {:noreply, assign(socket, add_open: false)}
  end

  def handle_event("toggle_add_user", %{"id" => id}, socket) do
    case Integer.parse(id) do
      {user_id, ""} ->
        selected = socket.assigns.add_selected

        selected =
          if MapSet.member?(selected, user_id),
            do: MapSet.delete(selected, user_id),
            else: MapSet.put(selected, user_id)

        {:noreply, assign(socket, add_selected: selected)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("confirm_add_members", _params, socket) do
    ids = MapSet.to_list(socket.assigns.add_selected)

    case Channels.add_members(socket.assigns.current_scope, socket.assigns.channel.id, ids) do
      {:ok, _added} ->
        {:noreply, assign(socket, add_open: false)}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(add_open: false)
         |> put_flash(:error, gettext("Couldn't add those members."))}
    end
  end

  def handle_event("remove_member", %{"id" => id}, socket) do
    case Channels.remove_member(socket.assigns.current_scope, socket.assigns.channel.id, id) do
      :ok ->
        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't remove that member."))}
    end
  end

  # No guard: the context validates the role and errors on crafted values —
  # a guarded clause here would FunctionClauseError on them instead.
  def handle_event("set_member_role", %{"id" => id, "role" => role}, socket) do
    case Channels.set_member_role(
           socket.assigns.current_scope,
           socket.assigns.channel.id,
           id,
           role
         ) do
      :ok -> {:noreply, socket}
      {:error, _} -> {:noreply, put_flash(socket, :error, gettext("Couldn't change that role."))}
    end
  end

  def handle_event("transfer_ownership", %{"id" => id}, socket) do
    case Channels.transfer_ownership(socket.assigns.current_scope, socket.assigns.channel.id, id) do
      :ok ->
        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't transfer ownership."))}
    end
  end

  def handle_event("leave_channel", _params, socket) do
    case Channels.leave_channel(socket.assigns.current_scope, socket.assigns.channel.id) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("You left the channel."))
         |> push_navigate(to: ~p"/app")}

      {:error, :owner} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Transfer ownership or delete the channel before leaving.")
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't leave the channel."))}
    end
  end

  def handle_event("open_invites", _params, socket) do
    case Channels.list_invites(socket.assigns.current_scope, socket.assigns.channel.id) do
      {:ok, invites} ->
        {:noreply, assign(socket, invites_open: true, invites: invites, new_invite_url: nil)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("close_invites", _params, socket) do
    {:noreply, assign(socket, invites_open: false, new_invite_url: nil)}
  end

  def handle_event("create_invite", _params, socket) do
    case Channels.create_invite(socket.assigns.current_scope, socket.assigns.channel.id) do
      {:ok, _invite, raw} ->
        {:noreply,
         socket
         |> refresh_invites()
         |> assign(new_invite_url: url(~p"/channels/join/#{raw}"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't create an invite link."))}
    end
  end

  def handle_event("revoke_invite", %{"id" => id}, socket) do
    case Channels.revoke_invite(socket.assigns.current_scope, id) do
      :ok ->
        {:noreply, refresh_invites(socket)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't revoke that link."))}
    end
  end

  def handle_event("forward_prompt", %{"id" => id}, socket) do
    targets = Chat.list_conversations(socket.assigns.current_scope)
    {:noreply, assign(socket, forward_id: id, forward_targets: targets)}
  end

  def handle_event("close_forward", _params, socket) do
    {:noreply, assign(socket, forward_id: nil)}
  end

  def handle_event("move_to_folder_prompt", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Chat.get_conversation(scope, id) do
      {:ok, conversation} ->
        checked = MapSet.new(Chat.conversation_folder_ids(scope, conversation.id))
        {:noreply, assign(socket, folder_chat_id: conversation.id, folder_checked: checked)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_folder", %{"folder" => folder_id}, socket) do
    %{current_scope: scope, folder_chat_id: cid} = socket.assigns
    # The toggle broadcasts :folders_changed on the user topic, so this session's
    # tabs/badges and list refresh via handle_info; here we just re-sync the picks.
    Chat.toggle_conversation_folder(scope, cid, folder_id)
    checked = MapSet.new(Chat.conversation_folder_ids(scope, cid))
    {:noreply, assign(socket, folder_checked: checked)}
  end

  def handle_event("close_folders", _params, socket) do
    {:noreply, assign(socket, folder_chat_id: nil)}
  end

  def handle_event("forward", %{"target" => target_id}, socket) do
    %{current_scope: scope, forward_id: forward_id} = socket.assigns

    case Chat.forward_message(scope, forward_id, target_id) do
      {:ok, _message} ->
        {:noreply,
         socket
         |> assign(forward_id: nil)
         |> put_flash(:info, gettext("Forwarded."))
         |> push_patch(to: ~p"/app/c/#{target_id}")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(forward_id: nil)
         |> put_flash(:error, gettext("Couldn't forward that message."))}
    end
  end

  # Clipboard copies are done client-side; the hook reports back for feedback.
  def handle_event("copied", %{"what" => "link"}, socket),
    do: {:noreply, put_flash(socket, :info, gettext("Link copied."))}

  def handle_event("copied", _params, socket),
    do: {:noreply, put_flash(socket, :info, gettext("Copied."))}

  ## Threads

  def handle_event("open_thread", %{"id" => id}, socket) do
    {:noreply, open_thread(socket, id)}
  end

  def handle_event("close_thread", _params, socket) do
    {:noreply, socket |> clear_thread_typing() |> assign(thread_root: nil, thread_reply_to: nil)}
  end

  # The Threads list panel (#57): the room's followed threads, drill into any.
  def handle_event("open_threads", _params, socket) do
    scope = socket.assigns.current_scope

    {:noreply,
     assign(socket,
       thread_list_open: true,
       thread_root: nil,
       thread_reply_to: nil,
       thread_list: Chat.list_followed_threads(scope, socket.assigns.selected.id)
     )}
  end

  def handle_event("close_threads", _params, socket),
    do: {:noreply, assign(socket, thread_list_open: false)}

  # Follow / unfollow the open thread; reflects in the header bell + unread badges.
  def handle_event("toggle_follow_thread", _params, socket) do
    case socket.assigns.thread_root do
      %{} = root ->
        scope = socket.assigns.current_scope

        {following, unreads} =
          if socket.assigns.thread_following do
            Chat.unfollow_thread(scope, root.id)
            {false, Map.delete(socket.assigns.thread_unreads, root.id)}
          else
            Chat.follow_thread(scope, root.id)
            {true, Map.put_new(socket.assigns.thread_unreads, root.id, 0)}
          end

        # No root re-stream: the footer pill only shows when unread > 0, and the
        # thread is already read (unread 0) by the time its bell is reachable —
        # so toggling follow never changes the footer.
        {:noreply,
         socket
         |> assign(thread_following: following, thread_unreads: unreads)
         |> refresh_thread_list()}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("react", %{"id" => id, "emoji" => emoji}, socket)
      when is_binary(emoji) do
    # The toggle broadcasts {:reaction_changed, message}; our own session
    # re-renders the chips from that, like everyone else's.
    case Chat.toggle_reaction(socket.assigns.current_scope, id, emoji) do
      {:ok, _message} ->
        {:noreply, socket}

      {:error, reason} ->
        # A rejected toggle (gone/not a member/non-allowed emoji/add-add race) is a
        # no-op for the UI; log for diagnosis rather than failing silently.
        Logger.debug("react rejected: #{inspect(reason)} (message #{inspect(id)})")
        {:noreply, socket}
    end
  end

  # A malformed/hostile payload (no emoji, or a non-string emoji) — ignore rather
  # than crash the LiveView on this client-reachable event.
  def handle_event("react", _params, socket), do: {:noreply, socket}

  # Quote-reply (#71): stage the target in the composer tray. The menu/swipe/arrow
  # also focus the composer client-side (JS.focus), so this just sets the assign.
  def handle_event("reply", %{"id" => id}, socket) do
    case Chat.get_message(socket.assigns.current_scope, id) do
      nil -> {:noreply, socket}
      message -> {:noreply, assign(socket, reply_to: message)}
    end
  end

  def handle_event("reply", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_reply", _params, socket), do: {:noreply, assign(socket, reply_to: nil)}

  # Quote-reply from inside the thread panel: stages the target in the THREAD
  # composer, so the reply posts into the thread (not the room).
  def handle_event("reply_in_thread", %{"id" => id}, socket) do
    case Chat.get_message(socket.assigns.current_scope, id) do
      nil -> {:noreply, socket}
      message -> {:noreply, assign(socket, thread_reply_to: message)}
    end
  end

  def handle_event("reply_in_thread", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_thread_reply", _params, socket),
    do: {:noreply, assign(socket, thread_reply_to: nil)}

  # Tap a rendered quote → scroll to + highlight the original. Reuses the permalink
  # resolver so a quoted thread reply (dom id `thread-<id>`, not `messages-<id>`)
  # is found and its thread opened, instead of flashing "message unavailable".
  def handle_event("focus_original", %{"id" => id}, socket) do
    {:noreply, focus_message_target(socket, id)}
  end

  # Jump to the thread's root in the main stream: close the panel (on mobile it
  # covers the stream) and focus-highlight the root, reusing the permalink path.
  def handle_event("jump_to_root", _params, socket) do
    case socket.assigns.thread_root do
      %{id: id} ->
        {:noreply,
         socket
         # Close BOTH the thread and the Threads-list panel — otherwise nulling
         # thread_root re-reveals the list aside over the message we jumped to.
         |> assign(thread_root: nil, thread_list_open: false)
         |> push_event("focus_message", %{domId: "messages-#{id}"})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("reply_changed", %{"reply" => %{"body" => body}}, socket) do
    {:noreply,
     socket
     |> assign(reply_composer: to_form(%{"body" => body}, as: "reply"))
     |> maybe_broadcast_thread_typing(body)}
  end

  def handle_event("send_reply", %{"reply" => %{"body" => body} = reply}, socket) do
    root = socket.assigns.thread_root

    if is_nil(root) or String.trim(body) == "" do
      {:noreply, socket}
    else
      attrs = %{"body" => body, "reply_to_id" => reply["reply_to_id"]}

      case Chat.create_reply(socket.assigns.current_scope, root.id, attrs) do
        {:ok, _reply} ->
          # The reply itself arrives via the {:thread_reply} broadcast.
          {:noreply,
           assign(socket,
             reply_composer: to_form(%{"body" => ""}, as: "reply"),
             thread_reply_to: nil,
             last_thread_typing_at: nil
           )}

        {:error, %Ecto.Changeset{}} ->
          {:noreply, put_flash(socket, :error, gettext("That reply can't be sent."))}

        {:error, _} ->
          {:noreply,
           socket
           |> assign(thread_root: nil)
           |> put_flash(:error, gettext("Thread not found."))}
      end
    end
  end

  def handle_event("message_unavailable", _params, socket),
    do: {:noreply, put_flash(socket, :error, gettext("That message is unavailable."))}

  # "Send message" from a profile: open (or reuse) a 1:1 with that user. The
  # profile was reached through a shared conversation, so re-checking the share
  # both authorizes and validates the id before creating anything.
  def handle_event("message_user", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with {:ok, user} <- Chat.get_shared_user(scope, id),
         {:ok, conversation} <- Chat.create_conversation(scope, [user.id]) do
      socket = assign(socket, profile: nil, show_members: false)

      # From a channel/room the messenger is a different route — navigate (a
      # full remount). Within the messenger, a lighter patch + sidebar refresh.
      if socket.assigns.channel do
        {:noreply, push_navigate(socket, to: ~p"/app/c/#{conversation.id}")}
      else
        {:noreply,
         socket
         |> stream(:conversations, Chat.list_conversations(scope), reset: true)
         |> push_patch(to: ~p"/app/c/#{conversation.id}")}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Couldn't start the conversation."))}
    end
  end

  def handle_event("start", %{"member_ids" => ids} = params, socket) do
    scope = socket.assigns.current_scope
    opts = if length(List.wrap(ids)) > 1, do: [group: true, title: params["title"]], else: []

    case Chat.create_conversation(scope, List.wrap(ids), opts) do
      {:ok, conversation} ->
        {:noreply,
         socket
         |> assign(show_new: false)
         |> stream(:conversations, Chat.list_conversations(scope), reset: true)
         |> push_patch(to: ~p"/app/c/#{conversation.id}")}

      {:error, :no_members} ->
        {:noreply, put_flash(socket, :error, gettext("Pick at least one person."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't start the conversation."))}
    end
  end

  def handle_event("start", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("Pick at least one person."))}
  end

  @impl true
  def handle_info({:new_message, message}, socket) do
    # Incoming message in the open conversation counts as read; skip our own
    # (nothing to clear, no write needed).
    if message.sender_id != socket.assigns.current_scope.user.id do
      Chat.mark_read(socket.assigns.current_scope, message.conversation_id)
    end

    # Room flat layout: continue (or break) the compact run live.
    {message, socket} =
      case {socket.assigns.selected, socket.assigns.last_flat} do
        {%{channel_id: cid}, last} when not is_nil(cid) ->
          marked = %{message | compact: compact?(message, last)}
          {marked, assign(socket, last_flat: {message.sender_id, message.inserted_at})}

        _ ->
          {message, socket}
      end

    {:noreply,
     socket
     # The sender just sent — they're no longer typing, so clear them now rather
     # than waiting out the TTL (#11).
     |> drop_typing(:typing_users, message.sender_id)
     |> assign(compacts: Map.put(socket.assigns.compacts, message.id, message.compact))
     |> stream_insert(:messages, message)}
  end

  # A reply landed in a thread of the open conversation: refresh the root's
  # footer (count/time/facepile), the viewer's unread, and the panel if open.
  def handle_info({:thread_reply, root, reply}, socket) do
    viewing? = thread_open_for?(socket, root.id)
    # Reading the thread keeps it read on the server (the DB just incremented it).
    if viewing?, do: Chat.mark_thread_read(socket.assigns.current_scope, root.id)

    socket =
      if open?(socket, root.conversation_id) do
        socket
        # Authoritative unread from the server: covers the auto-followed root
        # author (no local key yet) and viewers reading right now (now zero).
        |> sync_thread_unread(root.id)
        |> restream_root_if_loaded(root)
        |> bump_facepile(root.id, reply.sender)
        |> refresh_thread_list()
      else
        socket
      end

    if viewing? do
      {reply, socket} = mark_thread_compact(socket, reply)

      {:noreply,
       socket
       |> drop_typing(:thread_typing_users, reply.sender_id)
       |> assign(thread_root: root)
       |> stream_insert(:thread, reply)}
    else
      {:noreply, socket}
    end
  end

  # A reply was deleted for everyone: the root's footer + the viewer's unread and
  # the Threads list all need to re-settle.
  def handle_info({:thread_updated, root}, socket) do
    socket =
      if open?(socket, root.conversation_id) do
        participants =
          Chat.thread_participants(socket.assigns.current_scope, root.conversation_id, [root.id])

        socket
        |> restream_root_if_loaded(root)
        |> assign(
          :thread_participants,
          Map.merge(socket.assigns.thread_participants, participants)
        )
        |> sync_thread_unread(root.id)
        |> refresh_thread_list()
      else
        socket
      end

    if thread_open_for?(socket, root.id) do
      {:noreply, assign(socket, thread_root: root)}
    else
      {:noreply, socket}
    end
  end

  # Delete-for-both: the message is removed from the conversation for everyone.
  # If it was a thread root, drop it from the unread map + Threads list too.
  def handle_info({:message_deleted, message}, socket) do
    if open?(socket, message.conversation_id) do
      {:noreply,
       socket
       |> stream_delete_by_dom_id(:messages, "messages-#{message.id}")
       |> stream_delete_by_dom_id(:thread, "thread-#{message.id}")
       |> close_thread_if_root_gone(message.id)
       |> assign(:thread_unreads, Map.delete(socket.assigns.thread_unreads, message.id))
       |> refresh_thread_list()}
    else
      {:noreply, socket}
    end
  end

  # Another tab of the same user read a thread: zero its badge here too.
  def handle_info({:thread_read, conversation_id, root_id}, socket) do
    if open?(socket, conversation_id) do
      {:noreply,
       socket
       |> assign(:thread_unreads, Map.replace(socket.assigns.thread_unreads, root_id, 0))
       |> refresh_thread_list()}
    else
      {:noreply, socket}
    end
  end

  # Delete-for-me (on the user's own topic): drop the message from this session
  # and refresh the sidebar preview (the hidden message may have been the last one).
  def handle_info({:message_hidden, conversation_id, message_id}, socket) do
    socket =
      if open?(socket, conversation_id),
        do:
          socket
          |> stream_delete_by_dom_id(:messages, "messages-#{message_id}")
          |> stream_delete_by_dom_id(:thread, "thread-#{message_id}")
          |> close_thread_if_root_gone(message_id),
        else: socket

    {:noreply, put_sidebar_conversation(socket, conversation_id)}
  end

  # A thumbnail finished generating: swap the full image for it, in place. Guard
  # against a late broadcast arriving after the user switched conversations.
  def handle_info({:thumbnail_ready, message}, socket) do
    selected = socket.assigns.selected

    if selected && selected.id == message.conversation_id do
      {:noreply, stream_insert(socket, :messages, restore_compact(socket, message))}
    else
      {:noreply, socket}
    end
  end

  # A reaction was toggled (anyone, this conversation): re-render the message's
  # chips, restoring its compact flag so the flat row doesn't sprout an avatar.
  def handle_info({:reaction_changed, message}, socket) do
    selected = socket.assigns.selected

    if selected && selected.id == message.conversation_id do
      {:noreply, apply_reaction_change(socket, message, socket.assigns.thread_root)}
    else
      {:noreply, socket}
    end
  end

  # The other participant read up to read_at — refresh delivery ticks. Re-stream
  # without reset so existing rows are morphed in place (keeps an open action menu
  # and any loaded older messages) instead of being torn down and recreated.
  def handle_info({:read, reader_id, read_at}, socket) do
    %{current_scope: scope, selected: conversation} = socket.assigns

    if conversation && reader_id != scope.user.id do
      {:ok, messages} = Chat.list_messages(scope, conversation.id, limit: @page)

      {:noreply, socket |> assign(other_read_at: read_at) |> stream(:messages, messages)}
    else
      {:noreply, socket}
    end
  end

  # The user deleted a conversation (in this or another of their sessions): drop it
  # from the sidebar, refresh folder badges (its unread no longer counts), and
  # leave the thread if it was the one open here.
  def handle_info({:conversation_left, conversation_id}, socket) do
    socket =
      if socket.assigns.channel do
        # No DM stream rendered in channel mode; badges refresh on return.
        socket
      else
        stream_delete_by_dom_id(socket, :conversations, "conversations-#{conversation_id}")
      end
      |> refresh_folders()

    if open?(socket, conversation_id) do
      {:noreply, socket |> unsubscribe() |> assign(selected: nil) |> push_patch(to: ~p"/app")}
    else
      {:noreply, socket}
    end
  end

  # A conversation the user belongs to changed: move it to the top of the list
  # with refreshed unread/preview, without reloading the whole sidebar. Folder
  # unread badges may have changed too, so refresh the tabs.
  def handle_info({:conversation_activity, conversation_id}, socket) do
    {:noreply,
     socket
     |> put_sidebar_conversation(conversation_id, at: 0)
     |> refresh_folders()
     # Room activity bumps the channel's rail badge; for DM activity this is a
     # cheap no-op recompute (DMs never contribute to channel aggregates).
     |> refresh_rail()}
  end

  # Folder set / membership / order / mute changed in one of the user's
  # sessions: refresh the tab bar, re-apply the active filter, and refresh room
  # badges (room mute lives on the same memberships).
  def handle_info(:folders_changed, socket) do
    {:noreply,
     socket |> refresh_folders() |> refresh_rooms() |> stream_conversations(reset: true)}
  end

  ## Channel mode: events on the channel topic (subscribed while inside one)

  def handle_info({:channel_renamed, renamed}, socket) do
    case socket.assigns.channel do
      %{id: id, role: role} when id == renamed.id ->
        # The broadcast carries the actor's role — keep this session's own.
        {:noreply, assign(socket, channel: %{renamed | role: role}, page_title: renamed.name)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:channel_deleted, id}, socket) do
    if match?(%{id: ^id}, socket.assigns.channel) do
      {:noreply,
       socket
       |> put_flash(:error, gettext("This channel was deleted."))
       |> push_navigate(to: ~p"/app")}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:room_created, _room}, socket), do: {:noreply, refresh_rooms(socket)}
  def handle_info(:rooms_reordered, socket), do: {:noreply, refresh_rooms(socket)}

  # Membership/roles changed (add/remove/promote/transfer): my own role might
  # have moved too, so re-fetch the channel; refresh the members modal if open.
  def handle_info({:members_changed, channel_id}, socket) do
    if match?(%{id: ^channel_id}, socket.assigns.channel) do
      {:noreply,
       socket
       |> refresh_channel_access(channel_id)
       |> refresh_rooms()
       |> maybe_clear_knock()}
    else
      {:noreply, socket}
    end
  end

  # I was removed from (or left) a channel in another session: get out of it.
  def handle_info({:removed_from_channel, channel_id}, socket) do
    if match?(%{id: ^channel_id}, socket.assigns.channel) do
      {:noreply,
       socket
       |> put_flash(:error, gettext("You no longer have access to this channel."))
       |> push_navigate(to: ~p"/app")}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:room_renamed, room}, socket) do
    socket = refresh_rooms(socket)

    if open?(socket, room.id) do
      {:noreply, assign(socket, selected: %{socket.assigns.selected | name: room.name})}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:room_deleted, room_id}, socket) do
    socket = refresh_rooms(socket)

    if open?(socket, room_id) do
      {:noreply,
       socket
       |> unsubscribe()
       |> assign(selected: nil)
       |> push_patch(to: ~p"/channels/#{socket.assigns.channel.id}", replace: true)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", payload: payload}, socket) do
    # Header status + open profile read @online_ids (plain assigns) and refresh on
    # this update for free. The sidebar dots live in a `phx-update="stream"` list,
    # so they need a re-stream (#10) — but only when a conversation *peer's* status
    # actually changed; otherwise skip the per-diff DB re-query, since presence is
    # one global topic and every connect/nav by anyone fans a diff to all sessions
    # (#94 review). No-op in channel mode (rooms show no presence dot).
    socket = assign(socket, online_ids: EdenWeb.Presence.online_ids())
    changed = presence_changed_ids(payload)
    peers = socket.assigns.sidebar_peer_ids

    if socket.assigns.channel || Enum.all?(changed, &(&1 not in peers)) do
      {:noreply, socket}
    else
      {:noreply, stream_conversations(socket, [])}
    end
  end

  # Someone is typing in the open conversation (#11). Ignore our own echo (incl.
  # other tabs of ours); (re)arm their TTL timer so a steady typer keeps a single
  # timer and the indicator doesn't flicker.
  def handle_info({:typing, user_id, name, root_id}, socket) do
    cond do
      user_id == socket.assigns.current_scope.user.id ->
        {:noreply, socket}

      # Main composer (room/DM): root_id is nil → the room indicator.
      is_nil(root_id) ->
        {:noreply, track_typing(socket, :typing_users, user_id, name)}

      # Thread reply (#103): show only inside that exact open thread panel.
      match?(%{id: ^root_id}, socket.assigns.thread_root) ->
        {:noreply, track_typing(socket, :thread_typing_users, user_id, name)}

      true ->
        {:noreply, socket}
    end
  end

  # A TTL fired — drop the typer only if this is their latest arm (token match); a
  # superseded timer that fired after a re-arm is ignored (#94 review). `field` routes
  # to the room (:typing_users) or the open thread (:thread_typing_users, #103) map.
  def handle_info({:typing_expired, field, user_id, token}, socket) do
    case socket.assigns[field] do
      %{^user_id => %{token: ^token}} -> {:noreply, drop_typing(socket, field, user_id)}
      _ -> {:noreply, socket}
    end
  end

  # A user changed their profile (name/avatar). Identity is rendered wherever a
  # person appears, so refresh our own scope, the sidebar, an open profile card,
  # and the selected conversation's members — without a reload.
  def handle_info({:user_updated, user}, socket) do
    scope = socket.assigns.current_scope

    socket =
      if user.id == scope.user.id do
        assign(socket, current_scope: %{scope | user: user})
      else
        socket
      end

    socket =
      if socket.assigns.profile && socket.assigns.profile.id == user.id do
        assign(socket, profile: user)
      else
        socket
      end

    {:noreply, socket |> refresh_sidebar() |> refresh_selected_for(user)}
  end

  # Swallow any unexpected message (a stray PubSub broadcast, a late async reply)
  # instead of crashing the LiveView on a FunctionClauseError.
  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <div class="ed-root h-screen flex overflow-hidden">
      <%!-- Below the header so it never covers the header buttons; the wrapper
            ignores pointer events so only the toast itself is interactive. --%>
      <div class="fixed top-20 left-1/2 -translate-x-1/2 z-40 w-full max-w-sm px-4 pointer-events-none">
        <.ed_flash flash={@flash} />
      </div>

      <%!-- Discord-style shell: the messenger is the rail's top-left item. On
            mobile the rail hides with the sidebar while a chat is open. --%>
      <.rail
        channels={@channels}
        active={(@channel && @channel.id) || :messenger}
        class={@selected && "hidden md:flex"}
      />

      <aside
        :if={@channel}
        class={[
          "flex-1 min-w-0 md:flex-none md:w-80 border-r flex flex-col",
          @selected && "hidden md:flex"
        ]}
        style="border-color: var(--ed-border);"
      >
        <header
          class="flex items-center justify-between gap-2 px-4 h-14 border-b"
          style="border-color: var(--ed-border);"
        >
          <div class="min-w-0">
            <div class="font-semibold truncate">{@channel.name}</div>
            <div
              :if={@channel.about}
              class="truncate"
              style="font-size:0.6875rem; color: var(--ed-muted);"
            >
              {@channel.about}
            </div>
          </div>
          <%!-- click-away on the wrapper (the opening click is inside it);
                inline display, not [hidden] — Tailwind preflight makes the
                latter !important and JS.toggle couldn't override it. --%>
          <div
            class="relative shrink-0"
            phx-click-away={JS.hide(to: "#channel-menu")}
            phx-window-keydown={JS.hide(to: "#channel-menu")}
            phx-key="escape"
          >
            <button
              type="button"
              class="ed-btn--icon"
              phx-click={JS.toggle(to: "#channel-menu")}
              aria-haspopup="menu"
              aria-label={gettext("Channel menu")}
            >
              <.icon name="hero-ellipsis-horizontal-mini" class="size-5" />
            </button>
            <div
              id="channel-menu"
              class="ed-menu ed-menu--anchored"
              role="menu"
              style="display: none;"
            >
              <button
                type="button"
                class="ed-menu__item"
                role="menuitem"
                phx-click={JS.hide(to: "#channel-menu") |> JS.push("open_channel_members")}
              >
                <.icon name="hero-users-micro" class="size-4" /> {gettext("Members")}
              </button>
              <button
                :if={@channel.role in ~w(owner admin)}
                type="button"
                class="ed-menu__item"
                role="menuitem"
                phx-click={JS.hide(to: "#channel-menu") |> JS.push("open_add_members")}
              >
                <.icon name="hero-user-plus-micro" class="size-4" /> {gettext("Add members")}
              </button>
              <button
                :if={@channel.role in ~w(owner admin)}
                type="button"
                class="ed-menu__item"
                role="menuitem"
                phx-click={JS.hide(to: "#channel-menu") |> JS.push("open_invites")}
              >
                <.icon name="hero-link-micro" class="size-4" /> {gettext("Invite link")}
              </button>
              <button
                :if={@channel.role in ~w(owner admin)}
                type="button"
                class="ed-menu__item"
                role="menuitem"
                phx-click={JS.hide(to: "#channel-menu") |> JS.push("open_channel_edit")}
              >
                <.icon name="hero-pencil-micro" class="size-4" /> {gettext("Edit channel")}
              </button>
              <button
                :if={@channel.role in ~w(owner admin)}
                type="button"
                class="ed-menu__item"
                role="menuitem"
                phx-click={JS.hide(to: "#channel-menu") |> JS.push("open_new_room")}
              >
                <.icon name="hero-plus-micro" class="size-4" /> {gettext("New room")}
              </button>
              <div class="ed-menu__sep"></div>
              <button
                type="button"
                class="ed-menu__item ed-menu__item--danger"
                role="menuitem"
                phx-click="leave_channel"
                data-confirm={gettext("Leave this channel?")}
              >
                <.icon name="hero-arrow-right-start-on-rectangle-micro" class="size-4" /> {gettext(
                  "Leave channel"
                )}
              </button>
              <button
                :if={@channel.role == "owner"}
                type="button"
                class="ed-menu__item ed-menu__item--danger"
                role="menuitem"
                phx-click="delete_channel"
                data-confirm={gettext("Delete this channel for everyone? This cannot be undone.")}
              >
                <.icon name="hero-trash-micro" class="size-4" /> {gettext("Delete channel")}
              </button>
            </div>
          </div>
        </header>

        <%!-- Channel-wide search (#43): rooms by name + message bodies across
              the rooms you're in. Results replace the list while typing. --%>
        <form class="ed-search" phx-change="channel_search" phx-submit="channel_search">
          <.icon name="hero-magnifying-glass-micro" class="size-4 shrink-0" />
          <input
            type="search"
            name="q"
            value={@channel_search}
            placeholder={gettext("Search channel")}
            autocomplete="off"
            class="ed-search__input"
            phx-debounce="200"
            aria-label={gettext("Search this channel")}
          />
          <button
            :if={@channel_search != ""}
            type="button"
            class="ed-btn--icon"
            phx-click="clear_channel_search"
            aria-label={gettext("Clear search")}
          >
            <.icon name="hero-x-mark-micro" class="size-4" />
          </button>
        </form>

        <%!-- Gate on the TRIMMED query (matching the handler's "blank means
              not searching") — a lone space must not hijack the rooms list. --%>
        <div :if={String.trim(@channel_search) != ""} class="flex-1 overflow-y-auto p-2">
          <.channel_search_results
            results={@channel_results || []}
            rooms={@rooms}
            query={@channel_search}
            channel={@channel}
          />
        </div>

        <div
          :if={String.trim(@channel_search) == ""}
          id="rooms-list"
          class="flex-1 overflow-y-auto p-2 space-y-0.5"
          phx-hook=".RoomSortable"
          data-admin={to_string(@channel.role in ~w(owner admin))}
        >
          <%!-- Favorites float on top (per-user); the header appears only when
                any exist. list_rooms already orders favorites-first. --%>
          <p :if={Enum.any?(@rooms, & &1.favorite)} class="ed-rooms__group">
            {gettext("Favorites")}
          </p>
          <.room_item
            :for={room <- Enum.filter(@rooms, & &1.favorite)}
            id={"room-#{room.id}"}
            room={room}
            channel={@channel}
            active={@selected && @selected.id == room.id}
            admin={@channel.role in ~w(owner admin)}
          />
          <p :if={Enum.any?(@rooms, & &1.favorite)} class="ed-rooms__group">
            {gettext("Rooms")}
          </p>
          <.room_item
            :for={room <- Enum.reject(@rooms, & &1.favorite)}
            id={"room-#{room.id}"}
            room={room}
            channel={@channel}
            active={@selected && @selected.id == room.id}
            admin={@channel.role in ~w(owner admin)}
          />
          <button
            :if={@channel.role in ~w(owner admin)}
            type="button"
            class="ed-convo ed-room ed-room--new"
            phx-click="open_new_room"
          >
            <span class="ed-room__hash"><.icon name="hero-plus-micro" class="size-4" /></span>
            <span class="ed-convo__name">{gettext("New room")}</span>
          </button>
          <p
            :if={@rooms == [] and @channel.role not in ~w(owner admin)}
            class="text-center py-8"
            style="color: var(--ed-muted); font-size:0.875rem;"
          >
            {gettext("No rooms yet.")}
          </p>
        </div>
      </aside>

      <aside
        :if={is_nil(@channel)}
        class={[
          "flex-1 min-w-0 md:flex-none md:w-80 border-r flex flex-col",
          @selected && "hidden md:flex"
        ]}
        style="border-color: var(--ed-border);"
      >
        <header
          class="flex items-center justify-between gap-2 px-4 h-14 border-b"
          style="border-color: var(--ed-border);"
        >
          <span class="font-semibold tracking-tight">{gettext("Chats")}</span>
          <button
            class="ed-btn--icon"
            phx-click="toggle_new"
            aria-label={gettext("New conversation")}
          >
            <.icon name="hero-pencil-square-mini" class="size-5" />
          </button>
        </header>

        <form
          id="sidebar-search"
          class="ed-search"
          phx-change="search"
          phx-submit="search"
          phx-hook=".SearchBox"
          role="search"
        >
          <.icon name="hero-magnifying-glass-micro" class="size-4 shrink-0" />
          <input
            type="search"
            name="q"
            value={@search}
            placeholder={gettext("Search")}
            class="ed-search__input"
            phx-debounce="250"
            autocomplete="off"
            aria-label={gettext("Search chats and messages")}
          />
          <button
            :if={@search != ""}
            type="button"
            class="ed-btn--icon"
            phx-click="clear_search"
            aria-label={gettext("Clear search")}
          >
            <.icon name="hero-x-mark-micro" class="size-4" />
          </button>
        </form>

        <nav
          :if={@folders != [] and @search == ""}
          id="folder-tabs"
          class="ed-folders"
          aria-label={gettext("Chat folders")}
          phx-hook=".FolderTabs"
        >
          <%!-- The selected-tab oval; the .FolderTabs hook slides it under the
                active tab so switching folders glides instead of teleporting. --%>
          <span class="ed-folder-indicator" data-indicator aria-hidden="true"></span>
          <%= for tab <- @folder_tabs do %>
            <button
              :if={tab == :all}
              type="button"
              class={["ed-folder-tab", @folder_id == nil && "ed-folder-tab--active"]}
              phx-click="select_folder"
              phx-value-id=""
              aria-pressed={to_string(@folder_id == nil)}
            >
              {gettext("All Chats")}
            </button>
            <span
              :if={tab != :all}
              id={"folder-tab-#{tab.id}"}
              class="ed-folder-tab-wrap"
              phx-hook=".ContextMenu"
            >
              <button
                type="button"
                class={["ed-folder-tab", @folder_id == tab.id && "ed-folder-tab--active"]}
                phx-click="select_folder"
                phx-value-id={tab.id}
                aria-pressed={to_string(@folder_id == tab.id)}
                aria-haspopup="menu"
              >
                <span :if={tab.muted_at} class="ed-folder-tab__muted">
                  <.icon name="hero-bell-slash-micro" class="size-3.5" />
                  <span class="sr-only">{gettext("Muted")}</span>
                </span>
                {tab.name}
                <span :if={tab.unread_count > 0} class="ed-folder-tab__badge">
                  {tab.unread_count}
                </span>
              </button>
              <div class="ed-menu" id={"folder-menu-#{tab.id}"} data-menu role="menu" hidden>
                <button
                  type="button"
                  class="ed-menu__item"
                  role="menuitem"
                  phx-click="toggle_folder_mute"
                  phx-value-id={tab.id}
                >
                  <.icon
                    name={if tab.muted_at, do: "hero-bell-micro", else: "hero-bell-slash-micro"}
                    class="size-4"
                  />
                  {if tab.muted_at, do: gettext("Unmute folder"), else: gettext("Mute folder")}
                </button>
              </div>
            </span>
          <% end %>
        </nav>

        <%!-- The stream container is only hidden (not removed) while searching,
              so its client-side items survive and updates keep applying. --%>
        <div class={["flex-1 overflow-y-auto p-2 relative", @search != "" && "hidden"]}>
          <div id="conversations" phx-update="stream" class="space-y-0.5">
            <.conversation_item
              :for={{dom_id, conversation} <- @streams.conversations}
              id={dom_id}
              conversation={conversation}
              user={@current_scope.user}
              online_ids={@online_ids}
              active={@selected && @selected.id == conversation.id}
            />
          </div>
          <%!-- Shown via CSS only when the stream rendered no rows — no server
                round-trip. Inside a folder it means "nothing filed here", not
                "you have no chats", so the copy and CTA differ. --%>
          <div class="ed-convo-empty">
            <span style="color: var(--ed-muted);">
              <.icon name="hero-chat-bubble-left-right" class="size-7" />
            </span>
            <%= if @folder_id do %>
              <p style="font-weight:600;">{gettext("No chats in this folder")}</p>
              <p style="color: var(--ed-muted); font-size:0.875rem;">
                {gettext("Right-click a chat to move it here.")}
              </p>
            <% else %>
              <p style="font-weight:600;">{gettext("No chats yet")}</p>
              <button class="ed-btn ed-btn--primary" phx-click="toggle_new">
                <.icon name="hero-pencil-square-micro" class="size-4" /> {gettext("New conversation")}
              </button>
            <% end %>
          </div>
        </div>
        <div :if={@search != ""} class="flex-1 overflow-y-auto p-2">
          <p
            :if={is_nil(@search_results)}
            class="text-center py-8"
            style="color: var(--ed-muted); font-size:0.875rem;"
          >
            {gettext("Type at least %{count} characters to search.",
              count: Chat.search_min_chars()
            )}
          </p>
          <.search_results
            :if={@search_results}
            results={@search_results}
            query={@search}
            user={@current_scope.user}
            online_ids={@online_ids}
          />
        </div>
      </aside>

      <main
        class={
          [
            "flex-1 flex flex-col min-w-0",
            # Hidden on mobile when no room is open — UNLESS a private-room knock
            # window is pending (it lives in here; without this it'd be invisible on
            # mobile, #91). selected is nil during a knock, so guard on knock_room.
            !@selected && is_nil(@knock_room) && "hidden md:flex"
          ]
        }
        style="background: var(--ed-bg);"
      >
        <%= if @selected do %>
          <header
            class="flex items-center gap-3 px-4 h-14 border-b shrink-0"
            style="border-color: var(--ed-border);"
          >
            <.link
              navigate={if @channel, do: ~p"/channels/#{@channel.id}", else: ~p"/app"}
              class="ed-btn--icon md:hidden"
              aria-label={gettext("Back")}
            >
              <.icon name="hero-arrow-left-mini" class="size-5" />
            </.link>
            <%!-- A room header: name + channel, no profile/peer affordances. --%>
            <div :if={@selected.channel_id} class="flex items-center gap-2 min-w-0 flex-1">
              <.room_glyph room={@selected} class="ed-room__hash--lg" />
              <div class="min-w-0">
                <div class="font-semibold truncate" style="font-size:0.9375rem;">
                  {@selected.name}
                </div>
                <div :if={@channel} style="font-size:0.6875rem; color: var(--ed-muted);">
                  {@channel.name}
                </div>
              </div>
            </div>
            <%!-- Threads list (#57): the room's followed threads + an unread badge. --%>
            <button
              :if={@selected.channel_id}
              type="button"
              class="ed-btn--icon shrink-0 relative"
              phx-click="open_threads"
              title={gettext("Threads")}
              aria-label={
                if unread_thread_count(@thread_unreads) > 0,
                  do:
                    gettext("Threads, %{count} unread",
                      count: unread_thread_count(@thread_unreads)
                    ),
                  else: gettext("Threads")
              }
              aria-expanded={to_string(@thread_list_open)}
            >
              <.icon name="hero-chat-bubble-left-right-mini" class="size-5" />
              <span :if={unread_thread_count(@thread_unreads) > 0} class="ed-thread-badge">
                {unread_thread_count(@thread_unreads)}
              </span>
            </button>
            <button
              :if={@selected.channel_id}
              type="button"
              class="ed-btn--icon shrink-0"
              phx-click="toggle_room_search"
              title={gettext("Search in room")}
              aria-label={gettext("Search in room")}
              aria-expanded={to_string(@room_search_open)}
            >
              <.icon name="hero-magnifying-glass-mini" class="size-5" />
            </button>
            <button
              :if={is_nil(@selected.channel_id)}
              type="button"
              class="flex items-center gap-3 min-w-0 flex-1 text-left -ml-1.5 px-1.5 py-1 rounded-[var(--ed-radius)] transition-colors hover:bg-[var(--ed-surface)]"
              data-profile-trigger
              phx-click={if @selected.is_group, do: "show_members", else: "show_profile"}
              phx-value-id={peer_id(@selected, @current_scope.user)}
              aria-label={gettext("View profile")}
            >
              <.avatar
                name={title(@selected, @current_scope.user)}
                src={avatar_src(peer(@selected, @current_scope.user))}
                online={online?(@selected, @current_scope.user, @online_ids)}
                size={:sm}
              />
              <div class="min-w-0">
                <div class="font-semibold truncate" style="font-size:0.9375rem;">
                  {title(@selected, @current_scope.user)}
                </div>
                <div
                  :if={not @selected.is_group}
                  style={"font-size:0.6875rem; color: var(#{if online?(@selected, @current_scope.user, @online_ids), do: "--ed-online", else: "--ed-muted"});"}
                >
                  {if online?(@selected, @current_scope.user, @online_ids),
                    do: gettext("online"),
                    else: gettext("offline")}
                </div>
                <div
                  :if={@selected.is_group}
                  style="font-size:0.6875rem; color: var(--ed-muted);"
                >
                  {ngettext("%{count} member", "%{count} members", member_count(@selected))}
                </div>
              </div>
            </button>
          </header>

          <%!-- In-room search (#43): a bar under the header; results overlay
                the top of the message area, each result is a permalink. --%>
          <div :if={@room_search_open and @selected.channel_id} class="relative shrink-0">
            <form
              class="ed-search"
              style="margin-bottom: 0;"
              phx-change="room_search"
              phx-submit="room_search"
            >
              <.icon name="hero-magnifying-glass-micro" class="size-4 shrink-0" />
              <input
                type="search"
                name="q"
                value={@room_search}
                placeholder={gettext("Search in %{room}", room: @selected.name)}
                autocomplete="off"
                class="ed-search__input"
                phx-debounce="200"
                phx-mounted={JS.focus()}
                aria-label={gettext("Search in room")}
              />
              <button
                type="button"
                class="ed-btn--icon"
                phx-click="toggle_room_search"
                aria-label={gettext("Close search")}
              >
                <.icon name="hero-x-mark-micro" class="size-4" />
              </button>
            </form>
            <div :if={String.trim(@room_search) != ""} class="ed-room-search__panel">
              <p
                :if={(@room_results || []) == []}
                class="text-center py-6"
                style="color: var(--ed-muted); font-size:0.875rem;"
              >
                {gettext("No results for “%{query}”", query: String.trim(@room_search))}
              </p>
              <.link
                :for={message <- @room_results || []}
                patch={~p"/channels/#{@selected.channel_id}/r/#{@selected.id}/m/#{message.id}"}
                class="ed-convo"
              >
                <span class="ed-convo__body">
                  <span class="ed-convo__top">
                    <span class="ed-convo__name">
                      {(message.sender && message.sender.display_name) ||
                        gettext("Deleted account")}
                    </span>
                    <.local_time at={message.inserted_at} class="ed-convo__time" />
                  </span>
                  <span class="ed-convo__preview">
                    <.highlighted text={snippet(message.body, @room_search)} query={@room_search} />
                  </span>
                </span>
              </.link>
            </div>
          </div>

          <%!-- Localized lightbox button labels (#95 review): gettext isn't reachable
                inside the colocated .Lightbox hook, so the hook reads these. --%>
          <div
            class="flex-1 overflow-y-auto overscroll-x-contain p-4"
            id="message-scroll"
            phx-hook=".ScrollBottom"
            data-conversation-id={@selected.id}
            data-has-more={to_string(@has_more)}
            data-lb-close={gettext("Close")}
            data-lb-prev={gettext("Previous")}
            data-lb-next={gettext("Next")}
          >
            <%!-- Floating day chip (#83): server-rendered so a re-render never drops it;
                  the .DateRail hook sets its label to the topmost visible day + toggles
                  .is-visible while scrolling. --%>
            <div id="date-chip" class="ed-date-chip" aria-hidden="true"></div>
            <%!-- Older messages auto-load when you scroll near the top (#113); the
                  ScrollBottom hook preserves the scroll position across the prepend.
                  This spinner only comes into view at the very top — i.e. exactly
                  when a page is loading. --%>
            <div
              :if={@has_more}
              class="flex justify-center py-2"
              style="color: var(--ed-muted);"
              aria-hidden="true"
            >
              <.icon name="hero-arrow-path" class="size-5 motion-safe:animate-spin" />
            </div>
            <%!-- Date separators + sticky day chip (#83): the .DateRail hook reconciles
                  a centered chip before each day-change row (client-side, in the viewer's
                  local TZ, robust to streamed inserts + "load older"). Labels via
                  Intl(locale) + gettext Today/Yesterday — gettext is unreachable in the
                  hook, so they ride as data-*. --%>
            <div
              class={["flex flex-col", (@selected.channel_id && "ed-flat-list") || "gap-2"]}
              id="messages"
              phx-update="stream"
              phx-hook=".DateRail"
              data-locale={Gettext.get_locale()}
              data-today={gettext("Today")}
              data-yesterday={gettext("Yesterday")}
            >
              <%= for {dom_id, message} <- @streams.messages do %>
                <%= if @selected.channel_id do %>
                  <.flat_message
                    id={dom_id}
                    message={message}
                    conversation_id={@selected.id}
                    mine={message.sender_id == @current_scope.user.id}
                    me={@current_scope.user.id}
                    quick={@my_quick}
                    participants={Map.get(@thread_participants, message.id, [])}
                    thread_unread={Map.get(@thread_unreads, message.id, 0)}
                    admin={@channel && @channel.role in ~w(owner admin)}
                  />
                <% else %>
                  <.message_bubble
                    id={dom_id}
                    message={message}
                    conversation_id={@selected.id}
                    mine={message.sender_id == @current_scope.user.id}
                    me={@current_scope.user.id}
                    quick={@my_quick}
                    group={@selected.is_group}
                    read={read?(message, @other_read_at)}
                  />
                <% end %>
              <% end %>
            </div>
            <%!-- Optimistic, not-yet-acked sends live here (JS-managed; LiveView leaves it alone). --%>
            <div class="flex flex-col gap-2 mt-2" id="pending-messages" phx-update="ignore"></div>
          </div>

          <%!-- Shared full-emoji grid (#72): ONE popover for the page, opened by a
                message menu's "more" chevron, instead of a 39-button grid hidden in
                every message. Positioned + targeted by the .ReactionGrid hook. --%>
          <div
            id="reaction-grid"
            class="ed-react-grid"
            phx-hook=".ReactionGrid"
            role="menu"
            aria-label={gettext("Add reaction")}
            hidden
          >
            <button
              :for={e <- reaction_set()}
              type="button"
              class="ed-menu__react"
              role="menuitem"
              data-emoji={e}
            >
              {e}
            </button>
          </div>

          <%!-- Typing indicator (#11): above the MAIN composer for the open conversation
                (DMs + rooms); each typer auto-expires via its TTL. Thread replies have
                their own indicator in the thread panel (#103). --%>
          <.typing_row typers={@typing_users} />

          <.form
            for={@composer}
            id="composer"
            phx-hook=".SendQueue"
            data-conversation-id={@selected.id}
            data-layout={if @selected.channel_id, do: "flat", else: "bubble"}
            data-is-group={to_string(@selected.is_group)}
            data-sender-id={@current_scope.user.id}
            data-sender-name={@current_scope.user.display_name}
            data-max-body={Chat.Message.max_body()}
            data-sending-media={to_string(@sending_media)}
            phx-submit="send"
            phx-change="composer_changed"
            class={[
              "flex flex-col shrink-0",
              (@uploads.attachment.entries == [] or @sending_media) && "gap-2 p-3 border-t"
            ]}
            style="border-color: var(--ed-border);"
          >
            <%!-- Quote-reply tray (#71): shows the message being replied to. The
                  hidden input rides the send (form + hook paths); data-reply-active
                  tells the SendQueue hook to defer to the server (no optimistic). --%>
            <div :if={@reply_to} class="ed-reply-bar" data-reply-active>
              <span class="ed-reply-bar__accent" aria-hidden="true"></span>
              <div class="ed-reply-bar__body">
                <span class="ed-reply-bar__name">{reply_author(@reply_to)}</span>
                <span class="ed-reply-bar__text">{reply_snippet(@reply_to)}</span>
              </div>
              <input type="hidden" name="message[reply_to_id]" value={@reply_to.id} />
              <button
                type="button"
                class="ed-btn--icon shrink-0"
                phx-click="cancel_reply"
                aria-label={gettext("Cancel reply")}
              >
                <.icon name="hero-x-mark-micro" class="size-4" />
              </button>
            </div>
            <%!-- @sending_media closes the preview the instant a media send starts
                  (#95): the normal composer returns (its own live_file_input keeps
                  the in-flight upload alive) while the in-stream node shows progress. --%>
            <%= if @uploads.attachment.entries == [] or @sending_media do %>
              <%!-- Normal composer bar: attach + caption + send. --%>
              <div class="flex items-center gap-2">
                <%!-- While a media send is uploading, gate attach (and paste, in the
                      PasteUpload hook) so sends stay serialized — one in-flight set of
                      entries keeps the progress average exact and the FIFO swap
                      unambiguous (#95). pointer-events only: the live_file_input stays
                      enabled so the in-flight upload it's bound to isn't dropped. --%>
                <label
                  class={[
                    "ed-btn--icon",
                    (@sending_media && "opacity-40 pointer-events-none") || "cursor-pointer"
                  ]}
                  aria-label={gettext("Attach a file")}
                  aria-disabled={@sending_media}
                >
                  <.icon name="hero-paper-clip-micro" class="size-5" />
                  <%!-- sr-only (not hidden) keeps the input focusable / keyboard-reachable. --%>
                  <.live_file_input upload={@uploads.attachment} class="sr-only" />
                </label>
                <input
                  type="text"
                  id="composer-body"
                  name="message[body]"
                  value={@composer[:body].value}
                  class="ed-input"
                  placeholder={gettext("Message")}
                  autocomplete="off"
                  phx-hook=".PasteUpload"
                />
                <%!-- phx-update="ignore": the picker is fully client-managed (its
                      open/closed `hidden` is toggled by the hook, contents are a
                      static emoji set). Without it, the per-keystroke phx-change
                      re-render re-asserts the pop's static `hidden` and snaps the
                      picker shut after one pick — defeating multi-select (#90). --%>
                <div
                  class="ed-emoji"
                  id="emoji-picker"
                  phx-hook=".EmojiPicker"
                  phx-update="ignore"
                >
                  <button
                    type="button"
                    class="ed-btn--icon"
                    data-emoji-toggle
                    aria-label={gettext("Emoji")}
                    aria-expanded="false"
                  >
                    <.icon name="hero-face-smile-micro" class="size-5" />
                  </button>
                  <div class="ed-emoji__pop" data-emoji-pop hidden role="menu">
                    <button
                      :for={e <- emoji_set()}
                      type="button"
                      class="ed-emoji__item"
                      data-emoji={e}
                      aria-label={e}
                    >
                      {e}
                    </button>
                  </div>
                </div>
                <button
                  class="ed-btn ed-btn--primary shrink-0"
                  style="width:2.5rem; padding:0; border-radius:var(--ed-radius-full);"
                  type="submit"
                  aria-label={gettext("Send")}
                >
                  <.icon name="hero-paper-airplane-micro" class="size-4" />
                </button>
              </div>
            <% else %>
              <%!-- Attachment preview modal (#58): a Telegram-style overlay with a
                    media grid, the caption + send inside it. data-upload-preview
                    tells the SendQueue hook to defer to the normal phx-submit. --%>
              <.compose_overlay upload={@uploads.attachment} form={@composer} />
            <% end %>
          </.form>
        <% else %>
          <div class="flex-1 grid place-items-center text-center p-8">
            <%!-- Knock window: a private room reached by link that you're not in. --%>
            <div :if={@knock_room} class="space-y-3 max-w-sm">
              <span class="ed-room__hash mx-auto" style="font-size:1.75rem;">
                <.icon name="hero-lock-closed" class="size-8" />
              </span>
              <p style="font-weight:600;">{@knock_room.name}</p>
              <p style="color: var(--ed-muted); font-size:0.875rem;">
                {gettext("This room is private. Request access, or wait for an admin to add you.")}
              </p>
              <button
                :if={!@knock_pending}
                class="ed-btn ed-btn--primary"
                phx-click="request_join"
              >
                <.icon name="hero-hand-raised-micro" class="size-4" /> {gettext("Request to join")}
              </button>
              <p :if={@knock_pending} style="color: var(--ed-muted); font-size:0.875rem;">
                {gettext("Request sent.")}
              </p>
            </div>
            <div :if={@channel && is_nil(@knock_room)} class="space-y-2 max-w-sm break-words">
              <p style="font-weight:600;">{@channel.name}</p>
              <p :if={@channel.about} style="color: var(--ed-muted); font-size:0.875rem;">
                {@channel.about}
              </p>
              <p style="color: var(--ed-muted); font-size:0.875rem;">
                {gettext("Pick a room to start reading.")}
              </p>
            </div>
            <div :if={is_nil(@channel)} class="space-y-2">
              <p style="font-weight:600;">{gettext("No conversation selected")}</p>
              <p style="color: var(--ed-muted); font-size:0.875rem;">
                {gettext("Pick a chat or start a new one.")}
              </p>
              <button class="ed-btn ed-btn--primary" phx-click="toggle_new">
                <.icon name="hero-pencil-square-micro" class="size-4" /> {gettext("New conversation")}
              </button>
            </div>
          </div>
        <% end %>
      </main>

      <%!-- Thread panel (Mattermost RHS): a right column on desktop, a
            full-screen overlay on mobile. --%>
      <aside :if={@thread_root && @selected} class="ed-thread" aria-label={gettext("Thread")}>
        <header
          class="flex items-center gap-2 px-4 h-14 border-b shrink-0"
          style="border-color: var(--ed-border);"
        >
          <button
            type="button"
            class="ed-btn--icon md:hidden"
            phx-click="close_thread"
            aria-label={gettext("Back")}
          >
            <.icon name="hero-arrow-left-mini" class="size-5" />
          </button>
          <div class="min-w-0 flex-1">
            <div class="font-semibold" style="font-size:0.9375rem;">{gettext("Thread")}</div>
            <div class="truncate" style="font-size:0.6875rem; color: var(--ed-muted);">
              {(@selected.channel_id && @selected.name) ||
                title(@selected, @current_scope.user)}
            </div>
          </div>
          <%!-- Follow / unfollow this thread (#57): following counts its new
                replies toward your unread badge. --%>
          <button
            type="button"
            class={["ed-btn--icon", @thread_following && "ed-btn--icon--on"]}
            phx-click="toggle_follow_thread"
            title={if @thread_following, do: gettext("Following"), else: gettext("Follow thread")}
            aria-label={
              if @thread_following, do: gettext("Following"), else: gettext("Follow thread")
            }
            aria-pressed={to_string(@thread_following)}
          >
            <.icon
              name={if @thread_following, do: "hero-bell-alert-mini", else: "hero-bell-mini"}
              class="size-5"
            />
          </button>
          <%!-- Jump to the root in the main stream (closes the panel — on mobile
                it's a full-screen overlay covering the message). --%>
          <button
            type="button"
            class="ed-btn--icon"
            phx-click="jump_to_root"
            title={gettext("Go to message")}
            aria-label={gettext("Go to message")}
          >
            <.icon name="hero-arrow-up-right-mini" class="size-5" />
          </button>
          <button
            type="button"
            class="ed-btn--icon hidden md:inline-flex"
            phx-click="close_thread"
            aria-label={gettext("Close")}
          >
            <.icon name="hero-x-mark-mini" class="size-5" />
          </button>
        </header>

        <div
          class="flex-1 overflow-y-auto overscroll-x-contain p-4"
          id="thread-scroll"
          phx-hook=".ScrollBottom"
        >
          <%!-- in_thread: the "N replies" separator right below makes the
                root's own footer pill redundant. --%>
          <.flat_message
            id={"thread-root-#{@thread_root.id}"}
            message={%{@thread_root | compact: false}}
            conversation_id={@selected.id}
            mine={@thread_root.sender_id == @current_scope.user.id}
            me={@current_scope.user.id}
            menu={false}
            in_thread
          />
          <div class="ed-thread__sep">
            {ngettext("%{count} reply", "%{count} replies", @thread_root.reply_count)}
          </div>
          <div class="flex flex-col ed-flat-list" id="thread-replies" phx-update="stream">
            <.flat_message
              :for={{dom_id, reply} <- @streams.thread}
              id={dom_id}
              message={reply}
              conversation_id={@selected.id}
              mine={reply.sender_id == @current_scope.user.id}
              me={@current_scope.user.id}
              quick={@my_quick}
              in_thread
            />
          </div>
        </div>

        <%!-- Thread typing indicator (#103): only peers typing IN THIS thread. --%>
        <.typing_row typers={@thread_typing_users} />

        <.form
          for={@reply_composer}
          id="reply-composer"
          phx-change="reply_changed"
          phx-submit="send_reply"
          class="flex flex-col gap-2 p-3 border-t shrink-0"
          style="border-color: var(--ed-border);"
        >
          <%!-- Quote-reply within the thread (#71). --%>
          <div :if={@thread_reply_to} class="ed-reply-bar">
            <span class="ed-reply-bar__accent" aria-hidden="true"></span>
            <div class="ed-reply-bar__body">
              <span class="ed-reply-bar__name">{reply_author(@thread_reply_to)}</span>
              <span class="ed-reply-bar__text">{reply_snippet(@thread_reply_to)}</span>
            </div>
            <input type="hidden" name="reply[reply_to_id]" value={@thread_reply_to.id} />
            <button
              type="button"
              class="ed-btn--icon shrink-0"
              phx-click="cancel_thread_reply"
              aria-label={gettext("Cancel reply")}
            >
              <.icon name="hero-x-mark-micro" class="size-4" />
            </button>
          </div>
          <div class="flex items-center gap-2">
            <input
              type="text"
              id="reply-body"
              name="reply[body]"
              value={@reply_composer[:body].value}
              class="ed-input flex-1"
              placeholder={gettext("Reply…")}
              aria-label={gettext("Reply")}
              autocomplete="off"
              maxlength="4000"
            />
            <button type="submit" class="ed-btn ed-btn--primary" aria-label={gettext("Send")}>
              <.icon name="hero-paper-airplane-micro" class="size-4" />
            </button>
          </div>
        </.form>
      </aside>

      <%!-- Threads list (#57): the room's followed threads, drill into any one.
            Shares the RHS aside; a single thread (above) takes precedence, so
            closing it falls back here. --%>
      <aside
        :if={@thread_list_open and is_nil(@thread_root) and @selected}
        class="ed-thread"
        aria-label={gettext("Threads")}
      >
        <header
          class="flex items-center gap-2 px-4 h-14 border-b shrink-0"
          style="border-color: var(--ed-border);"
        >
          <button
            type="button"
            class="ed-btn--icon md:hidden"
            phx-click="close_threads"
            aria-label={gettext("Back")}
          >
            <.icon name="hero-arrow-left-mini" class="size-5" />
          </button>
          <div class="min-w-0 flex-1">
            <div class="font-semibold" style="font-size:0.9375rem;">{gettext("Threads")}</div>
            <div class="truncate" style="font-size:0.6875rem; color: var(--ed-muted);">
              {@selected.name}
            </div>
          </div>
          <button
            type="button"
            class="ed-btn--icon hidden md:inline-flex"
            phx-click="close_threads"
            aria-label={gettext("Close")}
          >
            <.icon name="hero-x-mark-mini" class="size-5" />
          </button>
        </header>

        <div class="flex-1 overflow-y-auto py-1">
          <button
            :for={{root, unread} <- @thread_list}
            type="button"
            class="ed-thread-row"
            phx-click="open_thread"
            phx-value-id={root.id}
          >
            <.avatar name={reply_author(root)} src={avatar_src(root.sender)} size={:sm} />
            <div class="min-w-0 flex-1">
              <div class="flex items-center gap-2">
                <span class="ed-thread-row__name">{reply_author(root)}</span>
                <span :if={root.last_reply_at} class="ed-thread-row__time">
                  <.local_time at={root.last_reply_at} />
                </span>
              </div>
              <div class="ed-thread-row__preview">{reply_snippet(root)}</div>
            </div>
            <span :if={unread > 0} class="ed-thread-badge ed-thread-badge--inline">{unread}</span>
          </button>
          <div :if={@thread_list == []} class="ed-thread-empty">
            {gettext("No followed threads yet. Reply to one to follow it.")}
          </div>
        </div>
      </aside>

      <.new_conversation_modal :if={@show_new} people={@people} />
      <.members_modal
        :if={@show_members && @selected}
        conversation={@selected}
        user={@current_scope.user}
        online_ids={@online_ids}
      />
      <.profile_popover
        :if={@profile}
        user={@profile}
        online={MapSet.member?(@online_ids, @profile.id)}
        self={@profile.id == @current_scope.user.id}
      />
      <.forward_modal
        :if={@forward_id}
        targets={@forward_targets}
        user={@current_scope.user}
        online_ids={@online_ids}
      />
      <.folder_modal :if={@folder_chat_id} folders={@folders} checked={@folder_checked} />
      <.channel_form_modal
        :if={@show_new_channel}
        id="new-channel"
        title={gettext("New channel")}
        form={@new_channel_form}
        submit="rail_create_channel"
        close="rail_close_new_channel"
        submit_label={gettext("Create channel")}
      />
      <.channel_form_modal
        :if={@show_channel_edit}
        id="edit-channel"
        title={gettext("Edit channel")}
        form={@channel_form}
        submit="save_channel"
        close="close_channel_edit"
        submit_label={gettext("Save")}
        channel={@channel}
        upload={@uploads.channel_avatar}
        change="validate_channel"
      />
      <.room_form_modal
        :if={@room_modal}
        title={if @room_modal == :new, do: gettext("New room"), else: gettext("Room settings")}
        form={@room_form}
        submit_label={if @room_modal == :new, do: gettext("Create room"), else: gettext("Save")}
        show_visibility={room_modal_visibility?(@room_modal, @rooms)}
      />
      <.room_add_modal
        :if={@room_add}
        room={@room_add}
        addable={@room_addable}
        selected={@room_add_selected}
        invite_url={@room_invite_url}
        online_ids={@online_ids}
      />
      <.channel_members_modal
        :if={@members_open && @channel}
        members={@members}
        channel={@channel}
        me={@current_scope.user}
        online_ids={@online_ids}
      />
      <.add_members_modal
        :if={@add_open && @channel}
        addable={@addable}
        selected={@add_selected}
        online_ids={@online_ids}
      />
      <.invites_modal :if={@invites_open && @channel} invites={@invites} new_url={@new_invite_url} />

      <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyUrl">
        // Copies data-url to the clipboard and briefly flips the label to
        // data-copied. Falls back to a hidden textarea on non-secure contexts.
        export default {
          mounted() {
            this.el.addEventListener("click", () => {
              const text = this.el.dataset.url
              const done = () => {
                const old = this.el.textContent
                this.el.textContent = this.el.dataset.copied
                setTimeout(() => (this.el.textContent = old), 1500)
              }
              if (navigator.clipboard && navigator.clipboard.writeText) {
                navigator.clipboard.writeText(text).then(done).catch(() => this.legacy(text, done))
              } else {
                this.legacy(text, done)
              }
            })
          },
          legacy(text, done) {
            const ta = document.createElement("textarea")
            ta.value = text
            ta.style.position = "fixed"
            ta.style.opacity = "0"
            document.body.appendChild(ta)
            ta.focus()
            ta.select()
            try { if (document.execCommand("copy")) done() } finally { ta.remove() }
          }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".SearchBox">
        // Keeps the search input in sync with server-side clears: morphdom won't
        // patch a focused input's value, so the server pushes "clear-search" and
        // we empty it here. Also forwards the native type=search Escape-clear
        // (which fires "search", not "input") to the server.
        export default {
          mounted() {
            this.input = this.el.querySelector("input[type=search]")
            this.handleEvent("clear-search", () => { this.input.value = "" })
            this.input.addEventListener("search", () => {
              if (this.input.value === "") this.pushEvent("clear_search", {})
            })
          }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".RoomSortable">
        // Admin drag-and-drop room ordering in the channel sidebar (the folder
        // settings .Sortable pattern). Rows are draggable only for admins
        // (draggable attr is server-rendered). The displayed sequence becomes
        // the canonical position order on drop.
        export default {
          mounted() { this.bind() },
          updated() { this.bind() },
          bind() {
            if (this.el.dataset.admin !== "true") return
            this.el.querySelectorAll(".ed-room-wrap[draggable=true]").forEach((item) => {
              if (item._dnd) return
              item._dnd = true
              item.addEventListener("dragstart", (e) => {
                this.dragging = item
                this.startOrder = this.order().join()
                item.classList.add("ed-dragging")
                e.dataTransfer.effectAllowed = "move"
              })
              item.addEventListener("dragend", () => {
                item.classList.remove("ed-dragging")
                this.commit()
              })
            })
            if (this._listBound) return
            this._listBound = true
            this.el.addEventListener("dragover", (e) => {
              e.preventDefault()
              if (!this.dragging) return
              const after = this.afterElement(e.clientY)
              if (after == null) {
                // Below the last row: land right after it — never appendChild,
                // which would park the row below "+ New room".
                const rows = this.el.querySelectorAll(".ed-room-wrap[draggable=true]:not(.ed-dragging)")
                const last = rows[rows.length - 1]
                if (last) last.after(this.dragging)
              } else {
                this.el.insertBefore(this.dragging, after)
              }
            })
          },
          afterElement(y) {
            const items = [...this.el.querySelectorAll(".ed-room-wrap[draggable=true]:not(.ed-dragging)")]
            return items.find((item) => {
              const box = item.getBoundingClientRect()
              return y < box.top + box.height / 2
            }) || null
          },
          commit() {
            this.dragging = null
            const ids = this.order()
            if (ids.join() !== this.startOrder) this.pushEvent("reorder_rooms", { ids })
          },
          order() {
            return [...this.el.querySelectorAll(".ed-room-wrap[draggable=true]")].map((i) => i.dataset.id)
          }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".Popover">
        // Positions the profile card at the clicked avatar/name (window.__edAnchor,
        // recorded in app.js before the round-trip). Below-and-left-aligned to the
        // trigger, clamped to the viewport, flipping above if it would overflow.
        // On a narrow viewport the CSS makes it a bottom sheet — skip positioning.
        export default {
          mounted() {
            this.place()
            // Move focus into the dialog (role=dialog/aria-modal) so a screen
            // reader announces it and Escape is reliable; focus returns to the
            // trigger naturally when the popover closes and the DOM restores.
            this.el.focus()
          },
          // A presence diff can morph the card while it's open; re-place so it
          // never ends up hidden (place() always restores visibility).
          updated() { this.place() },
          place() {
            if (window.innerWidth < 768) return  // CSS bottom sheet
            const w = this.el.offsetWidth, h = this.el.offsetHeight, gap = 8
            const a = window.__edAnchor
            let left, top
            if (a) {
              left = Math.max(gap, Math.min(a.left, window.innerWidth - w - gap))
              top = a.bottom + gap
              if (top + h > window.innerHeight - gap) top = Math.max(gap, a.top - h - gap)
            } else {
              // No recorded anchor (e.g. a trigger missing data-profile-trigger):
              // center it rather than leave the card invisible.
              left = Math.max(gap, (window.innerWidth - w) / 2)
              top = Math.max(gap, (window.innerHeight - h) / 2)
            }
            this.el.style.left = `${left}px`
            this.el.style.top = `${top}px`
            this.el.style.visibility = "visible"
          }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".FolderTabs">
        // Slides the selected-tab oval under the active folder tab. The folder
        // list persists across selection (phx-click, no navigation), so the
        // indicator can transition between positions instead of teleporting.
        export default {
          mounted() {
            this.indicator = this.el.querySelector("[data-indicator]")
            this.place(false)
            // Re-measure after fonts/layout settle and on container resize.
            this.ro = new ResizeObserver(() => this.place(false))
            this.ro.observe(this.el)
          },
          updated() { this.place(true) },
          destroyed() { this.ro && this.ro.disconnect() },
          place(animate) {
            const active = this.el.querySelector(".ed-folder-tab--active")
            if (!active || !this.indicator) return
            // Overlay the active tab's exact box. offset* are relative to the
            // shared offsetParent (.ed-folders), so this stays correct under
            // horizontal scroll (the indicator scrolls with the content).
            this.indicator.style.transition = animate ? "" : "none"
            this.indicator.style.width = `${active.offsetWidth}px`
            this.indicator.style.height = `${active.offsetHeight}px`
            this.indicator.style.transform =
              `translate(${active.offsetLeft}px, ${active.offsetTop}px)`
            this.indicator.style.opacity = "1"
            if (!animate) {
              // Flush so the first real selection animates from the right spot.
              void this.indicator.offsetWidth
              this.indicator.style.transition = ""
            }
          }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollBottom">
        export default {
          mounted() {
            // Remember which conversation we're pinned to; a switch is a patch (no
            // remount), so updated() must re-pin instantly rather than mounted (#109).
            this.convId = this.el.dataset.conversationId
            this.toBottom()
            // Permalink: scroll to and briefly highlight a message, or report it's gone.
            this.handleEvent("focus_message", ({ domId }) => {
              const el = document.getElementById(domId)
              if (!el) { this.pushEvent("message_unavailable"); return }
              el.scrollIntoView({ block: "center", behavior: "smooth" })
              el.classList.add("ed-msg--focus")
              setTimeout(() => el.classList.remove("ed-msg--focus"), 2200)
            })
            // Runs for nodes added AFTER mount only — the initial list is already
            // in the DOM when the observer starts, so it never animates (no
            // page-load choreography). Two jobs:
            //   1. Atomic swap: when MY real row streams in (data-client-id, in
            //      #messages), drop its optimistic twin from #pending in this same
            //      microtask — before paint. The list never holds both, so it can't
            //      grow-then-shrink by a row (the "whole line dips then snaps up"
            //      jerk). Both text AND media rows carry data-client-id now (#95: the
            //      id rides the fire-and-forget media_sending push, not the upload
            //      form), so one precise id-keyed swap covers both — no heuristic.
            //   2. Rise-in for everyone else's messages.
            this.riser = new MutationObserver((muts) => {
              for (const mut of muts) {
                for (const node of mut.addedNodes) {
                  if (node.nodeType !== 1) continue
                  const row = node.matches?.(".ed-msg, .ed-flat") ? node
                    : node.querySelector?.(".ed-msg, .ed-flat")
                  if (!row) continue
                  const inPending = !!row.closest("#pending-messages")
                  if (row.dataset.clientId) {
                    if (!inPending) {
                      const twin = document.getElementById("pending-messages")
                        ?.querySelector(`[data-client-id="${row.dataset.clientId}"]`)
                      if (twin) twin.remove()
                    }
                    continue
                  }
                  // Optimistic nodes already animated themselves in SendQueue;
                  // never re-animate one that's sitting in #pending.
                  if (inPending) continue
                  row.classList.add("ed-msg--enter")
                  setTimeout(() => row.classList.remove("ed-msg--enter"), 200)
                }
              }
            })
            this.riser.observe(this.el, { childList: true, subtree: true })
            // Auto-load older messages on scroll near the top (#113), replacing the
            // "Load older" button. updated() preserves the scroll position across
            // the prepend so the list doesn't jump.
            // Track "at the bottom" on every scroll so the ResizeObserver below can
            // re-pin after a viewport shrink. Start pinned — mount() just scrolled down.
            this.pinned = true
            this.onScroll = () => {
              this.pinned = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 48
              this.maybeLoadOlder()
            }
            this.el.addEventListener("scroll", this.onScroll, { passive: true })
            // The reply bar / typing row live OUTSIDE #message-scroll (in the composer),
            // so their appearing never triggers this hook's updated(). A ResizeObserver
            // catches the viewport shrinking and keeps the last message visible above the
            // composer instead of letting it hide behind the reply bar.
            this.ro = new ResizeObserver(() => {
              if (this.pinned) this.toBottom(false)
            })
            this.ro.observe(this.el)
          },
          maybeLoadOlder() {
            if (this.loadingMore || this.el.dataset.hasMore !== "true") return
            if (this.el.scrollTop > 300) return
            this.loadingMore = true
            this.prevHeight = this.el.scrollHeight
            this.pushEvent("load_more", {})
          },
          beforeUpdate() {
            this.pinned = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 48
          },
          // A new message while pinned: glide the list up to make room so it
          // eases in from the bottom instead of snapping (the "jerk"). Mount
          // stays instant — no page-load scroll choreography.
          updated() {
            // Switched conversation (a patch, so mounted() didn't re-run): jump
            // INSTANTLY to the latest message instead of smooth-scrolling from the
            // previous chat's scroll position — that glide was the #109 bug. Checked
            // FIRST and abandons any in-flight older-load from the previous chat, so
            // its restore math never runs against the new conversation (review).
            if (this.el.dataset.conversationId !== this.convId) {
              this.convId = this.el.dataset.conversationId
              this.loadingMore = false
              this.toBottom(false)
              return
            }
            // An older-page prepend (#113): keep the same content under the viewport
            // by adding the prepended height to scrollTop. Only when rows were
            // actually added — the final empty page removes the spinner instead, so
            // the height SHRINKS; don't yank the viewport up then (review).
            if (this.loadingMore) {
              this.loadingMore = false
              // Restore in a rAF so the prepended height is measured AFTER the DateRail
              // hook (#83) has injected the older days' separators — otherwise their
              // height isn't in `delta` and the viewport jumps by it. rAF runs after all
              // hooks' updated() in this patch, before paint, so there's no flash.
              requestAnimationFrame(() => {
                const delta = this.el.scrollHeight - this.prevHeight
                if (delta > 0) this.el.scrollTop += delta
              })
              return
            }
            if (this.pinned) this.toBottom(true)
          },
          destroyed() {
            this.riser && this.riser.disconnect()
            this.ro && this.ro.disconnect()
            this.onScroll && this.el.removeEventListener("scroll", this.onScroll)
          },
          toBottom(smooth) {
            const motion =
              smooth && !window.matchMedia("(prefers-reduced-motion: reduce)").matches
                ? "smooth"
                : "auto"
            this.el.scrollTo({ top: this.el.scrollHeight, behavior: motion })
          }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ContextMenu">
        // Telegram-style context menu, shared by message bubbles and sidebar chats:
        // open it with a right-click (desktop) or a long-press (touch) anywhere on
        // the host element — no visible trigger. The dropdown is position:fixed at
        // the pointer, clamped to the viewport, so no scroll container can clip it.
        // Copy items (when present) run client-side; the rest dispatch to the server.
        //
        // `active` (module-scoped) is the one menu currently open. Opening another
        // closes it through close() so its document listeners are torn down — never
        // by mutating `.hidden` directly (that would orphan the listeners). The host
        // (this.el) and the menu node both carry stable ids, so their listeners
        // survive a stream re-render; menu visibility/position is re-applied in
        // updated(), which is why the markup needs no phx-update="ignore" and item
        // labels stay free to change (e.g. a future Mute/Unmute toggle).
        let active = null
        export default {
          mounted() {
            this.onDoc = (e) => { if (!this.menu.contains(e.target)) this.close() }
            this.onKey = (e) => this.onKeydown(e)
            // Capture phase so a scroll in ANY ancestor container closes the menu —
            // but NOT the menu's own scrollable emoji grid (#67), which would slam
            // the menu shut the moment you tried to browse the full picker.
            this.onScroll = (e) => { if (!(this.menu && this.menu.contains(e.target))) this.close() }
            this.wire()

            // Desktop: right-click the host. A keyboard context-menu (Shift+F10 /
            // Menu key) reports clientX/Y 0 — fall back to the host's top-left.
            this.el.addEventListener("contextmenu", (e) => {
              e.preventDefault()
              const r = this.el.getBoundingClientRect()
              this.open(e.clientX || r.left + 8, e.clientY || r.top + 8)
            })

            // Touch: long-press opens the menu; a horizontal LEFT-swipe on a
            // message row quote-replies (#71). A move cancels the long-press
            // (it's a scroll/swipe/select).
            let timer, sx, sy, dx, swiping
            const SWIPE = 56 // px of leftward travel past which a swipe quote-replies
            const ENGAGE = 12 // px before a mouse drag counts as a swipe (vs a click)
            const CLAMP = 90 // px the row follows the gesture 1:1 before the elastic tail
            const SETTLE = 200 // ms of wheel silence before a trackpad swipe re-arms
            const reset = () => {
              this.el.style.transition = "transform 0.18s var(--ed-ease)"
              this.el.style.transform = ""
              swiping = false
            }
            // Rubber-band the row to the gesture: follow the finger 1:1 up to CLAMP (a
            // comfortable, Telegram-like drag distance), then a soft exponential elastic
            // tail past it so it never hits a hard wall. The reply trigger (SWIPE) sits
            // well inside the 1:1 region, so it stays precise. `delta` is <= 0 (left).
            const pull = (delta) => {
              if (delta >= -CLAMP) return delta
              const extra = -delta - CLAMP
              return -(CLAMP + 30 * (1 - Math.exp(-extra / 70)))
            }
            // Fire the quote-reply for this row. In the thread panel the row carries
            // reply_in_thread, so a swipe there replies INTO the thread, not the room.
            const fireReply = () => {
              if (!this.el.dataset.messageId) return
              const event = this.el.dataset.replyEvent || "reply"
              this.pushEvent(event, { id: this.el.dataset.messageId })
              const sel = event === "reply_in_thread" ? "#reply-body" : "#composer-body"
              const input = document.querySelector(sel)
              input && input.focus()
            }
            this.el.addEventListener("touchstart", (e) => {
              const t = e.touches[0]; sx = t.clientX; sy = t.clientY; dx = 0; swiping = false
              this.el.style.transition = "none"
              // Mark a recent touch so a touchscreen laptop's synthesized mouse events
              // don't ALSO run the desktop drag path → double reply (#110 review S2).
              this.recentTouch = true
              clearTimeout(this._touchGuard)
              this._touchGuard = setTimeout(() => { this.recentTouch = false }, 700)
              timer = setTimeout(() => { this.open(sx, sy); this.longPressed = true }, 450)
            }, { passive: true })
            const cancel = () => clearTimeout(timer)
            this.el.addEventListener("touchmove", (e) => {
              const t = e.touches[0]
              dx = t.clientX - sx
              const dy = t.clientY - sy
              if (Math.abs(dx) > 10 || Math.abs(dy) > 10) cancel()
              // Drag a message row left with the finger (rubber-banded); reply on release.
              if (this.el.dataset.messageId && dx < -10 && Math.abs(dx) > Math.abs(dy)) {
                swiping = true
                this.el.style.transform = `translateX(${pull(dx)}px)`
              }
            }, { passive: true })
            this.el.addEventListener("touchend", () => {
              cancel()
              if (swiping && dx <= -SWIPE) fireReply()
              if (swiping) reset()
            })
            // Desktop swipe-to-reply (#110) — DM/group BUBBLES only (rooms use flat
            // rows; the thread panel too, so they keep right-click → Reply). Two inputs:
            //   • Mouse: a CLEARLY horizontal left drag (past ENGAGE AND axis-dominant),
            //     so dragging to SELECT TEXT isn't hijacked (#110 review M1).
            //   • Trackpad: a PASSIVE wheel — keeps the list's vertical scroll on the
            //     compositor fast-path (review M3); the row follows the gesture and
            //     replies past SWIPE. overscroll-x-contain on the scroller stops the
            //     browser's back/forward nav, so we never need preventDefault here.
            // The document-level drag listeners + wheel timer are torn down in
            // destroyed() so an interrupted gesture can't leak a detached node (M2).
            if (this.el.classList.contains("ed-bubble")) {
              let msx = 0, msy = 0, mdx = 0, mDrag = false
              this._dragMove = (e) => {
                mdx = e.clientX - msx
                const mdy = e.clientY - msy
                // Engage only past ENGAGE AND when clearly horizontal; else a
                // vertical/diagonal text-selection drag would slide the row + reply.
                if (!mDrag && (mdx > -ENGAGE || Math.abs(mdx) <= Math.abs(mdy))) return
                mDrag = true
                this.el.style.transition = "none"
                this.el.style.transform = `translateX(${pull(mdx)}px)`
                e.preventDefault() // suppress text selection once it IS a swipe
              }
              this._dragUp = () => {
                document.removeEventListener("mousemove", this._dragMove)
                document.removeEventListener("mouseup", this._dragUp)
                if (mDrag && mdx <= -SWIPE) fireReply()
                // A real drag suppresses the click it would otherwise fire (opening a
                // photo). `dragged` is distinct from the touch long-press flag.
                if (mDrag) { reset(); this.dragged = true; setTimeout(() => { this.dragged = false }, 0) }
              }
              this.el.addEventListener("mousedown", (e) => {
                if (e.button !== 0 || this.recentTouch) return
                msx = e.clientX; msy = e.clientY; mdx = 0; mDrag = false
                clearTimeout(this._wheelTimer) // a just-ended wheel settle must not reset mid-drag
                clearTimeout(this._wheelSnap)
                document.addEventListener("mousemove", this._dragMove)
                document.addEventListener("mouseup", this._dragUp)
              })
              // A photo is a natively-draggable <img>: without this a left drag starts
              // the browser's image drag-and-drop and fights the reply swipe.
              this.el.addEventListener("dragstart", (e) => e.preventDefault())
              // Trackpad two-finger swipe. Vertical-dominant wheels fall through so
              // normal scroll is untouched; positive wx = leftward (tracks the OS scroll
              // direction). The row FOLLOWS the swipe rubber-banded, just like the mouse
              // drag — it must not snap back the instant it crosses SWIPE or a quick flick
              // only nudges ~20px. There's no "release" event (the OS keeps sending
              // decaying momentum wheels for ~1s after a flick), so on crossing SWIPE we
              // reply, let it follow a beat longer for feedback, then snap back and ignore
              // the rest of the momentum tail — a BOUNDED follow so the row can't sit
              // frozen until momentum dies. Idle silence (SETTLE) clears the state.
              let wx = 0
              this.el.addEventListener("wheel", (e) => {
                if (Math.abs(e.deltaX) <= Math.abs(e.deltaY)) return
                clearTimeout(this._wheelTimer)
                this._wheelTimer = setTimeout(() => {
                  wx = 0
                  this._wheelFired = false
                  this._wheelDone = false
                  reset()
                }, SETTLE)
                if (this._wheelDone) return // replied + snapped; ignore the momentum tail
                wx = Math.max(0, wx + e.deltaX)
                this.el.style.transition = "none"
                this.el.style.transform = `translateX(${pull(-wx)}px)`
                if (!this._wheelFired && wx >= SWIPE) {
                  this._wheelFired = true
                  fireReply()
                  this._wheelSnap = setTimeout(() => { this._wheelDone = true; reset() }, 180)
                }
              }, { passive: true })
            }
            // Swallow the click/navigation a long-press OR a desktop drag would
            // otherwise fire (a photo opening, or following a sidebar chat link).
            this.el.addEventListener("click", (e) => {
              if (this.longPressed || this.dragged) {
                e.preventDefault()
                e.stopPropagation()
                this.longPressed = false
                this.dragged = false
              }
            }, true)
          },
          // A stream re-render morphs the item; re-bind the (possibly new) menu node
          // and restore the open state the server render doesn't know about.
          updated() {
            this.wire()
            if (active === this) {
              this.menu.hidden = false
              this.position(this.x, this.y)
            }
          },
          destroyed() {
            this.close()
            // Tear down anything an in-flight desktop gesture left on `document` or
            // any pending timer, so an interrupted drag/swipe (the row destroyed by a
            // conversation switch, delete, or pagination mid-gesture) can't leak a
            // detached node via a live listener/closure (#110 review M2/M3).
            if (this._dragMove) document.removeEventListener("mousemove", this._dragMove)
            if (this._dragUp) document.removeEventListener("mouseup", this._dragUp)
            clearTimeout(this._touchGuard)
            clearTimeout(this._wheelTimer)
            clearTimeout(this._wheelSnap)
          },
          // Bind the menu node + its delegated click handler. Idempotent: re-runs on
          // updated() and only attaches the listener to a freshly morphed-in node.
          wire() {
            this.menu = this.el.querySelector("[data-menu]")
            if (this.menu && !this.menu._wired) {
              this.menu._wired = true
              this.menu.addEventListener("click", (e) => this.onItem(e))
            }
            // Optional visible trigger (the flat rows' hover "⋯") — anchors the
            // same menu under the button. Wired here so a stream morph that
            // replaces the node re-attaches the listener.
            const trigger = this.el.querySelector("[data-menu-trigger]")
            if (trigger && !trigger._wired) {
              trigger._wired = true
              trigger.addEventListener("click", (e) => {
                e.preventDefault(); e.stopPropagation()
                // Toggle: a second click on the trigger closes the open menu.
                // stopPropagation above keeps onDoc from firing, so without
                // this branch open() just re-opens (active === this) and the
                // menu never closes from the trigger.
                if (active === this && this.menu && !this.menu.hidden) {
                  this.close()
                  return
                }
                const r = trigger.getBoundingClientRect()
                this.open(r.left, r.bottom + 4)
              })
            }
          },
          onItem(e) {
            // The reaction row's "more" chevron opens the shared full-emoji grid
            // popover (#72) for this message, then closes the menu.
            const expand = e.target.closest("[data-react-expand]")
            if (expand) {
              e.preventDefault()
              // Anchor the grid to the MENU's on-screen box, not the chevron —
              // the chevron is the rightmost item in the reacts row, so on a
              // right-aligned bubble its left edge clamps the grid to the far
              // screen edge. The menu's top-left puts the grid where the menu was.
              const mr = this.menu.getBoundingClientRect()
              window.dispatchEvent(new CustomEvent("ed:open-reaction-grid", {
                detail: {
                  id: this.el.dataset.messageId,
                  mine: expand.dataset.mine || "",
                  x: mr.left,
                  y: mr.top
                }
              }))
              this.close()
              return
            }
            const ct = e.target.closest("[data-copy-text]")
            const cl = e.target.closest("[data-copy-link]")
            if (ct) this.copy(ct.dataset.text, "text")
            else if (cl) this.copy(cl.dataset.link, "link")
            // A reaction (phx-click="react") or forward/delete dispatches to the
            // server; either way the menu closes.
            if (e.target.closest("button")) this.close()
          },
          onKeydown(e) {
            if (e.key === "Escape") { this.close(); this.opener && this.opener.focus() }
            else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
              e.preventDefault()
              const items = [...this.menu.querySelectorAll("[role=menuitem]")]
              if (!items.length) return
              const i = items.indexOf(document.activeElement)
              const n = e.key === "ArrowDown" ? i + 1 : i - 1
              items[(n + items.length) % items.length].focus()
            }
          },
          open(x, y) {
            // Hosts without a menu node (e.g. the thread panel root) no-op.
            if (!this.menu) return
            if (active && active !== this) active.close()
            active = this
            this.x = x; this.y = y
            // Remember a focused trigger (keyboard open) to restore focus on Escape.
            this.opener = this.el.contains(document.activeElement) ? document.activeElement : null
            this.menu.hidden = false
            this.position(x, y)
            const first = this.menu.querySelector("[role=menuitem]")
            first && first.focus()
            // Defer the outside-click listener so the same gesture doesn't close it.
            setTimeout(() => document.addEventListener("click", this.onDoc), 0)
            document.addEventListener("keydown", this.onKey)
            document.addEventListener("scroll", this.onScroll, { capture: true, passive: true })
          },
          close() {
            if (active === this) active = null
            if (this.menu) this.menu.hidden = true
            // removeEventListener is a no-op if not attached — safe to call always.
            document.removeEventListener("click", this.onDoc)
            document.removeEventListener("keydown", this.onKey)
            document.removeEventListener("scroll", this.onScroll, { capture: true })
          },
          position(x, y) {
            const mw = this.menu.offsetWidth || 220
            const mh = this.menu.offsetHeight || 240
            const left = Math.max(8, Math.min(x, window.innerWidth - mw - 8))
            const top = Math.max(8, Math.min(y, window.innerHeight - mh - 8))
            this.menu.style.left = `${left}px`
            this.menu.style.top = `${top}px`
          },
          copy(text, what) {
            const done = () => this.pushEvent("copied", { what })
            if (navigator.clipboard && navigator.clipboard.writeText) {
              navigator.clipboard.writeText(text).then(done).catch(() => this.legacyCopy(text, done))
            } else {
              this.legacyCopy(text, done)
            }
            this.close()
          },
          // Fallback for non-secure contexts (HTTP, old WebViews) where the async
          // Clipboard API is unavailable.
          legacyCopy(text, done) {
            const ta = document.createElement("textarea")
            ta.value = text
            ta.style.position = "fixed"
            ta.style.opacity = "0"
            document.body.appendChild(ta)
            ta.focus()
            ta.select()
            try { if (document.execCommand("copy")) done() } finally { ta.remove() }
          }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ReactionGrid">
        // The shared full-emoji grid popover (#72). One instance for the page; a
        // message menu's "more" chevron fires `ed:open-reaction-grid` with the
        // message id + anchor, we position over it and (on pick) push "react" for
        // that message. Closes on outside-click / Esc / any scroll outside the
        // grid (its own scroll is contained by CSS overscroll-behavior).
        export default {
          mounted() {
            this.onOpen = (e) => this.open(e.detail.id, e.detail.x, e.detail.y, e.detail.mine)
            window.addEventListener("ed:open-reaction-grid", this.onOpen)
            this.el.addEventListener("click", (e) => {
              const btn = e.target.closest("[data-emoji]")
              if (!btn) return
              this.pushEvent("react", { id: this.msgId, emoji: btn.dataset.emoji })
              this.close()
            })
            // Close on any interaction outside the grid: a left-click, OR a
            // right-click (which opens a fresh context menu — the two popovers are
            // mutually exclusive), OR a scroll. Without the contextmenu case the
            // grid would linger under a newly-opened menu.
            this.onDoc = (e) => { if (!this.el.contains(e.target)) this.close() }
            this.onKey = (e) => { if (e.key === "Escape") this.close() }
            this.onScroll = (e) => { if (!this.el.contains(e.target)) this.close() }
          },
          // Destroyed while open (e.g. @selected -> nil on leave/remove, or a
          // server-driven navigate) must drop the document listeners too — else
          // they'd survive on a detached node. close() does exactly that.
          destroyed() {
            window.removeEventListener("ed:open-reaction-grid", this.onOpen)
            this.close()
          },
          open(id, x, y, mine) {
            // Re-entrant: tear down any listeners from a prior open FIRST. If the
            // grid was already open (a new menu opened over it, then its chevron
            // clicked), a surviving onDoc would fire on this very opening click and
            // slam the grid shut — and leave a stale listener that breaks every
            // future open. Clearing first guarantees the opening gesture is clean.
            this.teardown()
            this.msgId = id
            // Mirror the per-message highlight the in-menu grid used to show: mark
            // the viewer's existing reactions (space-joined in the chevron's
            // data-mine) so the full grid still tells you what you've already picked.
            const set = new Set((mine || "").split(" ").filter(Boolean))
            this.el.querySelectorAll("[data-emoji]").forEach((b) => {
              const on = set.has(b.dataset.emoji)
              b.classList.toggle("ed-menu__react--active", on)
              b.setAttribute("aria-pressed", String(on))
            })
            this.el.hidden = false
            const w = this.el.offsetWidth, h = this.el.offsetHeight
            this.el.style.left = Math.max(8, Math.min(x, window.innerWidth - w - 8)) + "px"
            this.el.style.top = Math.max(8, Math.min(y, window.innerHeight - h - 8)) + "px"
            // Move focus into the popover so keyboard users land on it (the menu
            // that opened it has closed, dropping focus to <body>).
            const first = this.el.querySelector("[data-emoji]")
            if (first) first.focus({ preventScroll: true })
            // Defer the outside-interaction listeners so the same gesture that
            // opened the grid doesn't immediately close it.
            setTimeout(() => {
              document.addEventListener("click", this.onDoc)
              document.addEventListener("contextmenu", this.onDoc)
            }, 0)
            document.addEventListener("keydown", this.onKey)
            document.addEventListener("scroll", this.onScroll, { capture: true, passive: true })
          },
          close() {
            this.el.hidden = true
            this.teardown()
          },
          teardown() {
            document.removeEventListener("click", this.onDoc)
            document.removeEventListener("contextmenu", this.onDoc)
            document.removeEventListener("keydown", this.onKey)
            document.removeEventListener("scroll", this.onScroll, { capture: true })
          }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".LocalTime">
        export default {
          mounted() { this.fmt() },
          updated() { this.fmt() },
          fmt() {
            const d = new Date(this.el.getAttribute("datetime"));
            if (!isNaN(d)) this.el.textContent = d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
          }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".DateRail">
        // Date separators + a sticky day chip (#83), grouped in the viewer's LOCAL
        // timezone from each row's data-ts (UTC unix seconds). Client-side so it groups
        // by the local day and survives streamed inserts + "load older" — reconcile()
        // re-derives the inline separators after every stream patch. Labels come from
        // Intl(locale) + the gettext Today/Yesterday passed as data-* (gettext is
        // unreachable in the hook).
        export default {
          mounted() {
            this.scroller = this.el.closest("#message-scroll") || this.el.parentElement
            this.locale = this.el.dataset.locale || undefined
            this.today = this.el.dataset.today || "Today"
            this.yesterday = this.el.dataset.yesterday || "Yesterday"
            // The floating chip is server-rendered (#date-chip) so a re-render can't drop
            // it — we only read/update it here, never inject it.
            this.chip = this.scroller.querySelector("#date-chip")
            this.onScroll = () => {
              if (this._raf) return
              this._raf = requestAnimationFrame(() => { this._raf = null; this.updateChip() })
            }
            this.scroller.addEventListener("scroll", this.onScroll, { passive: true })
            this.reconcile()
            this.scheduleMidnight()
          },
          updated() { this.reconcile() },
          destroyed() {
            this.scroller && this.onScroll && this.scroller.removeEventListener("scroll", this.onScroll)
            this._raf && cancelAnimationFrame(this._raf)
            clearTimeout(this._fade)
            clearTimeout(this._midnight)
          },
          // Re-derive the labels at local midnight so a tab left open across it doesn't
          // keep an old "Today"/"Yesterday" (the day key is unchanged, so force a relabel).
          scheduleMidnight() {
            const now = new Date()
            const next = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1, 0, 0, 5)
            this._midnight = setTimeout(() => {
              this._sig = null
              this.reconcile()
              this.updateChip()
              this.scheduleMidnight()
            }, next - now)
          },
          // Local-day key (browser TZ): a row's day-change boundary + Today/Yesterday.
          dayKeyOf(d) { return d.getFullYear() * 10000 + (d.getMonth() + 1) * 100 + d.getDate() },
          dayLabel(ts) {
            if (!Number.isFinite(ts)) return ""
            const d = new Date(ts * 1000)
            const now = new Date()
            if (this.dayKeyOf(d) === this.dayKeyOf(now)) return this.today
            const y = new Date(now)
            y.setDate(y.getDate() - 1)
            if (this.dayKeyOf(d) === this.dayKeyOf(y)) return this.yesterday
            const opts =
              d.getFullYear() === now.getFullYear()
                ? { day: "numeric", month: "long" }
                : { day: "numeric", month: "long", year: "numeric" }
            return new Intl.DateTimeFormat(this.locale, opts).format(d)
          },
          rows() { return [...this.el.children].filter((c) => c.dataset && c.dataset.ts) },
          // Re-derive the boundary rows (first row of each local day; a non-finite ts is
          // skipped, never crashing Intl). Skip the DOM remove+reinsert when the day
          // structure is unchanged — most patches (a reaction toggle, read tick,
          // thumbnail swap, a same-day message) don't move a boundary, so they no-op.
          reconcile() {
            const desired = []
            let prev = null
            for (const row of this.rows()) {
              const k = this.dayKeyOf(new Date(Number(row.dataset.ts) * 1000))
              if (Number.isFinite(k) && k !== prev) { desired.push(row); prev = k }
            }
            const existing = this.el.querySelectorAll(":scope > .ed-date-sep")
            const sig = desired.map((r) => r.id).join("|")
            // Skip the DOM churn only when the day structure is unchanged AND the
            // separators are still in the DOM — a stream patch (e.g. an append) can drop
            // the injected nodes, so we must re-add them even when the structure matches.
            if (sig === this._sig && existing.length === desired.length) return
            this._sig = sig
            existing.forEach((s) => s.remove())
            for (const row of desired) {
              const sep = document.createElement("div")
              sep.className = "ed-date-sep"
              const span = document.createElement("span")
              span.textContent = this.dayLabel(Number(row.dataset.ts))
              sep.appendChild(span)
              this.el.insertBefore(sep, row)
            }
          },
          // Track the topmost visible row's day in the floating chip; fade when idle. The
          // rows are vertically ordered, so binary-search the first one still in view
          // (O(log n) rect reads) instead of scanning every row each scroll frame.
          updateChip() {
            if (!this.chip) return
            const rows = this.rows()
            if (!rows.length) { this.chip.classList.remove("is-visible"); return }
            const vtop = this.scroller.getBoundingClientRect().top
            // If an inline separator sits in the floating chip's band at the top, let it
            // BE the label and keep the chip hidden — otherwise both render the same pill
            // stacked at a day boundary (the reported duplicate).
            const band = vtop + this.chip.offsetHeight + 6
            for (const sep of this.el.querySelectorAll(":scope > .ed-date-sep")) {
              const r = sep.getBoundingClientRect()
              if (r.bottom > vtop && r.top < band) {
                this.chip.classList.remove("is-visible")
                clearTimeout(this._fade)
                return
              }
            }
            const top = vtop + 4
            let lo = 0, hi = rows.length - 1, cur = rows[rows.length - 1]
            while (lo <= hi) {
              const mid = (lo + hi) >> 1
              if (rows[mid].getBoundingClientRect().bottom > top) { cur = rows[mid]; hi = mid - 1 }
              else lo = mid + 1
            }
            this.chip.textContent = this.dayLabel(Number(cur.dataset.ts))
            this.chip.classList.add("is-visible")
            clearTimeout(this._fade)
            this._fade = setTimeout(() => this.chip.classList.remove("is-visible"), 1400)
          },
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".SendQueue">
        // Optimistic text sends + an in-memory outbound queue. A send is rendered
        // immediately, queued, and (re)sent over the socket; while the socket is
        // down it waits and flushes on reconnect, so a flaky cross-border link
        // doesn't lose or duplicate messages (the server dedups by client_id).
        // Photo sends fall through to the normal LiveView path (they need a live
        // upload). In-memory only: a full page reload clears the queue.
        export default {
          mounted() {
            this.connected = true
            this.convId = this.el.dataset.conversationId
            this.queue = []
            this.input = this.el.querySelector('input[name="message[body]"]')
            this.pending = document.getElementById("pending-messages")
            this.scroller = document.getElementById("message-scroll")
            this.el.addEventListener("submit", (e) => this.onSubmit(e))
            // Compress images client-side BEFORE they upload (#97): smaller transfer
            // on a slow cross-border link + smaller storage. We intercept the file
            // input's own input/change in capture, downscale/re-encode each image,
            // then re-feed the input so LiveView stages the COMPRESSED file (the
            // PasteUpload set-files+dispatch path, which is proven to stage). Paste
            // flows through the same handler, so pasted images compress too.
            this.onPick = (e) => this.compressPicked(e)
            this.el.addEventListener("input", this.onPick, true)
            this.el.addEventListener("change", this.onPick, true)
            // A media send that errored (or consumed no entry) has no real row to
            // swap its optimistic twin, so the server names the exact client_id to
            // drop — else it spins forever and pins its preview data-URLs (#95).
            this.handleEvent("media_failed", ({ id }) => {
              this.dropPending(id)
            })
            // Determinate upload progress for the in-flight media send (#95): the
            // server averages the album's entries and pushes {percent, id}; we drive
            // the ring on that exact optimistic node.
            this.handleEvent("media_progress", ({ id, percent }) => {
              this.setRing(this.pending?.querySelector(`[data-client-id="${id}"]`), percent)
              this.armStall(id)
            })
          },
          disconnected() { this.connected = false },
          reconnected() {
            this.connected = true
            // Re-arm anything that was in-flight when the link dropped; the
            // server dedups by client_id, so re-sending can't duplicate.
            for (const item of this.queue) item.sent = false
            this.flush()
          },
          updated() {
            // Switched conversation: drop the old thread's optimistic UI + queue.
            if (this.el.dataset.conversationId !== this.convId) {
              this.convId = this.el.dataset.conversationId
              this.queue = []
              if (this.pending) this.pending.replaceChildren()
            }
          },
          onSubmit(e) {
            // Media (#95 redesign): mint a client_id, render the local-preview node
            // (tagged with it) + a progress ring, push it fire-and-forget on
            // media_sending (which also closes the overlay), and let the live upload
            // proceed UNTOUCHED — no preventDefault, no gating. The id rides the
            // socket BEFORE the native submit's "send" (same channel → FIFO order),
            // so the server stamps the real message and the existing data-client-id
            // swap drops this exact twin. The OLD two-pass instead held the submit
            // until a pushEvent ack re-fired it; that ack path was the fragile bit
            // that stalled real uploads in prod (the spinner-forever bug).
            const overlay = this.el.querySelector("[data-upload-preview]")
            if (overlay) {
              // A staged entry with a client-side error (e.g. a video over the size
              // cap) won't upload. Don't close the overlay (media_sending) — that
              // would hide the error — and don't fake an optimistic node; keep the
              // error visible so the send isn't a silent no-op (#112: "при отправке
              // видео ничего не происходит" was an oversized clip whose error the
              // overlay-close swallowed).
              if (overlay.querySelector(".ed-attach-err")) {
                e.preventDefault()
                return
              }
              const clientId = this.uuid()
              this.addOptimisticMedia(clientId, overlay)
              this.pushEvent("media_sending", { id: clientId })
              this.armStall(clientId)
              // Close the preview INSTANTLY (#111) instead of waiting for the
              // media_sending round-trip to re-render — on a slow link the overlay
              // lingered ~seconds after Send. The element stays in the DOM (display
              // none) so the in-flight upload bound to its file input isn't dropped;
              // the server render then swaps it for the normal composer.
              overlay.style.display = "none"
              return
            }
            // A quote-reply (#71) also defers to the server path so the reply_to_id
            // rides along and the quote renders at the right height (no optimistic
            // node that would pop taller when the real row streams in).
            if (this.el.querySelector("[data-reply-active]")) return
            // Take over text sends: stop the event reaching LiveView's delegated
            // phx-submit so the message isn't also sent without a client_id.
            e.preventDefault()
            e.stopPropagation()
            const body = (this.input.value || "").trim()
            if (!body) return
            this.input.value = ""
            // Oversized bodies (> the server's codepoint cap) are split into
            // ordered parts and sent as separate messages — Telegram-style —
            // instead of failing the whole send (#68). Each part is a normal
            // queued item (own client_id, optimistic node, dedup, resend).
            for (const part of this.split(body)) {
              const clientId = this.uuid()
              this.addOptimistic(clientId, part)
              this.queue.push({ clientId, body: part, sent: false })
            }
            this.flush()
          },
          // A v4 UUID for the client_id. `crypto.randomUUID` only exists in a
          // secure context (HTTPS or localhost); over plain HTTP by IP it's
          // undefined and would throw, silently killing every text send. Fall back
          // to `crypto.getRandomValues`, which IS available in insecure contexts.
          uuid() {
            if (crypto.randomUUID) return crypto.randomUUID()
            const b = crypto.getRandomValues(new Uint8Array(16))
            b[6] = (b[6] & 0x0f) | 0x40
            b[8] = (b[8] & 0x3f) | 0x80
            const h = [...b].map((x) => x.toString(16).padStart(2, "0")).join("")
            return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`
          },
          // Break a body into <=max-codepoint chunks, preferring the last space
          // before the limit so words aren't cut; a single unbroken run is hard
          // cut. Counts codepoints (spread handles surrogate pairs) to match the
          // server's `count: :codepoints` and never split a multi-byte char.
          split(body) {
            const max = Number(this.el.dataset.maxBody) || 4000
            const cp = [...body]
            if (cp.length <= max) return [body]
            const parts = []
            let rest = cp
            while (rest.length > max) {
              let cut = max
              const window = rest.slice(0, max).join("")
              const space = window.lastIndexOf(" ")
              if (space > 0) cut = [...window.slice(0, space)].length
              parts.push(rest.slice(0, cut).join("").trim())
              rest = rest.slice(cut)
              // Drop a single boundary space so it isn't doubled across parts.
              if (rest[0] === " ") rest = rest.slice(1)
            }
            const tail = rest.join("").trim()
            if (tail) parts.push(tail)
            return parts.filter((p) => p.length > 0)
          },
          flush() {
            if (!this.connected) return
            // Items stay queued until acked; only then are they removed. An
            // in-flight item (sent) isn't re-sent until a reconnect re-arms it.
            for (const item of this.queue) {
              if (item.sent) continue
              item.sent = true
              this.pushEvent("send", { message: { body: item.body, client_id: item.clientId } }, (reply) => {
                this.queue = this.queue.filter((q) => q.clientId !== item.clientId)
                // On success DON'T remove the optimistic node here — the ack
                // races the {:new_message} broadcast, and removing first leaves
                // a frame where the message vanishes (the list dips, then the
                // real row pops in: the "jerk"). The rise-in observer removes it
                // atomically the instant the real row streams in. Only a nack
                // (rejected) needs handling, since no real row will arrive.
                if (reply && reply.nack) this.markFailed(item.clientId)
              })
            }
          },
          addOptimistic(clientId, body) {
            // Match the conversation's layout so the optimistic node doesn't
            // flash as a DM bubble in a room (or vice versa) before the real
            // message arrives. body/name are set via textContent, never
            // interpolated into innerHTML — the template strings are static.
            const row = document.createElement("div")
            row.dataset.clientId = clientId
            row.dataset.body = body
            if (this.el.dataset.layout === "flat") {
              // Mirror the server's compact rule (same author within 5 min):
              // a continuation row drops the avatar/name. Without this the
              // optimistic node always drew the avatar, which then vanished a
              // frame later when the real (compact) row replaced it.
              const myId = this.el.dataset.senderId
              const last = this.lastFlatRow()
              const compact = !!last && last.dataset.senderId === myId &&
                (Date.now() / 1000 - Number(last.dataset.ts || 0)) < 300
              row.className = compact ? "ed-flat ed-flat--compact" : "ed-flat"
              row.style.opacity = "0.55"
              row.dataset.senderId = myId
              row.dataset.ts = Math.floor(Date.now() / 1000)
              const name = this.el.dataset.senderName || ""
              if (compact) {
                row.innerHTML =
                  '<div class="ed-flat__gutter"></div>' +
                  '<div class="ed-flat__main"><div class="break-words ed-flat__body"></div></div>'
              } else {
                row.innerHTML =
                  '<div class="ed-flat__gutter"><span class="ed-avatar ed-avatar--sm"><span></span></span></div>' +
                  '<div class="ed-flat__main"><div class="ed-flat__head">' +
                  '<span class="ed-flat__name"></span></div>' +
                  '<div class="break-words ed-flat__body"></div></div>'
                row.querySelector(".ed-avatar span").textContent =
                  (name.trim().charAt(0) || "?").toUpperCase()
                row.querySelector(".ed-flat__name").textContent = name
              }
              row.querySelector(".ed-flat__body").textContent = body
            } else {
              // Match the real row's classes exactly ("ed-msg flex justify-end"):
              // .ed-msg carries the inter-message spacing, so the optimistic and
              // real rows are the same height and the swap doesn't nudge layout.
              row.className = "ed-msg flex justify-end"
              const bubble = document.createElement("div")
              bubble.className = "ed-bubble ed-bubble--me"
              bubble.style.opacity = "0.55"
              // Mirror the real bubble's body + meta structure so the optimistic
              // node is the SAME height — without the meta line it was shorter,
              // so the real (taller) replacement looked like it grew ("small to
              // large"). A lone "sending" check stands in for the read receipt —
              // but ONLY in 1:1s: group bubbles render no receipt (the real row
              // hides it for groups), so showing one optimistically made the check
              // flash then vanish as the real row swapped in (#89). Match that.
              const isGroup = this.el.dataset.isGroup === "true"
              const check =
                isGroup
                  ? ""
                  : '<span class="inline-flex items-center" style="margin-left:2px;">' +
                    '<span class="hero-check-micro size-3.5"></span></span>'
              bubble.innerHTML =
                '<span class="break-words"></span>' +
                '<span class="ed-bubble__meta"><time></time>' + check + "</span>"
              bubble.querySelector("span.break-words").textContent = body
              bubble.querySelector("time").textContent =
                new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
              row.appendChild(bubble)
            }
            this.pending.appendChild(row)
            // Rise the optimistic node in — this IS the smooth send animation the
            // user sees. The real replacement carries data-client-id, so the
            // observer skips it and it swaps in silently (no second animation).
            row.classList.add("ed-msg--enter")
            setTimeout(() => row.classList.remove("ed-msg--enter"), 200)
            // Glide the list up to reveal the new row (it eases in from the
            // bottom) instead of snapping — no jerk. Instant under reduced motion.
            if (this.scroller) {
              const smooth = !window.matchMedia("(prefers-reduced-motion: reduce)").matches
              this.scroller.scrollTo({
                top: this.scroller.scrollHeight,
                behavior: smooth ? "smooth" : "auto",
              })
            }
          },
          // Optimistic media node (#95): a local preview of the staged photos with a
          // determinate progress ring, tagged with the send's client_id so the riser
          // observer swaps exactly this twin when the real row streams in. Previews
          // are snapshotted to data-URLs because the overlay's object URLs are
          // revoked on consume. A files-only send (no image/video preview) gets NO
          // node — files render as cards with no meaningful local preview, and an
          // empty album box would just flash; their real rows rise in normally.
          addOptimisticMedia(clientId, overlay) {
            const previews = [...overlay.querySelectorAll(".ed-compose__img")]
              .map((img) => this.snapshot(img))
              .filter(Boolean)
            const videos = overlay.querySelectorAll(".ed-compose__video").length
            const n = previews.length + videos
            if (n === 0) return

            // Match the REAL render so the swap doesn't reflow (#95 review): a lone
            // image renders via attachment_view (natural aspect, NOT a square album
            // tile); 2+ use the .ed-album grid. Only a dim + spinner mark it sending.
            let media
            if (n === 1 && previews.length === 1) {
              media = document.createElement("div")
              media.className = "ed-media-sending ed-media-sending--single"
              const img = document.createElement("img")
              img.src = previews[0]
              img.alt = ""
              media.appendChild(img)
            } else {
              const cols = { 1: 1, 2: 2, 3: 3, 4: 2 }[n] || 3
              media = document.createElement("div")
              media.className = "ed-album ed-media-sending" + (cols > 1 ? " ed-album--" + cols : "")
              for (const src of previews) {
                const tile = document.createElement("span")
                tile.className = "ed-album__tile"
                const img = document.createElement("img")
                img.src = src
                img.alt = ""
                tile.appendChild(img)
                media.appendChild(tile)
              }
              for (let i = 0; i < videos; i++) {
                const tile = document.createElement("span")
                tile.className = "ed-album__tile"
                tile.innerHTML = '<span class="ed-album__tile-fill"></span>'
                media.appendChild(tile)
              }
            }
            // Determinate ring (#95): a track + a fill arc the server drives via
            // media_progress. Two SVG circles; the fill's stroke-dashoffset is set
            // in setRing. Rotated -90deg in CSS so it grows from 12 o'clock.
            const ring = document.createElement("span")
            ring.className = "ed-media-sending__ring"
            ring.setAttribute("aria-hidden", "true")
            ring.innerHTML =
              '<svg viewBox="0 0 36 36">' +
              '<circle class="ed-media-sending__ring-track" cx="18" cy="18" r="16"></circle>' +
              '<circle class="ed-media-sending__ring-fill" cx="18" cy="18" r="16"></circle>' +
              "</svg>"
            media.appendChild(ring)

            const row = document.createElement("div")
            row.dataset.clientId = clientId
            if (this.el.dataset.layout === "flat") {
              // Mirror the real flat row incl. the compact rule (#95 review): a
              // continuation (same author within 5 min) drops the avatar + name
              // header, matching the optimistic text node.
              const myId = this.el.dataset.senderId
              const last = this.lastFlatRow()
              const compact =
                !!last &&
                last.dataset.senderId === myId &&
                Date.now() / 1000 - Number(last.dataset.ts || 0) < 300
              row.className = compact ? "ed-flat ed-flat--compact" : "ed-flat"
              row.dataset.senderId = myId
              row.dataset.ts = Math.floor(Date.now() / 1000)
              const name = this.el.dataset.senderName || ""
              const main = document.createElement("div")
              main.className = "ed-flat__main"
              if (compact) {
                row.innerHTML = '<div class="ed-flat__gutter"></div>'
              } else {
                row.innerHTML =
                  '<div class="ed-flat__gutter"><span class="ed-avatar ed-avatar--sm"><span></span></span></div>'
                row.querySelector(".ed-avatar span").textContent =
                  (name.trim().charAt(0) || "?").toUpperCase()
                const head = document.createElement("div")
                head.className = "ed-flat__head"
                head.innerHTML = '<span class="ed-flat__name"></span>'
                head.querySelector(".ed-flat__name").textContent = name
                main.appendChild(head)
              }
              main.appendChild(media)
              row.appendChild(main)
            } else {
              row.className = "ed-msg flex justify-end"
              const bubble = document.createElement("div")
              bubble.className = "ed-bubble ed-bubble--me"
              // Mirror the REAL media bubble so the optimistic twin is the SAME
              // height and the swap doesn't nudge the stream: the photo sits in a
              // block (mb-1) wrapper with an .ed-bubble__meta time line beneath it
              // (+ a 1:1 sending check), exactly like the text optimistic node
              // above. Without it the real row was ~20px taller (the residual jump
              // left after the image-box reservation fix).
              const wrap = document.createElement("div")
              wrap.className = "mb-1"
              wrap.appendChild(media)
              bubble.appendChild(wrap)
              const meta = document.createElement("span")
              meta.className = "ed-bubble__meta"
              const time = document.createElement("time")
              time.textContent = new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
              meta.appendChild(time)
              if (this.el.dataset.isGroup !== "true") {
                meta.insertAdjacentHTML(
                  "beforeend",
                  '<span class="inline-flex items-center" style="margin-left:2px;">' +
                    '<span class="hero-check-micro size-3.5"></span></span>',
                )
              }
              bubble.appendChild(meta)
              row.appendChild(bubble)
            }
            this.pending.appendChild(row)
            row.classList.add("ed-msg--enter")
            setTimeout(() => row.classList.remove("ed-msg--enter"), 200)
            if (this.scroller) {
              const smooth = !window.matchMedia("(prefers-reduced-motion: reduce)").matches
              this.scroller.scrollTo({ top: this.scroller.scrollHeight, behavior: smooth ? "smooth" : "auto" })
            }
          },
          // Drive the progress ring's fill arc (#95). The dasharray is fixed in CSS
          // (the circle's circumference, r=16); we only move the dashoffset, so 0%
          // hides the arc and 100% closes the ring. A no-op if the node is gone.
          setRing(row, percent) {
            const fill = row && row.querySelector(".ed-media-sending__ring-fill")
            if (!fill) return
            const c = 2 * Math.PI * 16
            const p = Math.max(0, Math.min(100, Number(percent) || 0))
            fill.style.strokeDashoffset = c * (1 - p / 100)
          },
          // Remove an optimistic media node by client_id (the server names the exact
          // one on failure) and cancel its stall watchdog.
          dropPending(id) {
            const node = this.pending?.querySelector(`[data-client-id="${id}"]`)
            if (!node) return
            if (node._stall) clearTimeout(node._stall)
            node.remove()
          },
          // Stall watchdog (#95): if an upload makes NO progress for 30s — the link
          // died after the optimistic node + media_sending, so "send" never fires —
          // drop the stuck preview and ask the server to clear sending_media, which
          // re-shows the overlay (the entry is still staged) so the user can retry or
          // cancel. Every media_progress tick re-arms it, so a merely-slow upload is
          // never killed; a node removed by the swap leaves a harmless dead timer
          // (the callback no-ops once the node is disconnected).
          armStall(clientId) {
            const node = this.pending?.querySelector(`[data-client-id="${clientId}"]`)
            if (!node) return
            if (node._stall) clearTimeout(node._stall)
            node._stall = setTimeout(() => {
              if (!node.isConnected) return
              node.remove()
              this.pushEvent("media_send_reset", {})
            }, 30000)
          },
          // Snapshot a loaded preview <img> to a persistent JPEG data-URL. Returns
          // null on taint/empty so the node just shows the ring over a blank tile.
          snapshot(img) {
            try {
              let w = img.naturalWidth || img.width
              let h = img.naturalHeight || img.height
              if (!w || !h) return null
              // Downscale to a preview size (#95 review): a full-res phone photo
              // would allocate a ~tens-of-MB canvas and hold a multi-MB data-URL
              // per tile. 800px on the long edge is ample for the in-stream preview.
              const max = 800
              if (w > max || h > max) {
                const s = max / Math.max(w, h)
                w = Math.round(w * s)
                h = Math.round(h * s)
              }
              const c = document.createElement("canvas")
              c.width = w
              c.height = h
              c.getContext("2d").drawImage(img, 0, 0, w, h)
              return c.toDataURL("image/jpeg", 0.7)
            } catch (_e) {
              return null
            }
          },
          // Intercept a file selection (#97): compress images, then re-feed the input
          // so LiveView stages the COMPRESSED file, never the original. A native pick
          // fires BOTH `input` and `change`; we must stop EACH (else the unstopped one
          // stages the original → a duplicate). `_picking` then ignores the second of
          // the pair; `_edenCompressed` lets our re-dispatched events through.
          async compressPicked(e) {
            const input = e.target
            if (!(input instanceof HTMLInputElement) || input.type !== "file") return
            if (input._edenCompressed) return
            const files = [...input.files]
            if (!files.length) return
            if (!files.some((f) => (f.type || "").startsWith("image/"))) return
            // Stop FIRST so neither event of the pair stages the original. A pick that
            // arrives while an earlier compress is still running is then dropped (rare,
            // bounded by compressImage's timeout) rather than staged uncompressed.
            e.stopImmediatePropagation()
            e.preventDefault()
            if (this._picking) return
            this._picking = true
            try {
              const out = []
              for (const f of files) {
                out.push((f.type || "").startsWith("image/") ? await this.compressImage(f) : f)
              }
              this.feedInput(input, out)
            } finally {
              this._picking = false
            }
          },
          // Re-feed an input with an exact File set so LiveView stages it (the
          // PasteUpload set-files + dispatch path). _edenCompressed short-circuits
          // compressPicked so these files aren't re-processed.
          feedInput(input, files) {
            const dt = new DataTransfer()
            files.forEach((f) => dt.items.add(f))
            input.files = dt.files
            input._edenCompressed = true
            input.dispatchEvent(new Event("input", { bubbles: true }))
            input.dispatchEvent(new Event("change", { bubbles: true }))
            input._edenCompressed = false
          },
          // Downscale + re-encode one image to a JPEG File (#97). Returns the original
          // untouched for animated GIFs, undecodable images, or when it wouldn't
          // meaningfully shrink. createImageBitmap honors EXIF orientation (so phone
          // portraits aren't baked sideways) and decodes off the main thread; the
          // timeout guarantees the promise always settles so the pick loop can't hang.
          compressImage(file) {
            if (file.type === "image/gif") return Promise.resolve(file)
            return new Promise((resolve) => {
              // done() is the single settle point — it clears the timer, so the 8s
              // safety net covers EVERY async step (createImageBitmap AND toBlob); the
              // `settled` guard makes a late callback after the timeout a no-op.
              let settled = false
              const done = (out) => {
                if (settled) return
                settled = true
                clearTimeout(timer)
                resolve(out || file)
              }
              const timer = setTimeout(() => done(file), 8000)
              createImageBitmap(file, { imageOrientation: "from-image" })
                .then((bmp) => {
                  const w0 = bmp.width
                  const h0 = bmp.height
                  const max = 1920
                  // Only re-encode when the image actually needs downscaling. One
                  // already within bounds is kept UNTOUCHED — no lossy JPEG round-trip
                  // on screenshots (crisp text), small images, animated WebP/APNG, or
                  // transparent art. Large phone photos (the real win) still downscale.
                  if (!w0 || !h0 || (w0 <= max && h0 <= max)) {
                    bmp.close && bmp.close()
                    return done(file)
                  }
                  const s = max / Math.max(w0, h0)
                  const w = Math.round(w0 * s)
                  const h = Math.round(h0 * s)
                  const c = document.createElement("canvas")
                  c.width = w
                  c.height = h
                  const ctx = c.getContext("2d")
                  if (!ctx) {
                    bmp.close && bmp.close()
                    return done(file)
                  }
                  // JPEG has no alpha — flatten any transparency (png/webp/avif/…) onto
                  // white. Harmless for opaque images (drawImage covers the fill).
                  ctx.fillStyle = "#fff"
                  ctx.fillRect(0, 0, w, h)
                  ctx.drawImage(bmp, 0, 0, w, h)
                  bmp.close && bmp.close()
                  c.toBlob(
                    (blob) => {
                      // Only accept a meaningful win, else keep the original.
                      if (!blob || blob.size > file.size * 0.9) return done(file)
                      done(
                        new File([blob], file.name.replace(/\.[^.]+$/, "") + ".jpg", {
                          type: "image/jpeg",
                        })
                      )
                    },
                    "image/jpeg",
                    0.82
                  )
                })
                .catch(() => done(file))
            })
          },
          // The last flat row to compare against for the compact rule: a queued
          // optimistic node wins (rapid double-send), else the last streamed
          // message. Returns null in an empty room (first message — full row).
          lastFlatRow() {
            if (this.pending && this.pending.lastElementChild) {
              return this.pending.lastElementChild
            }
            const rows = document.querySelectorAll("#messages .ed-flat")
            return rows[rows.length - 1] || null
          },
          markFailed(clientId) {
            const node = this.pending.querySelector(`[data-client-id="${clientId}"]`)
            if (!node) return
            node.style.opacity = "1"
            const target = node.querySelector(".ed-bubble") || node.querySelector(".ed-flat__body")
            if (target) target.style.border = "1px solid var(--ed-danger)"
            // A failed node must not become a permanent ghost (#68): click it to
            // retry the send (same client_id → idempotent), or ✕ to dismiss it.
            node.classList.add("ed-msg-failed")
            node.title = "Failed to send — click to retry"
            node.addEventListener("click", (e) => {
              if (e.target.closest("[data-dismiss]")) return
              const body = node.dataset.body || ""
              node.remove()
              if (!body) return
              this.addOptimistic(clientId, body)
              this.queue.push({ clientId, body, sent: false })
              this.flush()
            }, { once: true })
            const x = document.createElement("button")
            x.type = "button"
            x.dataset.dismiss = ""
            x.className = "ed-msg-failed__x"
            x.setAttribute("aria-label", "Dismiss")
            x.textContent = "✕"
            x.addEventListener("click", () => node.remove())
            ;(target || node).appendChild(x)
          },
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".Lightbox">
        // In-app image viewer: click a photo to open it full-screen in a single
        // shared overlay (close on backdrop click or Esc). When the tile belongs
        // to an album (data-gallery), the overlay pages through that album's
        // photos with on-screen arrows and ←/→. Cmd/Ctrl/Shift/middle click fall
        // through to the normal "open original in a new tab".
        export default {
          mounted() {
            this.el.addEventListener("click", (e) => {
              if (e.metaKey || e.ctrlKey || e.shiftKey || e.button === 1) return
              e.preventDefault()
              this.openLightbox()
            })
          },
          openLightbox() {
            const gallery = this.el.dataset.gallery
            const tiles = gallery
              ? [...document.querySelectorAll(`[data-gallery="${gallery}"]`)]
              : [this.el]
            let i = Math.max(0, tiles.indexOf(this.el))

            const box = this.box()
            const img = box.querySelector(".ed-lightbox__img")
            const show = (n) => {
              i = (n + tiles.length) % tiles.length
              // Hide the frame until the new source decodes so paging into a
              // different photo (or album) never flashes the previous image.
              const reveal = () => { img.style.visibility = "visible" }
              img.style.visibility = "hidden"
              img.onload = reveal
              img.src = tiles[i].dataset.full
              // Reopening the same photo sets an unchanged src, which fires no
              // load event in some browsers — reveal immediately when cached.
              if (img.complete) reveal()
            }
            box.__show = show
            box.__step = (d) => show(i + d)
            box.classList.toggle("ed-lightbox--gallery", tiles.length > 1)
            show(i)

            box.classList.add("ed-lightbox--open")
            // Start each open with a clean gesture flag — a stale `__swiped` from a
            // prior swipe would otherwise suppress the first tap (e.g. the X) (#96).
            box.__swiped = false
            document.body.style.overflow = "hidden"
            document.addEventListener("keydown", box.__onKey)
          },
          box() {
            let box = document.getElementById("ed-lightbox")
            if (box) return box

            box = document.createElement("div")
            box.id = "ed-lightbox"
            box.className = "ed-lightbox"
            // Heroicon chevrons (mini) sit dead-center in the round buttons —
            // the text ‹/› glyphs rendered off-center.
            const chevron = (d) =>
              `<svg viewBox="0 0 20 20" fill="currentColor" aria-hidden="true"><path fill-rule="evenodd" d="${d}" clip-rule="evenodd"/></svg>`
            const left = "M11.78 5.22a.75.75 0 0 1 0 1.06L8.06 10l3.72 3.72a.75.75 0 1 1-1.06 1.06l-4.25-4.25a.75.75 0 0 1 0-1.06l4.25-4.25a.75.75 0 0 1 1.06 0Z"
            const right = "M8.22 5.22a.75.75 0 0 1 1.06 0l4.25 4.25a.75.75 0 0 1 0 1.06l-4.25 4.25a.75.75 0 0 1-1.06-1.06L11.94 10 8.22 6.28a.75.75 0 0 1 0-1.06Z"
            const xmark = "M6.28 5.22a.75.75 0 0 0-1.06 1.06L8.94 10l-3.72 3.72a.75.75 0 1 0 1.06 1.06L10 11.06l3.72 3.72a.75.75 0 1 0 1.06-1.06L11.06 10l3.72-3.72a.75.75 0 0 0-1.06-1.06L10 8.94 6.28 5.22Z"
            // Localized labels from #message-scroll (gettext is unreachable here).
            const lbl = document.getElementById("message-scroll")?.dataset || {}
            box.innerHTML =
              `<button class="ed-lightbox__close" aria-label="${lbl.lbClose || "Close"}">${chevron(xmark)}</button>` +
              `<button class="ed-lightbox__nav ed-lightbox__nav--prev" aria-label="${lbl.lbPrev || "Previous"}">${chevron(left)}</button>` +
              '<img class="ed-lightbox__img" alt="">' +
              `<button class="ed-lightbox__nav ed-lightbox__nav--next" aria-label="${lbl.lbNext || "Next"}">${chevron(right)}</button>`

            const close = () => {
              box.classList.remove("ed-lightbox--open")
              document.body.style.overflow = ""
              document.removeEventListener("keydown", box.__onKey)
            }
            box.__onKey = (e) => {
              if (e.key === "Escape") close()
              else if (e.key === "ArrowLeft") box.__step(-1)
              else if (e.key === "ArrowRight") box.__step(1)
            }
            box.addEventListener("click", (e) => {
              // A swipe ends in a synthetic click — ignore it so a page/close
              // gesture doesn't also fire the tap-to-close (#96).
              if (box.__swiped) {
                box.__swiped = false
                return
              }
              if (e.target.closest(".ed-lightbox__close")) return close()
              const nav = e.target.closest(".ed-lightbox__nav")
              if (nav) {
                e.stopPropagation()
                box.__step(nav.classList.contains("ed-lightbox__nav--next") ? 1 : -1)
              } else if (!e.target.closest(".ed-lightbox__img")) {
                close()
              }
            })
            // Touch (#96): no keyboard/arrows on a phone — swipe down to close,
            // swipe left/right to page an album. A gesture must clear ~50-70px and
            // be mostly on one axis to register (so a tap or tiny drift doesn't).
            // `multi` ignores pinch-zoom: a 2-finger gesture must not be read as a
            // swipe against a stale 1-finger origin (#95 review).
            let tx = 0
            let ty = 0
            let multi = false
            box.addEventListener(
              "touchstart",
              (e) => {
                if (e.touches.length === 1) {
                  tx = e.touches[0].clientX
                  ty = e.touches[0].clientY
                  multi = false
                } else {
                  multi = true
                }
                box.__swiped = false
              },
              { passive: true }
            )
            box.addEventListener("touchmove", (e) => { if (e.touches.length > 1) multi = true }, {
              passive: true,
            })
            box.addEventListener(
              "touchend",
              (e) => {
                // Wait out a pinch — only act once every finger has lifted on a
                // single-touch gesture.
                if (multi) {
                  if (e.touches.length === 0) multi = false
                  return
                }
                const t = e.changedTouches[0]
                if (!t) return
                const dx = t.clientX - tx
                const dy = t.clientY - ty
                if (dy > 70 && dy > Math.abs(dx)) {
                  box.__swiped = true
                  close()
                } else if (
                  Math.abs(dx) > 50 &&
                  Math.abs(dx) > Math.abs(dy) &&
                  box.classList.contains("ed-lightbox--gallery")
                ) {
                  box.__swiped = true
                  box.__step(dx < 0 ? 1 : -1)
                }
              },
              { passive: true }
            )
            document.body.appendChild(box)
            return box
          },
        }
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".PasteUpload">
        // Paste files/images from the clipboard straight into the composer's
        // upload (#58): screenshots and copied files land in the attachment tray.
        export default {
          mounted() {
            this.el.addEventListener("paste", (e) => {
              const files = [...(e.clipboardData?.files || [])]
              if (!files.length) return
              // Serialize media sends (#95): ignore a paste while one is uploading,
              // matching the gated attach button — keeps a single send in flight.
              if (this.el.closest("#composer")?.dataset.sendingMedia === "true") return
              const input = this.el.closest("form")?.querySelector('input[type="file"]')
              if (!input) return
              e.preventDefault()
              const dt = new DataTransfer()
              files.forEach((f) => dt.items.add(f))
              input.files = dt.files
              input.dispatchEvent(new Event("input", { bubbles: true }))
            })
          },
        }
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".EmojiPicker">
        // Composer emoji picker (#60): toggle a small grid; clicking a glyph
        // inserts it at the caret in the message input. Closes on outside click
        // or Esc. Dispatches "input" so phx-change keeps the body assign in sync.
        export default {
          mounted() {
            this.toggle = this.el.querySelector("[data-emoji-toggle]")
            this.pop = this.el.querySelector("[data-emoji-pop]")
            this.onDoc = (e) => { if (!this.el.contains(e.target)) this.setOpen(false) }
            this.onKey = (e) => { if (e.key === "Escape") this.setOpen(false) }
            this.toggle.addEventListener("click", (e) => {
              e.preventDefault()
              this.setOpen(this.pop.hidden)
            })
            this.pop.addEventListener("click", (e) => {
              const btn = e.target.closest("[data-emoji]")
              if (!btn) return
              e.preventDefault()
              // Stay open so several emoji can be picked in a row (#90); the
              // picker still closes on outside-click, Esc, or the toggle.
              this.insert(btn.dataset.emoji)
            })
          },
          destroyed() {
            document.removeEventListener("click", this.onDoc)
            document.removeEventListener("keydown", this.onKey)
          },
          setOpen(open) {
            this.pop.hidden = !open
            this.toggle.setAttribute("aria-expanded", String(open))
            const fn = open ? "addEventListener" : "removeEventListener"
            document[fn]("click", this.onDoc)
            document[fn]("keydown", this.onKey)
          },
          insert(emoji) {
            // Re-query each time: phx-update="ignore" is on the picker, not the
            // input, so the input can be re-rendered and a ref cached at mount
            // could go stale (#82 review).
            const i = this.el.closest("form")?.querySelector('input[name="message[body]"]')
            if (!i) return
            const s = i.selectionStart ?? i.value.length
            const e = i.selectionEnd ?? i.value.length
            i.value = i.value.slice(0, s) + emoji + i.value.slice(e)
            const pos = s + emoji.length
            i.setSelectionRange(pos, pos)
            i.dispatchEvent(new Event("input", { bubbles: true }))
            i.focus()
          },
        }
      </script>
    </div>
    """
  end

  ## Components

  attr :name, :string, required: true
  attr :src, :string, default: nil
  attr :online, :boolean, default: false
  attr :size, :atom, default: nil, values: [nil, :sm, :lg]

  # Circular avatar: shows the user's image when present, initials otherwise.
  defp avatar(assigns) do
    ~H"""
    <span class={["ed-avatar", @size == :sm && "ed-avatar--sm", @size == :lg && "ed-avatar--lg"]}>
      <img :if={@src} src={@src} alt="" />
      <span :if={!@src}>{initials(@name)}</span>
      <span :if={@online} class="ed-avatar__dot"></span>
    </span>
    """
  end

  attr :id, :string, required: true
  attr :conversation, :map, required: true
  attr :user, :map, required: true
  attr :online_ids, :any, required: true
  attr :active, :boolean, default: false

  defp conversation_item(assigns) do
    ~H"""
    <div id={@id} class="ed-convo-wrap" phx-hook=".ContextMenu">
      <.link
        patch={~p"/app/c/#{@conversation.id}"}
        class={["ed-convo", @active && "ed-convo--active"]}
        aria-haspopup="menu"
      >
        <.avatar
          name={title(@conversation, @user)}
          src={avatar_src(peer(@conversation, @user))}
          online={online?(@conversation, @user, @online_ids)}
        />
        <span class="ed-convo__body">
          <span class="ed-convo__top">
            <span class="ed-convo__name">
              {title(@conversation, @user)}
              <span :if={@conversation.muted} class="ed-convo__muted">
                <.icon name="hero-bell-slash-micro" class="size-3.5" />
                <span class="sr-only">{gettext("Muted")}</span>
              </span>
            </span>
            <.local_time
              :if={@conversation.last_message_at}
              at={@conversation.last_message_at}
              class="ed-convo__time"
            />
          </span>
          <span class="ed-convo__top">
            <span class="ed-convo__preview">{convo_preview(@conversation)}</span>
            <span
              :if={@conversation.unread_count > 0}
              class={["ed-badge", @conversation.muted && "ed-badge--muted"]}
            >
              {@conversation.unread_count}
            </span>
          </span>
        </span>
      </.link>
      <div class="ed-menu" id={"convo-menu-#{@conversation.id}"} data-menu role="menu" hidden>
        <button
          type="button"
          class="ed-menu__item"
          role="menuitem"
          phx-click="mark_as_read"
          phx-value-id={@conversation.id}
        >
          <.icon name="hero-check-circle-micro" class="size-4" /> {gettext("Mark as read")}
        </button>
        <button
          type="button"
          class="ed-menu__item"
          role="menuitem"
          phx-click="toggle_mute"
          phx-value-id={@conversation.id}
        >
          <.icon
            name={if @conversation.muted, do: "hero-bell-micro", else: "hero-bell-slash-micro"}
            class="size-4"
          />
          {if @conversation.muted, do: gettext("Unmute"), else: gettext("Mute")}
        </button>
        <button
          type="button"
          class="ed-menu__item"
          role="menuitem"
          phx-click="move_to_folder_prompt"
          phx-value-id={@conversation.id}
        >
          <.icon name="hero-folder-micro" class="size-4" /> {gettext("Move to folder…")}
        </button>
        <div class="ed-menu__sep"></div>
        <button
          type="button"
          class="ed-menu__item ed-menu__item--danger"
          role="menuitem"
          phx-click="delete_chat"
          phx-value-id={@conversation.id}
          data-confirm={gettext("Delete this chat? It will be removed from your list.")}
        >
          <.icon name="hero-trash-micro" class="size-4" /> {gettext("Delete chat")}
        </button>
      </div>
    </div>
    """
  end

  attr :results, :map, required: true
  attr :query, :string, required: true
  attr :user, :map, required: true
  attr :online_ids, :any, required: true

  # Grouped search results: conversations (by participant/title) and messages
  # (by content). A message row opens its permalink — the existing scroll-to +
  # highlight flow. Matched terms render inside <mark>.
  defp search_results(assigns) do
    ~H"""
    <div class="space-y-3">
      <p
        :if={@results.conversations == [] and @results.messages == []}
        class="text-center py-8"
        style="color: var(--ed-muted); font-size:0.875rem;"
      >
        {gettext("No results for “%{query}”", query: String.trim(@query))}
      </p>

      <section :if={@results.conversations != []}>
        <h3 class="ed-search__group">{gettext("Chats")}</h3>
        <.link
          :for={conversation <- @results.conversations}
          patch={~p"/app/c/#{conversation.id}"}
          class="ed-convo"
        >
          <.avatar
            name={title(conversation, @user)}
            src={avatar_src(peer(conversation, @user))}
            online={online?(conversation, @user, @online_ids)}
          />
          <span class="ed-convo__body">
            <span class="ed-convo__name">
              <.highlighted text={title(conversation, @user)} query={@query} />
            </span>
          </span>
        </.link>
      </section>

      <section :if={@results.messages != []}>
        <h3 class="ed-search__group">{gettext("Messages")}</h3>
        <.link
          :for={message <- @results.messages}
          patch={~p"/app/c/#{message.conversation_id}/m/#{message.id}"}
          class="ed-convo"
        >
          <.avatar
            name={title(message.conversation, @user)}
            src={avatar_src(peer(message.conversation, @user))}
            online={online?(message.conversation, @user, @online_ids)}
          />
          <span class="ed-convo__body">
            <span class="ed-convo__top">
              <span class="ed-convo__name">{title(message.conversation, @user)}</span>
              <.local_time at={message.inserted_at} class="ed-convo__time" />
            </span>
            <span class="ed-convo__preview">
              <%!-- In a group the conversation title doesn't say who wrote it. --%>
              <span :if={message.conversation.is_group and message.sender}>
                {message.sender.display_name}:
              </span>
              <.highlighted text={snippet(message.body, @query)} query={@query} />
            </span>
          </span>
        </.link>
      </section>
    </div>
    """
  end

  attr :results, :list, required: true
  attr :rooms, :list, required: true
  attr :query, :string, required: true
  attr :channel, :map, required: true

  # Channel-wide search results (#43): rooms by name (from the already-loaded
  # joined-rooms list — no query) + message bodies with a room breadcrumb.
  defp channel_search_results(assigns) do
    needle = assigns.query |> String.trim() |> String.downcase()

    assigns =
      assign(
        assigns,
        :room_matches,
        Enum.filter(assigns.rooms, &String.contains?(String.downcase(&1.name), needle))
      )

    ~H"""
    <div class="space-y-3">
      <p
        :if={@room_matches == [] and @results == []}
        class="text-center py-8"
        style="color: var(--ed-muted); font-size:0.875rem;"
      >
        {gettext("No results for “%{query}”", query: String.trim(@query))}
      </p>

      <section :if={@room_matches != []}>
        <h3 class="ed-search__group">{gettext("Rooms")}</h3>
        <.link
          :for={room <- @room_matches}
          patch={~p"/channels/#{@channel.id}/r/#{room.id}"}
          class="ed-convo ed-room"
        >
          <.room_glyph room={room} />
          <span class="ed-convo__name flex-1 truncate">
            <.highlighted text={room.name} query={@query} />
          </span>
        </.link>
      </section>

      <section :if={@results != []}>
        <h3 class="ed-search__group">{gettext("Messages")}</h3>
        <.link
          :for={message <- @results}
          patch={~p"/channels/#{@channel.id}/r/#{message.conversation_id}/m/#{message.id}"}
          class="ed-convo"
        >
          <span class="ed-convo__body">
            <span class="ed-convo__top">
              <span class="ed-convo__name flex items-center gap-1">
                <.room_glyph room={message.conversation} /> {message.conversation.name}
              </span>
              <.local_time at={message.inserted_at} class="ed-convo__time" />
            </span>
            <span class="ed-convo__preview">
              <span :if={message.sender}>{message.sender.display_name}:</span>
              <.highlighted text={snippet(message.body, @query)} query={@query} />
            </span>
          </span>
        </.link>
      </section>
    </div>
    """
  end

  attr :room, :map, required: true
  attr :class, :string, default: nil

  # The room's identity glyph: general is ALWAYS the hash (Town Square); open
  # rooms get a globe (any link joins); private rooms a lock.
  defp room_glyph(assigns) do
    ~H"""
    <span class={["ed-room__hash", @class]}>
      <span :if={@room.is_general}>#</span>
      <.icon
        :if={!@room.is_general and @room.visibility == "private"}
        name="hero-lock-closed-micro"
        class="size-3.5"
      />
      <.icon
        :if={!@room.is_general and @room.visibility != "private"}
        name="hero-globe-alt-micro"
        class="size-3.5"
      />
    </span>
    """
  end

  attr :text, :string, required: true
  attr :query, :string, required: true

  # Wraps case-insensitive occurrences of the query in <mark>.
  defp highlighted(assigns) do
    ~H"{highlight_parts(@text, @query)}"
  end

  # Pre-rendered safe iodata: every user-derived part goes through html_escape
  # (no injection path); only the literal <mark> tags are raw. Built in Elixir
  # rather than template markup so no template whitespace can slip between a
  # match and the rest of its word ("озе ре") — newlines the formatter adds
  # inside HEEx render as spaces.
  defp highlight_parts(text, query) do
    q = String.trim(query)

    if q == "" do
      Phoenix.HTML.html_escape(text)
    else
      html =
        text
        |> String.split(~r/#{Regex.escape(q)}/iu, include_captures: true)
        |> Enum.map(&mark_part(&1, String.downcase(q)))

      {:safe, html}
    end
  end

  defp mark_part(part, down_query) do
    {:safe, escaped} = Phoenix.HTML.html_escape(part)

    if String.downcase(part) == down_query do
      [~s(<mark class="ed-mark">), escaped, "</mark>"]
    else
      escaped
    end
  end

  # A short window of the message body around the first match, so long messages
  # show the relevant part. Grapheme-based (byte offsets would split UTF-8).
  defp snippet(body, query) do
    # Strip markdown markers so a result preview reads as plain text, not raw
    # `**`/`#`; the highlight then matches against the displayed text.
    body = Markup.strip(body)
    q = String.downcase(String.trim(query))
    before = body |> String.downcase() |> String.split(q, parts: 2) |> hd()

    start = max(String.length(before) - 24, 0)
    prefix = if start > 0, do: "…", else: ""
    prefix <> String.slice(body, start, 110)
  end

  attr :id, :string, required: true
  attr :room, :map, required: true
  attr :channel, :map, required: true
  attr :active, :boolean, default: false
  attr :admin, :boolean, default: false

  # A room row in the channel sidebar. Same context-menu affordance as chats
  # (right-click / long-press, the shared .ContextMenu hook): Mute for everyone,
  # Rename/Delete for admins.
  defp room_item(assigns) do
    ~H"""
    <div
      id={@id}
      class="ed-convo-wrap ed-room-wrap"
      data-id={@room.id}
      draggable={to_string(@admin)}
      phx-hook=".ContextMenu"
    >
      <.link
        patch={~p"/channels/#{@channel.id}/r/#{@room.id}"}
        class={["ed-convo ed-room", @active && "ed-convo--active"]}
        aria-haspopup="menu"
        draggable="false"
      >
        <%!-- draggable=false: links are natively draggable, which would fight
              the row's reorder drag (the wrap is the drag source). --%>
        <.room_glyph room={@room} />
        <span class="ed-convo__name flex-1 truncate">
          {@room.name}
          <span :if={@room.favorite} class="ed-convo__muted" title={gettext("Favorite")}>
            <.icon name="hero-star-micro" class="size-3.5" />
            <span class="sr-only">{gettext("Favorite")}</span>
          </span>
          <span :if={@room.muted} class="ed-convo__muted">
            <.icon name="hero-bell-slash-micro" class="size-3.5" />
            <span class="sr-only">{gettext("Muted")}</span>
          </span>
        </span>
        <span :if={@room.unread_count > 0} class={["ed-badge", @room.muted && "ed-badge--muted"]}>
          {@room.unread_count}
        </span>
      </.link>
      <%!-- Visible ⋯ (hover): opens the same context menu as right-click. --%>
      <button
        type="button"
        class="ed-room__more"
        data-menu-trigger
        title={gettext("More actions")}
        aria-label={gettext("More actions")}
      >
        <.icon name="hero-ellipsis-horizontal-mini" class="size-4" />
      </button>
      <div class="ed-menu" id={"room-menu-#{@room.id}"} data-menu role="menu" hidden>
        <button
          type="button"
          class="ed-menu__item"
          role="menuitem"
          phx-click="mark_as_read"
          phx-value-id={@room.id}
        >
          <.icon name="hero-check-circle-micro" class="size-4" /> {gettext("Mark as read")}
        </button>
        <button
          type="button"
          class="ed-menu__item"
          role="menuitem"
          phx-click="toggle_room_favorite"
          phx-value-id={@room.id}
        >
          <.icon name="hero-star-micro" class="size-4" />
          {if @room.favorite, do: gettext("Unfavorite"), else: gettext("Favorite")}
        </button>
        <button
          type="button"
          class="ed-menu__item"
          role="menuitem"
          phx-click="toggle_mute"
          phx-value-id={@room.id}
        >
          <.icon
            name={if @room.muted, do: "hero-bell-micro", else: "hero-bell-slash-micro"}
            class="size-4"
          />
          {if @room.muted, do: gettext("Unmute"), else: gettext("Mute")}
        </button>
        <button
          type="button"
          class="ed-menu__item"
          role="menuitem"
          data-copy-link
          data-link={url(~p"/channels/#{@channel.id}/r/#{@room.id}")}
        >
          <.icon name="hero-link-micro" class="size-4" /> {gettext("Copy link")}
        </button>
        <div :if={@admin} class="ed-menu__sep"></div>
        <button
          :if={@admin}
          type="button"
          class="ed-menu__item"
          role="menuitem"
          phx-click="open_room_add"
          phx-value-id={@room.id}
        >
          <.icon name="hero-user-plus-micro" class="size-4" /> {gettext("Add members")}
        </button>
        <button
          :if={@admin}
          type="button"
          class="ed-menu__item"
          role="menuitem"
          phx-click="open_room_rename"
          phx-value-id={@room.id}
        >
          <.icon name="hero-pencil-micro" class="size-4" /> {gettext("Rename room")}
        </button>
        <div :if={@admin and not @room.is_general} class="ed-menu__sep"></div>
        <button
          :if={@admin and not @room.is_general}
          type="button"
          class="ed-menu__item ed-menu__item--danger"
          role="menuitem"
          phx-click="delete_room"
          phx-value-id={@room.id}
          data-confirm={gettext("Delete this room and all its messages? This cannot be undone.")}
        >
          <.icon name="hero-trash-micro" class="size-4" /> {gettext("Delete room")}
        </button>
      </div>
    </div>
    """
  end

  attr :members, :list, required: true
  attr :channel, :map, required: true
  attr :me, :map, required: true
  attr :online_ids, :any, required: true

  # Channel members: roles, online dots, and the owner/admin action matrix
  # (the context re-checks every action).
  defp channel_members_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-30">
      <button
        class="absolute inset-0 w-full h-full"
        style="background: oklch(0 0 0 / 0.55);"
        phx-click="close_channel_members"
        aria-label={gettext("Close")}
        tabindex="-1"
      >
      </button>
      <div class="absolute inset-0 grid place-items-center p-4 pointer-events-none">
        <div
          class="w-full max-w-md rounded-[var(--ed-radius-lg)] border p-5 space-y-4 pointer-events-auto"
          style="background: var(--ed-surface); border-color: var(--ed-border);"
          phx-window-keydown="close_channel_members"
          phx-key="Escape"
          role="dialog"
          aria-modal="true"
        >
          <div class="flex items-center justify-between">
            <h2 style="font-weight:600;">
              {gettext("Members")}
              <span style="color: var(--ed-muted); font-weight:400;">· {length(@members)}</span>
            </h2>
            <button
              class="ed-btn--icon"
              phx-click="close_channel_members"
              aria-label={gettext("Close")}
            >
              <.icon name="hero-x-mark-mini" class="size-5" />
            </button>
          </div>

          <div class="max-h-80 overflow-y-auto space-y-0.5">
            <div
              :for={%{user: user, role: role} <- @members}
              class="flex items-center gap-3 p-2 rounded-[var(--ed-radius)]"
            >
              <button
                type="button"
                class="flex items-center gap-3 flex-1 min-w-0 text-left rounded-[var(--ed-radius)] transition-colors hover:bg-[var(--ed-bg)]"
                data-profile-trigger
                phx-click="show_profile"
                phx-value-id={user.id}
                aria-label={gettext("View profile")}
              >
                <.avatar
                  name={user.display_name}
                  src={avatar_src(user)}
                  online={MapSet.member?(@online_ids, user.id)}
                  size={:sm}
                />
                <span class="flex-1 min-w-0">
                  <span class="block truncate" style="font-weight:550; font-size:0.875rem;">
                    {user.display_name}
                    <span :if={user.id == @me.id} style="color: var(--ed-muted); font-weight:400;">
                      · {gettext("you")}
                    </span>
                  </span>
                  <span class="block truncate" style="color: var(--ed-muted); font-size:0.75rem;">
                    @{user.username} · {role_label(role)}
                  </span>
                </span>
              </button>

              <%!-- Owner: manage admins / hand over / remove. Admin: remove members. --%>
              <span :if={member_actions?(@channel.role, role, user.id, @me.id)} class="flex gap-1">
                <button
                  :if={@channel.role == "owner" and role == "member"}
                  type="button"
                  class="ed-btn--icon"
                  title={gettext("Make admin")}
                  aria-label={gettext("Make admin")}
                  phx-click="set_member_role"
                  phx-value-id={user.id}
                  phx-value-role="admin"
                >
                  <.icon name="hero-shield-check-micro" class="size-4" />
                </button>
                <button
                  :if={@channel.role == "owner" and role == "admin"}
                  type="button"
                  class="ed-btn--icon"
                  title={gettext("Remove admin")}
                  aria-label={gettext("Remove admin")}
                  phx-click="set_member_role"
                  phx-value-id={user.id}
                  phx-value-role="member"
                >
                  <.icon name="hero-shield-exclamation-micro" class="size-4" />
                </button>
                <button
                  :if={@channel.role == "owner"}
                  type="button"
                  class="ed-btn--icon"
                  title={gettext("Transfer ownership")}
                  aria-label={gettext("Transfer ownership")}
                  phx-click="transfer_ownership"
                  phx-value-id={user.id}
                  data-confirm={gettext("Hand this channel over? You will become an admin.")}
                >
                  <.icon name="hero-key-micro" class="size-4" />
                </button>
                <button
                  type="button"
                  class="ed-btn--icon"
                  style="color: var(--ed-danger);"
                  title={gettext("Remove from channel")}
                  aria-label={gettext("Remove from channel")}
                  phx-click="remove_member"
                  phx-value-id={user.id}
                  data-confirm={gettext("Remove this member from the channel?")}
                >
                  <.icon name="hero-user-minus-micro" class="size-4" />
                </button>
              </span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp role_label("owner"), do: gettext("owner")
  defp role_label("admin"), do: gettext("admin")
  defp role_label(_member), do: gettext("member")

  # Mirrors the context's removal matrix for showing the action cluster.
  defp member_actions?(_my_role, _target_role, target_id, me_id) when target_id == me_id,
    do: false

  defp member_actions?("owner", target_role, _t, _m), do: target_role != "owner"
  defp member_actions?("admin", "member", _t, _m), do: true
  defp member_actions?(_my_role, _target_role, _t, _m), do: false

  attr :room, :map, required: true
  attr :addable, :list, required: true
  attr :selected, :any, required: true
  attr :invite_url, :any, required: true
  attr :online_ids, :any, required: true

  # Add members to a ROOM (#42): a platform-wide picker (non-channel users get
  # general + the room per the #41 matrix); private rooms also offer a
  # one-shot invite link.
  defp room_add_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-30">
      <button
        class="absolute inset-0 w-full h-full"
        style="background: oklch(0 0 0 / 0.55);"
        phx-click="close_room_add"
        aria-label={gettext("Close")}
        tabindex="-1"
      >
      </button>
      <div class="absolute inset-0 grid place-items-center p-4 pointer-events-none">
        <div
          class="w-full max-w-sm rounded-[var(--ed-radius-lg)] border p-5 space-y-4 pointer-events-auto"
          style="background: var(--ed-surface); border-color: var(--ed-border);"
          phx-window-keydown="close_room_add"
          phx-key="Escape"
          role="dialog"
          aria-modal="true"
        >
          <div class="flex items-center justify-between">
            <h2 style="font-weight:600;">
              {gettext("Add to %{room}", room: @room.name)}
            </h2>
            <button class="ed-btn--icon" phx-click="close_room_add" aria-label={gettext("Close")}>
              <.icon name="hero-x-mark-mini" class="size-5" />
            </button>
          </div>

          <%!-- Private rooms: a one-shot invite link (channel + room). --%>
          <div :if={@room.visibility == "private"} class="space-y-2">
            <div :if={@invite_url} class="flex items-center gap-2">
              <input type="text" readonly value={@invite_url} class="ed-input flex-1" />
              <button
                type="button"
                id="copy-room-invite-url"
                class="ed-btn ed-btn--primary"
                phx-hook=".CopyUrl"
                data-url={@invite_url}
                data-copied={gettext("Copied!")}
              >
                {gettext("Copy")}
              </button>
            </div>
            <button
              :if={is_nil(@invite_url)}
              type="button"
              class="ed-btn ed-btn--ghost w-full justify-center"
              phx-click="create_room_invite"
            >
              <.icon name="hero-link-micro" class="size-4" /> {gettext("Create invite link")}
            </button>
          </div>

          <p :if={@addable == []} style="color: var(--ed-muted); font-size:0.875rem;">
            {gettext("Everyone is already here.")}
          </p>

          <div class="max-h-72 overflow-y-auto space-y-0.5">
            <button
              :for={user <- @addable}
              type="button"
              class="flex w-full items-center gap-3 p-2 rounded-[var(--ed-radius)] text-left transition-colors hover:bg-[var(--ed-bg)]"
              phx-click="toggle_room_add_user"
              phx-value-id={user.id}
              aria-pressed={to_string(MapSet.member?(@selected, user.id))}
            >
              <span class={["ed-check", MapSet.member?(@selected, user.id) && "ed-check--on"]}>
                <.icon
                  :if={MapSet.member?(@selected, user.id)}
                  name="hero-check-mini"
                  class="size-4"
                />
              </span>
              <.avatar
                name={user.display_name}
                src={avatar_src(user)}
                online={MapSet.member?(@online_ids, user.id)}
                size={:sm}
              />
              <span class="flex-1 min-w-0 truncate" style="font-weight:550; font-size:0.875rem;">
                {user.display_name}
              </span>
            </button>
          </div>

          <div class="flex justify-end">
            <button
              type="button"
              class="ed-btn ed-btn--primary"
              phx-click="confirm_room_add"
              disabled={MapSet.size(@selected) == 0}
            >
              {gettext("Add")} ({MapSet.size(@selected)})
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :addable, :list, required: true
  attr :selected, :any, required: true
  attr :online_ids, :any, required: true

  defp add_members_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-30">
      <button
        class="absolute inset-0 w-full h-full"
        style="background: oklch(0 0 0 / 0.55);"
        phx-click="close_add_members"
        aria-label={gettext("Close")}
        tabindex="-1"
      >
      </button>
      <div class="absolute inset-0 grid place-items-center p-4 pointer-events-none">
        <div
          class="w-full max-w-sm rounded-[var(--ed-radius-lg)] border p-5 space-y-4 pointer-events-auto"
          style="background: var(--ed-surface); border-color: var(--ed-border);"
          phx-window-keydown="close_add_members"
          phx-key="Escape"
          role="dialog"
          aria-modal="true"
        >
          <div class="flex items-center justify-between">
            <h2 style="font-weight:600;">{gettext("Add members")}</h2>
            <button class="ed-btn--icon" phx-click="close_add_members" aria-label={gettext("Close")}>
              <.icon name="hero-x-mark-mini" class="size-5" />
            </button>
          </div>

          <p :if={@addable == []} style="color: var(--ed-muted); font-size:0.875rem;">
            {gettext("Everyone is already here.")}
          </p>

          <div class="max-h-72 overflow-y-auto space-y-0.5">
            <button
              :for={user <- @addable}
              type="button"
              class="flex w-full items-center gap-3 p-2 rounded-[var(--ed-radius)] text-left transition-colors hover:bg-[var(--ed-bg)]"
              phx-click="toggle_add_user"
              phx-value-id={user.id}
              aria-pressed={to_string(MapSet.member?(@selected, user.id))}
            >
              <span class={["ed-check", MapSet.member?(@selected, user.id) && "ed-check--on"]}>
                <.icon
                  :if={MapSet.member?(@selected, user.id)}
                  name="hero-check-mini"
                  class="size-4"
                />
              </span>
              <.avatar
                name={user.display_name}
                src={avatar_src(user)}
                online={MapSet.member?(@online_ids, user.id)}
                size={:sm}
              />
              <span class="flex-1 min-w-0 truncate" style="font-weight:550; font-size:0.875rem;">
                {user.display_name}
              </span>
            </button>
          </div>

          <div class="flex justify-end">
            <button
              type="button"
              class="ed-btn ed-btn--primary"
              phx-click="confirm_add_members"
              disabled={MapSet.size(@selected) == 0}
            >
              {gettext("Add")} ({MapSet.size(@selected)})
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :invites, :list, required: true
  attr :new_url, :any, required: true

  defp invites_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-30">
      <button
        class="absolute inset-0 w-full h-full"
        style="background: oklch(0 0 0 / 0.55);"
        phx-click="close_invites"
        aria-label={gettext("Close")}
        tabindex="-1"
      >
      </button>
      <div class="absolute inset-0 grid place-items-center p-4 pointer-events-none">
        <div
          class="w-full max-w-md rounded-[var(--ed-radius-lg)] border p-5 space-y-4 pointer-events-auto"
          style="background: var(--ed-surface); border-color: var(--ed-border);"
          phx-window-keydown="close_invites"
          phx-key="Escape"
          role="dialog"
          aria-modal="true"
        >
          <div class="flex items-center justify-between">
            <h2 style="font-weight:600;">{gettext("Invite links")}</h2>
            <button class="ed-btn--icon" phx-click="close_invites" aria-label={gettext("Close")}>
              <.icon name="hero-x-mark-mini" class="size-5" />
            </button>
          </div>

          <%!-- The raw link exists only right after creation — copy it now. --%>
          <div :if={@new_url} class="space-y-2">
            <p style="color: var(--ed-muted); font-size:0.8125rem;">
              {gettext("Copy this link now — it won't be shown again.")}
            </p>
            <div class="flex items-center gap-2">
              <input type="text" readonly value={@new_url} class="ed-input flex-1" />
              <button
                type="button"
                id="copy-invite-url"
                class="ed-btn ed-btn--primary"
                phx-hook=".CopyUrl"
                data-url={@new_url}
                data-copied={gettext("Copied!")}
              >
                {gettext("Copy")}
              </button>
            </div>
          </div>

          <button
            :if={is_nil(@new_url)}
            type="button"
            class="ed-btn ed-btn--primary w-full"
            phx-click="create_invite"
          >
            <.icon name="hero-link-micro" class="size-4" /> {gettext("Create invite link")}
          </button>

          <div :if={@invites != []} class="space-y-2">
            <p style="color: var(--ed-muted); font-size:0.75rem; text-transform: uppercase; letter-spacing: 0.04em; font-weight:600;">
              {gettext("Active links")}
            </p>
            <div
              :for={invite <- @invites}
              class="flex items-center gap-3 p-2 rounded-[var(--ed-radius)] border"
              style="border-color: var(--ed-border);"
            >
              <span class="flex-1 min-w-0" style="font-size:0.8125rem;">
                <span class="block" style="color: var(--ed-muted);">
                  {gettext("Uses: %{used}%{cap}",
                    used: invite.used_count,
                    cap: if(invite.max_uses, do: " / #{invite.max_uses}", else: "")
                  )} · {gettext("expires")} {Calendar.strftime(invite.expires_at, "%Y-%m-%d")}
                </span>
              </span>
              <button
                type="button"
                class="ed-btn ed-btn--ghost text-sm"
                style="color: var(--ed-danger);"
                phx-click="revoke_invite"
                phx-value-id={invite.id}
                data-confirm={gettext("Revoke this link? Anyone holding it loses access.")}
              >
                {gettext("Revoke")}
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :form, :any, required: true
  attr :submit_label, :string, required: true
  attr :show_visibility, :boolean, default: true

  # Create/rename room modal: name + visibility (the picker hides for general —
  # the Town Square is always open; the changeset guard enforces it anyway).
  defp room_form_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-30" id="room-modal">
      <button
        class="absolute inset-0 w-full h-full"
        style="background: oklch(0 0 0 / 0.55);"
        phx-click="close_room_modal"
        aria-label={gettext("Close")}
        tabindex="-1"
      >
      </button>
      <div class="absolute inset-0 grid place-items-center p-4 pointer-events-none">
        <div
          class="w-full max-w-sm rounded-[var(--ed-radius-lg)] border p-5 space-y-4 pointer-events-auto"
          style="background: var(--ed-surface); border-color: var(--ed-border);"
          phx-window-keydown="close_room_modal"
          phx-key="Escape"
          role="dialog"
          aria-modal="true"
        >
          <div class="flex items-center justify-between">
            <h2 style="font-weight:600;">{@title}</h2>
            <button class="ed-btn--icon" phx-click="close_room_modal" aria-label={gettext("Close")}>
              <.icon name="hero-x-mark-mini" class="size-5" />
            </button>
          </div>

          <.form for={@form} id="room-form" phx-submit="save_room" class="space-y-4">
            <.ed_field
              field={@form[:name]}
              label={gettext("Room name")}
              maxlength={Chat.Conversation.max_room_name()}
            />

            <fieldset :if={@show_visibility} class="space-y-2">
              <legend
                style="font-size:0.8125rem; font-weight:600; color: var(--ed-muted);"
                class="mb-1"
              >
                {gettext("Access")}
              </legend>
              <label class="ed-radio-row">
                <input
                  type="radio"
                  name={@form[:visibility].name}
                  value="open"
                  checked={(@form[:visibility].value || "open") == "open"}
                />
                <span class="min-w-0">
                  <span class="flex items-center gap-1.5" style="font-weight:550; font-size:0.875rem;">
                    <.icon name="hero-globe-alt-micro" class="size-3.5" /> {gettext("Open")}
                  </span>
                  <span class="block" style="color: var(--ed-muted); font-size:0.75rem;">
                    {gettext("Anyone with the link joins instantly.")}
                  </span>
                </span>
              </label>
              <label class="ed-radio-row">
                <input
                  type="radio"
                  name={@form[:visibility].name}
                  value="private"
                  checked={@form[:visibility].value == "private"}
                />
                <span class="min-w-0">
                  <span class="flex items-center gap-1.5" style="font-weight:550; font-size:0.875rem;">
                    <.icon name="hero-lock-closed-micro" class="size-3.5" /> {gettext("Private")}
                  </span>
                  <span class="block" style="color: var(--ed-muted); font-size:0.75rem;">
                    {gettext("Hidden from the sidebar; entry by invite, admin add, or request.")}
                  </span>
                </span>
              </label>
            </fieldset>

            <div class="flex justify-end">
              <button type="submit" class="ed-btn ed-btn--primary">{@submit_label}</button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end

  # Sidebar preview line. An attachment shows "<emoji> <caption|label>" so the row
  # is never blank (keeps item height + the time position consistent). An album
  # (count > 1) shows a counted label ("3 photos") in place of the single label.
  defp convo_preview(%{last_message_kind: kind} = conversation)
       when kind in ~w(image video file) do
    {emoji, _} = attachment_label(kind)
    caption = conversation.last_message_body

    body =
      if is_binary(caption) and caption != "",
        do: Markup.strip(caption),
        else: album_label(kind, conversation.last_message_attachment_count || 1)

    emoji <> " " <> body
  end

  defp convo_preview(%{last_message_body: body}) when is_binary(body) and body != "",
    do: Markup.strip(body)

  defp convo_preview(_conversation), do: gettext("No messages yet")

  # Quote-reply trigger (#71): inside the thread panel, target the thread composer
  # (so the reply posts into the thread); elsewhere the room/DM composer.
  defp reply_js(id, true),
    do: JS.push("reply_in_thread", value: %{"id" => id}) |> JS.focus(to: "#reply-body")

  defp reply_js(id, _not_in_thread),
    do: JS.push("reply", value: %{"id" => id}) |> JS.focus(to: "#composer-body")

  # Quote-reply (#71): author + one-line preview of the quoted message, for the
  # composer tray and the rendered quote block.
  defp reply_author(%{sender: %{display_name: name}}) when is_binary(name), do: name
  defp reply_author(_message), do: gettext("Deleted account")

  defp reply_snippet(%{deleted_at: at}) when not is_nil(at), do: gettext("Message deleted")

  defp reply_snippet(%{body: body, attachments: atts}) do
    cond do
      is_binary(body) and String.trim(body) != "" ->
        body |> Markup.strip() |> String.slice(0, 120)

      is_list(atts) and atts != [] ->
        media_label(hd(atts).kind)

      true ->
        ""
    end
  end

  defp reply_snippet(_message), do: ""

  defp media_label("image"), do: gettext("Photo")
  defp media_label("video"), do: gettext("Video")
  defp media_label("audio"), do: gettext("Audio")
  defp media_label(_file), do: gettext("File")

  defp attachment_label("image"), do: {"📷", gettext("Photo")}
  defp attachment_label("video"), do: {"🎬", gettext("Video")}
  defp attachment_label("file"), do: {"📎", gettext("File")}

  # A single attachment keeps its plain label; an album is counted by its first
  # attachment's kind ("3 photos") — the common pure-media case reads naturally.
  defp album_label(kind, count) when count <= 1, do: elem(attachment_label(kind), 1)
  defp album_label("image", n), do: ngettext("%{count} photo", "%{count} photos", n)
  defp album_label("video", n), do: ngettext("%{count} video", "%{count} videos", n)
  defp album_label(_file, n), do: ngettext("%{count} file", "%{count} files", n)

  # A small curated set for the composer emoji picker (#60) — common, cross-
  # platform glyphs, no dependency. Native emoji also type/paste fine; this is
  # just an insert affordance for desktop.
  defp emoji_set do
    ~w(😀 😅 😂 🙂 😉 😍 😎 🤔 😴 😢 😭 😡 👍 👎 👌 🙏 👏 🙌 💪 🔥 ✨ 🎉 ❤️ 🧡 💛 💚 💙 💜 ✅ ❌ ⚡ 💡 📌 📎 🚀 👀 🤝 🎶)
  end

  # The full reaction set the "more" chevron expands to — from the context so the
  # picker can never offer an emoji the changeset would reject. The quick row is
  # the viewer's personal set, threaded in via the `quick` attr (see `@my_quick`).
  defp reaction_set, do: Chat.allowed_reactions()

  # The set of emoji the current viewer has reacted with on this message — used to
  # mark the matching menu buttons active. Falls back to [] when reactions aren't
  # loaded (defensive) or there's no viewer id.
  defp mine_emoji(%{reactions: reactions}, me) when is_list(reactions) and not is_nil(me),
    do: for(r <- reactions, r.user_id == me, do: r.emoji)

  defp mine_emoji(_message, _me), do: []

  attr :message, :map, required: true

  # Quote-reply (#71): a tappable quote of the message this one replies to, shown
  # above the body. Tapping scrolls to + highlights the original. Only renders for
  # a loaded reply_to (a nilified / never-set ref shows nothing).
  defp quoted_reply(assigns) do
    ~H"""
    <button
      :if={match?(%Chat.Message{}, @message.reply_to)}
      type="button"
      class="ed-quote"
      phx-click="focus_original"
      phx-value-id={@message.reply_to.id}
    >
      <span class="ed-quote__name">{reply_author(@message.reply_to)}</span>
      <span class="ed-quote__text">{reply_snippet(@message.reply_to)}</span>
    </button>
    """
  end

  attr :message, :map, required: true
  attr :me, :any, required: true

  # Reaction chips under a message: one per emoji with its count; the viewer's
  # own reactions are highlighted (aria-pressed) and clicking toggles them.
  # Aggregated here so each viewer computes "mine" from their own id.
  defp reactions(assigns) do
    rows = if is_list(assigns.message.reactions), do: assigns.message.reactions, else: []

    chips =
      rows
      |> Enum.group_by(& &1.emoji)
      |> Enum.map(&build_chip(&1, assigns.me))
      # Most-reacted first; emoji as a stable tiebreaker so order doesn't jitter.
      |> Enum.sort_by(&{-&1.count, &1.emoji})

    assigns = assign(assigns, :chips, chips)

    ~H"""
    <div :if={@chips != []} class="ed-reactions">
      <button
        :for={chip <- @chips}
        type="button"
        class={["ed-react", chip.mine && "ed-react--mine"]}
        phx-click="react"
        phx-value-id={@message.id}
        phx-value-emoji={chip.emoji}
        aria-pressed={to_string(chip.mine)}
        title={chip.title}
        aria-label={chip.label}
      >
        <span class="ed-react__emoji" aria-hidden="true">{chip.emoji}</span>
        <span class="ed-react__count" aria-hidden="true">{chip.count}</span>
      </button>
    </div>
    """
  end

  # One reaction chip: count, whether it's mine, the reactor list (#82) for the
  # hover title + a11y label. `me` and the rows are split once; `length` once.
  defp build_chip({emoji, rows}, me) do
    {mine_rows, other_rows} = Enum.split_with(rows, &(&1.user_id == me))
    count = length(rows)
    who = format_reactors(other_rows, mine_rows != [])

    %{
      emoji: emoji,
      count: count,
      mine: mine_rows != [],
      # nil so HEEx omits the attribute when no reactor name resolved (reactions
      # not preloaded with :user) — no empty tooltip; aria-label keeps the count.
      title: if(who == "", do: nil, else: who),
      label: if(who == "", do: count_label(emoji, count), else: "#{emoji}: #{who}")
    }
  end

  # "Anna, Oleg and you": other reactors' display names (the viewer as "you").
  defp format_reactors(other_rows, mine?) do
    names = other_rows |> Enum.map(&reactor_name/1) |> Enum.reject(&is_nil/1) |> Enum.sort()
    format_name_list(if mine?, do: names ++ [gettext("you")], else: names)
  end

  defp count_label(emoji, count) do
    ngettext("%{emoji}: %{count} reaction", "%{emoji}: %{count} reactions", count,
      emoji: emoji,
      count: count
    )
  end

  defp reactor_name(%{user: %{display_name: name}}) when is_binary(name), do: name
  defp reactor_name(_), do: nil

  defp format_name_list([]), do: ""
  defp format_name_list([one]), do: one

  defp format_name_list(names) do
    {leading, [last]} = Enum.split(names, -1)
    gettext("%{names} and %{last}", names: Enum.join(leading, ", "), last: last)
  end

  attr :id, :string, required: true
  attr :message, :map, required: true
  attr :conversation_id, :any, required: true
  attr :mine, :boolean, required: true
  attr :me, :any, default: nil
  attr :quick, :list, default: []
  attr :participants, :list, default: []
  attr :in_thread, :boolean, default: false
  attr :menu, :boolean, default: true
  attr :admin, :boolean, default: false
  attr :thread_unread, :integer, default: 0

  # A system message (no human sender) — a centered notice rendered from `meta`.
  # The join-request carries an inline «Add» for channel admins while pending.
  defp flat_message(%{message: %{kind: "system"}} = assigns) do
    ~H"""
    <div id={@id} class="ed-sysmsg">
      <span>
        {gettext("%{name} requested to join", name: @message.meta["requester_name"])}
      </span>
      <button
        :if={@admin and @message.meta["status"] == "pending"}
        type="button"
        class="ed-btn ed-btn--primary ed-btn--sm"
        phx-click="approve_join"
        phx-value-id={@message.id}
      >
        {gettext("Add")}
      </button>
      <button
        :if={@admin and @message.meta["status"] == "pending"}
        type="button"
        class="ed-btn ed-btn--ghost ed-btn--sm"
        phx-click="decline_join"
        phx-value-id={@message.id}
      >
        {gettext("Decline")}
      </button>
      <span :if={@message.meta["status"] == "accepted"} class="ed-sysmsg__done">
        {gettext("Added")}
      </span>
      <span :if={@message.meta["status"] == "declined"} class="ed-sysmsg__muted">
        {gettext("Declined")}
      </span>
    </div>
    """
  end

  # A Mattermost-style flat row (channel rooms + the thread panel): avatar ·
  # name · time on one line, content below, left-aligned for everyone.
  # Consecutive same-author messages collapse (virtual `compact`). Desktop
  # hover reveals quick actions; right-click/long-press opens the full menu.
  defp flat_message(assigns) do
    ~H"""
    <%!-- phx-hook must stay a LITERAL: colocated hook names are rewritten at
          compile time only in literal attributes — a dynamic string reaches
          the client as the unresolvable ".ContextMenu". Menu-less hosts
          (the thread panel root) are handled by the hook's missing-menu
          guard instead. --%>
    <div
      id={@id}
      class={["ed-flat", @message.compact && "ed-flat--compact"]}
      data-sender-id={@message.sender_id}
      data-ts={@message.inserted_at && DateTime.to_unix(@message.inserted_at)}
      data-client-id={@mine && @message.client_id}
      data-message-id={@menu && @message.id}
      data-reply-event={(@in_thread && "reply_in_thread") || "reply"}
      phx-hook=".ContextMenu"
      aria-haspopup={@menu && "menu"}
    >
      <div class="ed-flat__gutter">
        <button
          :if={!@message.compact && @message.sender}
          type="button"
          class="ed-flat__avatar-btn"
          data-profile-trigger
          phx-click="show_profile"
          phx-value-id={@message.sender_id}
          aria-label={gettext("View profile")}
        >
          <.avatar name={@message.sender.display_name} src={avatar_src(@message.sender)} size={:sm} />
        </button>
      </div>
      <div class="ed-flat__main">
        <div :if={!@message.compact} class="ed-flat__head">
          <button
            :if={@message.sender}
            type="button"
            class="ed-flat__name ed-flat__name-btn"
            data-profile-trigger
            phx-click="show_profile"
            phx-value-id={@message.sender_id}
          >
            {@message.sender.display_name}
          </button>
          <span :if={!@message.sender} class="ed-flat__name">{gettext("Deleted account")}</span>
          <span class="ed-flat__time"><.local_time at={@message.inserted_at} /></span>
        </div>
        <.quoted_reply message={@message} />
        <span :if={@message.forwarded_from} class="ed-forwarded">
          <.icon name="hero-arrow-uturn-right-micro" class="size-3" />
          {forwarded_label(@message.forwarded_from)}
        </span>
        <.album_view
          :if={@message.attachments != []}
          attachments={@message.attachments}
          message_id={@message.id}
        />
        <div :if={@message.body != ""} class="break-words ed-flat__body">
          {Markup.to_iodata(@message.body)}
        </div>
        <button
          :if={@message.reply_count > 0 and not @in_thread}
          type="button"
          class="ed-thread-footer"
          phx-click="open_thread"
          phx-value-id={@message.id}
        >
          <span class="ed-facepile">
            <.avatar
              :for={user <- Enum.reverse(@participants)}
              name={user.display_name}
              src={avatar_src(user)}
              size={:sm}
            />
          </span>
          <span class="ed-thread-footer__count">
            {ngettext("%{count} reply", "%{count} replies", @message.reply_count)}
          </span>
          <span
            :if={@thread_unread > 0}
            class="ed-thread-footer__new"
            aria-label={ngettext("%{count} unread reply", "%{count} unread replies", @thread_unread)}
          >
            {@thread_unread}
          </span>
          <span :if={@message.last_reply_at} class="ed-thread-footer__time">
            <.local_time at={@message.last_reply_at} />
          </span>
        </button>
        <.reactions message={@message} me={@me} />
      </div>
      <div :if={@menu} class="ed-flat__actions">
        <button
          :if={not @in_thread}
          type="button"
          class="ed-btn--icon"
          title={gettext("Reply in thread")}
          aria-label={gettext("Reply in thread")}
          phx-click="open_thread"
          phx-value-id={@message.id}
        >
          <.icon name="hero-chat-bubble-left-micro" class="size-4" />
        </button>
        <%!-- Quote-reply (#71): quick arrow, left of the "⋯" (rooms); in-thread it
              targets the thread composer. --%>
        <button
          type="button"
          class="ed-btn--icon"
          title={gettext("Reply")}
          aria-label={gettext("Reply")}
          phx-click={reply_js(@message.id, @in_thread)}
        >
          <.icon name="hero-arrow-uturn-left-micro" class="size-4" />
        </button>
        <button
          type="button"
          class="ed-btn--icon"
          data-menu-trigger
          title={gettext("More actions")}
          aria-label={gettext("More actions")}
        >
          <.icon name="hero-ellipsis-horizontal-mini" class="size-4" />
        </button>
      </div>
      <.message_menu
        :if={@menu}
        message={@message}
        conversation_id={@conversation_id}
        mine={@mine}
        me={@me}
        quick={@quick}
        in_thread={@in_thread}
        threads
      />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :message, :map, required: true
  attr :conversation_id, :any, required: true
  attr :mine, :boolean, required: true
  attr :me, :any, default: nil
  attr :quick, :list, default: []
  attr :group, :boolean, required: true
  attr :read, :boolean, required: true

  defp message_bubble(assigns) do
    ~H"""
    <%!-- data-client-id on MY own rows lets the rise-in observer skip them: the
          optimistic node already animated, so the real replacement swaps in
          silently (no double-animation / jerk). Others' messages still rise in. --%>
    <div
      id={@id}
      class={["ed-msg flex", @mine && "justify-end"]}
      data-client-id={@mine && @message.client_id}
      data-ts={@message.inserted_at && DateTime.to_unix(@message.inserted_at)}
    >
      <%!-- Bubble + reactions stack in a column so reactions hang UNDER the bubble
            (aligned to its side), not inside it (#107). Inside the bubble their chip
            outline + count blended into the bubble fill and read as a bare emoji. --%>
      <div class={["flex flex-col min-w-0", (@mine && "items-end") || "items-start"]}>
        <div
          class={["ed-bubble", (@mine && "ed-bubble--me") || "ed-bubble--them"]}
          id={"bubble-#{@message.id}"}
          data-message-id={@message.id}
          phx-hook=".ContextMenu"
          aria-haspopup="menu"
        >
          <span
            :if={@group and not @mine and @message.sender}
            class="block"
            style="font-size:0.75rem; font-weight:600; color: var(--ed-primary);"
          >
            {@message.sender.display_name}
          </span>
          <.quoted_reply message={@message} />
          <span :if={@message.forwarded_from} class="ed-forwarded">
            <.icon name="hero-arrow-uturn-right-micro" class="size-3" />
            {forwarded_label(@message.forwarded_from)}
          </span>
          <.album_view
            :if={@message.attachments != []}
            attachments={@message.attachments}
            message_id={@message.id}
          />
          <span :if={@message.body != ""} class="break-words">
            {Markup.to_iodata(@message.body)}
          </span>
          <span class="ed-bubble__meta">
            <.local_time at={@message.inserted_at} />
            <span :if={@mine and not @group} class="inline-flex items-center" style="margin-left:2px;">
              <.icon :if={not @read} name="hero-check-micro" class="size-3.5" />
              <span :if={@read} class="inline-flex items-center">
                <.icon name="hero-check-micro" class="size-3.5 -mr-2" />
                <.icon name="hero-check-micro" class="size-3.5" />
              </span>
            </span>
          </span>
          <%!-- No thread affordance in the personal messenger (#26): threads are
                a corporate-room feature only. --%>
          <.message_menu
            message={@message}
            conversation_id={@conversation_id}
            mine={@mine}
            me={@me}
            quick={@quick}
          />
        </div>
        <.reactions message={@message} me={@me} />
      </div>
    </div>
    """
  end

  attr :message, :map, required: true
  attr :conversation_id, :any, required: true
  attr :mine, :boolean, required: true
  attr :me, :any, default: nil
  # The viewer's personal quick-react row (the top of the menu).
  attr :quick, :list, default: []
  attr :in_thread, :boolean, default: false
  # Threads are a corporate-room feature only (#26) — off in the DM/group menu.
  attr :threads, :boolean, default: false

  # The message context menu — opened by right-click / long-press on the bubble
  # (the `.ContextMenu` hook). It opens with a Telegram-style quick-react row on
  # top (#67): tapping an emoji dispatches "react" and closes the menu, the "more"
  # chevron opens the shared full-emoji grid popover (#72, the `.ReactionGrid`
  # hook) anchored to it — carrying the viewer's current reactions in data-mine so
  # the grid can highlight them. Copy actions run client-side; forward/delete
  # dispatch to the LiveView.
  defp message_menu(assigns) do
    assigns = assign(assigns, :mine_emoji, mine_emoji(assigns.message, assigns.me))

    ~H"""
    <div class="ed-menu" id={"menu-#{@message.id}"} data-menu role="menu" hidden>
      <div class="ed-menu__reacts" role="group" aria-label={gettext("React")}>
        <button
          :for={e <- @quick}
          type="button"
          class={["ed-menu__react", e in @mine_emoji && "ed-menu__react--active"]}
          phx-click="react"
          phx-value-id={@message.id}
          phx-value-emoji={e}
          aria-pressed={to_string(e in @mine_emoji)}
        >
          {e}
        </button>
        <%!-- Opens the shared full-emoji grid (#72): one popover per page, not a
              39-button grid hidden inside every message's menu. --%>
        <button
          type="button"
          class="ed-menu__react ed-menu__react-more"
          data-react-expand
          data-mine={Enum.join(@mine_emoji, " ")}
          aria-label={gettext("More emoji")}
          aria-haspopup="menu"
        >
          <.icon name="hero-chevron-down-micro" class="size-4" />
        </button>
      </div>
      <div class="ed-menu__sep"></div>
      <%!-- Quote-reply (#71): in DMs and rooms; focuses the composer client-side.
            Inside the thread panel it targets the thread composer, so the reply
            stays in the thread. Distinct from "Reply in thread" (the branch). --%>
      <button
        type="button"
        class="ed-menu__item"
        role="menuitem"
        phx-click={reply_js(@message.id, @in_thread)}
      >
        <.icon name="hero-arrow-uturn-left-micro" class="size-4" /> {gettext("Reply")}
      </button>
      <button
        :if={@threads and not @in_thread and is_nil(@message.root_id)}
        type="button"
        class="ed-menu__item"
        role="menuitem"
        phx-click="open_thread"
        phx-value-id={@message.id}
      >
        <.icon name="hero-chat-bubble-left-micro" class="size-4" /> {gettext("Reply in thread")}
      </button>
      <button
        :if={@message.body != ""}
        type="button"
        class="ed-menu__item"
        role="menuitem"
        data-copy-text
        data-text={@message.body}
      >
        <.icon name="hero-clipboard-micro" class="size-4" /> {gettext("Copy text")}
      </button>
      <button
        type="button"
        class="ed-menu__item"
        role="menuitem"
        data-copy-link
        data-link={url(~p"/app/c/#{@conversation_id}/m/#{@message.id}")}
      >
        <.icon name="hero-link-micro" class="size-4" /> {gettext("Copy link")}
      </button>
      <button
        type="button"
        class="ed-menu__item"
        role="menuitem"
        phx-click="forward_prompt"
        phx-value-id={@message.id}
      >
        <.icon name="hero-arrow-uturn-right-micro" class="size-4" /> {gettext("Forward")}
      </button>
      <button
        type="button"
        class="ed-menu__item"
        role="menuitem"
        phx-click="delete_for_me"
        phx-value-id={@message.id}
      >
        <.icon name="hero-eye-slash-micro" class="size-4" /> {gettext("Delete for me")}
      </button>
      <button
        :if={@mine}
        type="button"
        class="ed-menu__item ed-menu__item--danger"
        role="menuitem"
        phx-click="delete_for_both"
        phx-value-id={@message.id}
        data-confirm={gettext("Delete this message for everyone?")}
      >
        <.icon name="hero-trash-micro" class="size-4" /> {gettext("Delete for everyone")}
      </button>
    </div>
    """
  end

  attr :upload, :any, required: true
  attr :form, :any, required: true

  # Telegram-style attachment compose modal (#58): a lightbox overlay that opens
  # the moment files are staged — a media grid (photos/videos) plus, separately,
  # any non-media files (they send as their own messages, never inside the
  # album). The caption + send live in the modal footer.
  defp compose_overlay(assigns) do
    entries = assigns.upload.entries
    media = Enum.filter(entries, &media_entry?/1)
    files = Enum.reject(entries, &media_entry?/1)

    assigns =
      assigns
      |> assign(:media, media)
      |> assign(:files, files)
      |> assign(:errs, compose_errors(assigns.upload))

    ~H"""
    <div
      class="ed-compose"
      data-upload-preview
      role="dialog"
      aria-modal="true"
      aria-label={gettext("Attachment preview")}
      phx-window-keydown="cancel_all_uploads"
      phx-key="Escape"
    >
      <div class="ed-compose__scrim" phx-click="cancel_all_uploads" aria-hidden="true"></div>
      <div class="ed-compose__panel">
        <header class="ed-compose__head">
          <button
            type="button"
            class="ed-btn--icon"
            phx-click="cancel_all_uploads"
            aria-label={gettext("Cancel")}
          >
            <.icon name="hero-x-mark-mini" class="size-5" />
          </button>
          <span class="ed-compose__title">{compose_title(@media, @files)}</span>
          <label class="ed-btn--icon cursor-pointer" aria-label={gettext("Add more")}>
            <.icon name="hero-plus-mini" class="size-5" />
            <.live_file_input upload={@upload} class="sr-only" />
          </label>
        </header>

        <div class="ed-compose__body">
          <div
            :if={@media != []}
            class={["ed-compose__grid", "ed-album--#{album_cols(length(@media))}"]}
          >
            <div :for={entry <- @media} class="ed-compose__tile">
              <.live_img_preview :if={image_entry?(entry)} entry={entry} class="ed-compose__img" />
              <span :if={video_entry?(entry)} class="ed-compose__video" aria-hidden="true">
                <.icon name="hero-film" class="size-7" />
              </span>
              <button
                type="button"
                class="ed-compose__remove"
                phx-click="cancel_upload"
                phx-value-ref={entry.ref}
                aria-label={gettext("Remove %{name}", name: entry.client_name)}
              >
                <.icon name="hero-x-mark-micro" class="size-3.5" />
              </button>
              <progress
                :if={entry.progress > 0 and entry.progress < 100}
                value={entry.progress}
                max="100"
                class="ed-compose__bar"
              />
            </div>
          </div>

          <div :if={@files != []} class="ed-compose__files">
            <p class="ed-compose__files-note">
              {gettext("Files send as separate messages.")}
            </p>
            <div :for={entry <- @files} class="ed-attach-file">
              <span class="ed-file-chip shrink-0" aria-hidden="true">
                <.icon name={entry_icon(entry)} class="size-5" />
              </span>
              <span class="flex-1 min-w-0">
                <span class="block truncate" style="font-size:0.8125rem;">{entry.client_name}</span>
                <span class="block" style="font-size:0.75rem; color: var(--ed-muted);">
                  {human_size(entry.client_size)}
                </span>
              </span>
              <button
                type="button"
                class="ed-btn--icon shrink-0"
                phx-click="cancel_upload"
                phx-value-ref={entry.ref}
                aria-label={gettext("Remove %{name}", name: entry.client_name)}
              >
                <.icon name="hero-x-mark-mini" class="size-5" />
              </button>
            </div>
          </div>

          <p :for={{name, err} <- @errs} class="ed-attach-err">
            {name}: {upload_error_text(err)}
          </p>
        </div>

        <footer class="ed-compose__foot">
          <input
            type="text"
            id="composer-body"
            name="message[body]"
            value={@form[:body].value}
            class="ed-input"
            placeholder={gettext("Add a caption…")}
            autocomplete="off"
            phx-hook=".PasteUpload"
            phx-mounted={JS.focus()}
          />
          <button
            class="ed-btn ed-btn--primary shrink-0"
            style="width:2.5rem; padding:0; border-radius:var(--ed-radius-full);"
            type="submit"
            aria-label={gettext("Send")}
          >
            <.icon name="hero-paper-airplane-micro" class="size-4" />
          </button>
        </footer>
      </div>
    </div>
    """
  end

  # Upload errors flattened to {entry_name, error} pairs for the modal footer.
  defp compose_errors(upload) do
    Enum.flat_map(upload.entries, fn entry ->
      Enum.map(upload_errors(upload, entry), &{entry.client_name, &1})
    end)
  end

  # Modal title: counts the media (the album) when present, else the files. A
  # media-only set reads by its kind — "N videos" when there are no photos.
  defp compose_title(media, []) when media != [] do
    n = length(media)

    if Enum.any?(media, &image_entry?/1),
      do: ngettext("%{count} photo", "%{count} photos", n),
      else: ngettext("%{count} video", "%{count} videos", n)
  end

  defp compose_title([], files),
    do: ngettext("%{count} file", "%{count} files", length(files))

  defp compose_title(media, files),
    do: ngettext("%{count} attachment", "%{count} attachments", length(media) + length(files))

  attr :attachments, :list, required: true
  attr :message_id, :any, required: true

  # A message's attachments (#58). One renders exactly as before; several render
  # as a media grid (images as lightbox tiles, sharing a gallery so the lightbox
  # can page through them) followed by any videos/files stacked as full items.
  defp album_view(%{attachments: [single]} = assigns) do
    assigns = assign(assigns, :attachment, single)

    ~H"""
    <.attachment_view attachment={@attachment} />
    """
  end

  defp album_view(assigns) do
    media = Enum.filter(assigns.attachments, &(&1.kind in ~w(image video)))

    assigns =
      assigns
      |> assign(:media, media)
      |> assign(:rest, assigns.attachments -- media)
      |> assign(:gallery, "album-#{assigns.message_id}")

    ~H"""
    <div :if={@media != []} class={["ed-album mb-1", "ed-album--#{album_cols(length(@media))}"]}>
      <%!-- Image tiles share a gallery so the lightbox pages them together. The
            phx-hook must be a LITERAL string — a dynamic value skips the
            compile-time colocated-hook rewrite (client: "unknown hook"). --%>
      <%= for item <- @media do %>
        <a
          :if={item.kind == "image"}
          id={"att-#{item.id}"}
          phx-hook=".Lightbox"
          data-full={~p"/files/#{item.id}"}
          data-gallery={@gallery}
          href={~p"/files/#{item.id}"}
          target="_blank"
          rel="noopener"
          class="ed-album__tile cursor-zoom-in"
        >
          <img src={thumb_src(item)} loading="lazy" alt={item.filename || gettext("Photo")} />
        </a>
        <%!-- A video is a poster tile with a play badge that opens the clip; no
              poster yet (worker pending) gets a neutral fill, never the raw
              bytes piped into an <img>. --%>
        <a
          :if={item.kind == "video"}
          id={"att-#{item.id}"}
          href={~p"/files/#{item.id}"}
          target="_blank"
          rel="noopener"
          aria-label={item.filename || gettext("Video")}
          class="ed-album__tile"
        >
          <img
            :if={item.thumbnail_key}
            src={thumb_src(item)}
            loading="lazy"
            alt={item.filename || gettext("Video")}
          />
          <span :if={is_nil(item.thumbnail_key)} class="ed-album__tile-fill" />
          <span class="ed-album__play" aria-hidden="true">
            <.icon name="hero-play-solid" class="size-6" />
          </span>
        </a>
      <% end %>
    </div>
    <.attachment_view :for={attachment <- @rest} attachment={attachment} />
    """
  end

  # Album grid columns by image count: a pair stays 2-up, a trio 3-up, a quad is
  # a 2x2, larger sets settle on a 3-column grid (rows fill left to right).
  defp album_cols(1), do: 1
  defp album_cols(2), do: 2
  defp album_cols(3), do: 3
  defp album_cols(4), do: 2
  defp album_cols(_n), do: 3

  attr :attachment, :map, required: true
  attr :gallery, :string, default: nil

  # Renders an attachment by kind: a lightbox-able image, an in-app video player,
  # or a download card for a generic file.
  defp attachment_view(%{attachment: %{kind: "image"}} = assigns) do
    ~H"""
    <a
      id={"att-#{@attachment.id}"}
      phx-hook=".Lightbox"
      data-full={~p"/files/#{@attachment.id}"}
      data-gallery={@gallery}
      href={~p"/files/#{@attachment.id}"}
      target="_blank"
      rel="noopener"
      class="block mb-1 cursor-zoom-in"
    >
      <img
        src={thumb_src(@attachment)}
        width={@attachment.width}
        height={@attachment.height}
        class="rounded-[0.6rem] block"
        style={img_box(@attachment)}
        loading="lazy"
        alt={gettext("Photo")}
      />
    </a>
    """
  end

  defp attachment_view(%{attachment: %{kind: "video"}} = assigns) do
    ~H"""
    <video
      controls
      preload="metadata"
      poster={@attachment.thumbnail_key && ~p"/files/#{@attachment.id}/thumb"}
      aria-label={@attachment.filename || gettext("Video")}
      class="ed-video mb-1"
      style={video_ratio(@attachment)}
    >
      <source src={~p"/files/#{@attachment.id}"} type={@attachment.content_type} />
    </video>
    """
  end

  defp attachment_view(assigns) do
    ~H"""
    <a
      href={~p"/files/#{@attachment.id}"}
      download
      class="ed-file mb-1"
      aria-label={gettext("Download %{name}", name: @attachment.filename || gettext("file"))}
    >
      <span class="ed-file__icon" aria-hidden="true">
        <.icon name="hero-document-arrow-down-micro" class="size-5" />
      </span>
      <span class="ed-file__meta">
        <span class="ed-file__name">{@attachment.filename || gettext("File")}</span>
        <span class="ed-file__size">{human_size(@attachment.byte_size)}</span>
      </span>
    </a>
    """
  end

  attr :people, :list, required: true

  defp new_conversation_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-30">
      <button
        class="absolute inset-0 w-full h-full"
        style="background: oklch(0 0 0 / 0.55);"
        phx-click="close_new"
        aria-label={gettext("Close")}
        tabindex="-1"
      >
      </button>
      <div class="absolute inset-0 grid place-items-center p-4 pointer-events-none">
        <div
          class="w-full max-w-sm rounded-[var(--ed-radius-lg)] border p-5 space-y-4 pointer-events-auto"
          style="background: var(--ed-surface); border-color: var(--ed-border);"
          phx-window-keydown="close_new"
          phx-key="Escape"
          role="dialog"
          aria-modal="true"
        >
          <div class="flex items-center justify-between">
            <h2 style="font-weight:600;">{gettext("New conversation")}</h2>
            <button class="ed-btn--icon" phx-click="close_new" aria-label={gettext("Close")}>
              <.icon name="hero-x-mark-mini" class="size-5" />
            </button>
          </div>

          <%= if @people == [] do %>
            <p style="color: var(--ed-muted); font-size:0.875rem;">
              {gettext("No one else has joined yet.")}
            </p>
          <% else %>
            <form phx-submit="start" class="space-y-3">
              <input
                type="text"
                name="title"
                class="ed-input"
                placeholder={gettext("Group name (optional)")}
                autocomplete="off"
              />
              <div class="max-h-60 overflow-y-auto space-y-0.5">
                <label
                  :for={u <- @people}
                  class="flex items-center gap-3 p-2 rounded-[var(--ed-radius)] cursor-pointer"
                >
                  <input type="checkbox" name="member_ids[]" value={u.id} class="size-4" />
                  <.avatar name={u.display_name} src={avatar_src(u)} size={:sm} />
                  <span class="flex-1 min-w-0">
                    <span class="block" style="font-weight:550; font-size:0.875rem;">
                      {u.display_name}
                    </span>
                    <span class="block" style="color: var(--ed-muted); font-size:0.75rem;">
                      @{u.username}
                    </span>
                  </span>
                </label>
              </div>
              <button class="ed-btn ed-btn--primary w-full" type="submit">{gettext("Start")}</button>
            </form>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr :targets, :list, required: true
  attr :user, :map, required: true
  attr :online_ids, :any, required: true

  # Pick a conversation to forward the pending message into.
  defp forward_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-30">
      <button
        class="absolute inset-0 w-full h-full"
        style="background: oklch(0 0 0 / 0.55);"
        phx-click="close_forward"
        aria-label={gettext("Close")}
        tabindex="-1"
      >
      </button>
      <div class="absolute inset-0 grid place-items-center p-4 pointer-events-none">
        <div
          class="w-full max-w-sm rounded-[var(--ed-radius-lg)] border p-5 space-y-4 pointer-events-auto"
          style="background: var(--ed-surface); border-color: var(--ed-border);"
          phx-window-keydown="close_forward"
          phx-key="Escape"
          role="dialog"
          aria-modal="true"
        >
          <div class="flex items-center justify-between">
            <h2 style="font-weight:600;">{gettext("Forward to")}</h2>
            <button class="ed-btn--icon" phx-click="close_forward" aria-label={gettext("Close")}>
              <.icon name="hero-x-mark-mini" class="size-5" />
            </button>
          </div>

          <p :if={@targets == []} style="color: var(--ed-muted); font-size:0.875rem;">
            {gettext("No conversations yet.")}
          </p>
          <div class="max-h-72 overflow-y-auto space-y-0.5">
            <button
              :for={c <- @targets}
              type="button"
              class="flex w-full items-center gap-3 p-2 rounded-[var(--ed-radius)] text-left transition-colors hover:bg-[var(--ed-bg)]"
              phx-click="forward"
              phx-value-target={c.id}
            >
              <.avatar
                name={title(c, @user)}
                src={avatar_src(peer(c, @user))}
                online={online?(c, @user, @online_ids)}
                size={:sm}
              />
              <span class="flex-1 min-w-0 truncate" style="font-weight:550; font-size:0.875rem;">
                {title(c, @user)}
              </span>
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :folders, :list, required: true
  attr :checked, :any, required: true

  # Move-to-folder sheet: toggle the chat's membership in each folder. Changes
  # apply immediately (each tap dispatches a toggle); "All Chats" is virtual and
  # not listed. Folders are created/managed in Settings.
  defp folder_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-30">
      <button
        class="absolute inset-0 w-full h-full"
        style="background: oklch(0 0 0 / 0.55);"
        phx-click="close_folders"
        aria-label={gettext("Close")}
        tabindex="-1"
      >
      </button>
      <div class="absolute inset-0 grid place-items-center p-4 pointer-events-none">
        <div
          class="w-full max-w-sm rounded-[var(--ed-radius-lg)] border p-5 space-y-4 pointer-events-auto"
          style="background: var(--ed-surface); border-color: var(--ed-border);"
          phx-window-keydown="close_folders"
          phx-key="Escape"
          role="dialog"
          aria-modal="true"
        >
          <div class="flex items-center justify-between">
            <h2 style="font-weight:600;">{gettext("Move to folder")}</h2>
            <button class="ed-btn--icon" phx-click="close_folders" aria-label={gettext("Close")}>
              <.icon name="hero-x-mark-mini" class="size-5" />
            </button>
          </div>

          <div :if={@folders == []} class="space-y-3 text-center py-2">
            <p style="color: var(--ed-muted); font-size:0.875rem;">
              {gettext("You don't have any folders yet.")}
            </p>
            <.link navigate={~p"/settings"} class="ed-btn ed-btn--primary inline-flex">
              <.icon name="hero-cog-6-tooth-micro" class="size-4" /> {gettext("Manage folders")}
            </.link>
          </div>

          <div :if={@folders != []} class="max-h-72 overflow-y-auto space-y-0.5">
            <button
              :for={folder <- @folders}
              type="button"
              class="flex w-full items-center gap-3 p-2 rounded-[var(--ed-radius)] text-left transition-colors hover:bg-[var(--ed-bg)]"
              phx-click="toggle_folder"
              phx-value-folder={folder.id}
              aria-pressed={to_string(MapSet.member?(@checked, folder.id))}
            >
              <span class={[
                "ed-check",
                MapSet.member?(@checked, folder.id) && "ed-check--on"
              ]}>
                <.icon
                  :if={MapSet.member?(@checked, folder.id)}
                  name="hero-check-mini"
                  class="size-4"
                />
              </span>
              <span class="flex-1 min-w-0 truncate" style="font-weight:550; font-size:0.875rem;">
                {folder.name}
              </span>
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp forwarded_label(%{sender: %{display_name: name}}),
    do: gettext("Forwarded from %{name}", name: name)

  defp forwarded_label(_forwarded_from), do: gettext("Forwarded")

  attr :user, :map, required: true
  attr :online, :boolean, required: true
  attr :self, :boolean, default: false

  # A light profile popover anchored at the clicked avatar/name (a bottom sheet
  # on mobile). Opened from message rows, the chat header peer, and member
  # lists. Own card shows an "Edit profile" link instead of "Message".
  defp profile_popover(assigns) do
    ~H"""
    <div>
      <button
        class="ed-popover__scrim"
        phx-click="close_profile"
        aria-label={gettext("Close")}
        tabindex="-1"
      >
      </button>
      <div
        id="profile-popover"
        class="ed-popover"
        phx-hook=".Popover"
        phx-window-keydown="close_profile"
        phx-key="Escape"
        role="dialog"
        aria-modal="true"
        aria-label={gettext("Profile")}
        tabindex="-1"
      >
        <div class="flex flex-col items-center text-center">
          <.avatar name={@user.display_name} src={avatar_src(@user)} online={@online} size={:lg} />
          <h2 class="mt-3 font-semibold" style="font-size:1.0625rem;">{@user.display_name}</h2>
          <p style="color: var(--ed-muted); font-size:0.8125rem;">@{@user.username}</p>
          <p
            class="mt-0.5"
            style={"font-size:0.75rem; color: var(#{if @online, do: "--ed-online", else: "--ed-muted"});"}
          >
            {if @online, do: gettext("online"), else: gettext("offline")}
          </p>

          <p
            :if={@user.bio}
            class="mt-4 whitespace-pre-line break-words text-left w-full"
            style="font-size:0.875rem; color: var(--ed-ink);"
          >
            {@user.bio}
          </p>
        </div>

        <.link
          :if={@self}
          navigate={~p"/settings"}
          class="ed-btn ed-btn--ghost w-full mt-6 justify-center"
        >
          <.icon name="hero-pencil-square-micro" class="size-4" /> {gettext("Edit profile")}
        </.link>
        <button
          :if={!@self}
          class="ed-btn ed-btn--primary w-full mt-6"
          phx-click="message_user"
          phx-value-id={@user.id}
        >
          <.icon name="hero-chat-bubble-oval-left-micro" class="size-4" /> {gettext("Message")}
        </button>
      </div>
    </div>
    """
  end

  attr :conversation, :map, required: true
  attr :user, :map, required: true
  attr :online_ids, :any, required: true

  # Group member list: tap a member to open their profile (tapping yourself
  # routes to Settings, handled by show_profile).
  defp members_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-30">
      <button
        class="absolute inset-0 w-full h-full"
        style="background: oklch(0 0 0 / 0.55);"
        phx-click="close_members"
        aria-label={gettext("Close")}
        tabindex="-1"
      >
      </button>
      <div class="absolute inset-0 grid place-items-center p-4 pointer-events-none">
        <div
          class="w-full max-w-sm rounded-[var(--ed-radius-lg)] border p-5 space-y-4 pointer-events-auto"
          style="background: var(--ed-surface); border-color: var(--ed-border);"
          phx-window-keydown="close_members"
          phx-key="Escape"
          role="dialog"
          aria-modal="true"
        >
          <div class="flex items-center justify-between">
            <h2 style="font-weight:600;">{gettext("Members")}</h2>
            <button class="ed-btn--icon" phx-click="close_members" aria-label={gettext("Close")}>
              <.icon name="hero-x-mark-mini" class="size-5" />
            </button>
          </div>

          <div class="max-h-72 overflow-y-auto space-y-0.5">
            <button
              :for={m <- @conversation.memberships}
              type="button"
              class="flex w-full items-center gap-3 p-2 rounded-[var(--ed-radius)] text-left transition-colors hover:bg-[var(--ed-bg)]"
              data-profile-trigger
              phx-click="show_profile"
              phx-value-id={m.user.id}
            >
              <.avatar
                name={m.user.display_name}
                src={avatar_src(m.user)}
                online={MapSet.member?(@online_ids, m.user.id)}
                size={:sm}
              />
              <span class="flex-1 min-w-0">
                <span class="block truncate" style="font-weight:550; font-size:0.875rem;">
                  {m.user.display_name}{if m.user.id == @user.id, do: " " <> gettext("(you)")}
                </span>
                <span class="block truncate" style="color: var(--ed-muted); font-size:0.75rem;">
                  @{m.user.username}
                </span>
              </span>
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :typers, :map, required: true

  # The "… is typing" row — shared by the room composer and the thread panel (#103).
  defp typing_row(assigns) do
    ~H"""
    <div :if={@typers != %{}} class="ed-typing-row" aria-live="polite">
      <span class="ed-typing" aria-hidden="true"><span></span><span></span><span></span></span>
      <span class="ed-typing-row__label">{typing_label(@typers)}</span>
    </div>
    """
  end

  # A timestamp that the browser reformats to the viewer's local time (the
  # server-rendered text is a UTC fallback shown before JS runs).
  attr :at, :any, required: true
  attr :class, :string, default: nil

  defp local_time(assigns) do
    ~H"""
    <time
      class={@class}
      phx-hook=".LocalTime"
      id={"t-#{System.unique_integer([:positive])}"}
      datetime={DateTime.to_iso8601(@at)}
    >
      {Calendar.strftime(@at, "%H:%M")}
    </time>
    """
  end

  ## Helpers

  defp select_conversation(socket, conversation) do
    scope = socket.assigns.current_scope
    socket = unsubscribe(socket)
    Chat.subscribe(conversation.id)
    Chat.mark_read(scope, conversation.id)

    {:ok, messages} = Chat.list_messages(scope, conversation.id, limit: @page)
    # Room flat layout: collapse consecutive same-author runs + facepiles.
    {messages, last_flat} = mark_compact(messages, conversation)

    socket
    # Drop chat A's staged attachments before opening B — they belong to the
    # conversation they were composed in; otherwise they ride into the new
    # composer and a send would attach them to the wrong chat (#89, with the
    # text-draft reset below).
    |> cancel_staged_attachments()
    |> assign(
      selected: conversation,
      subscribed_id: conversation.id,
      other_read_at: other_read_at(conversation, scope.user),
      has_more: length(messages) == @page,
      oldest_id: messages |> List.first() |> then(&(&1 && &1.id)),
      oldest_msg: List.first(messages),
      thread_root: nil,
      # The composer is per-conversation: reset it so a draft/last-sent body from
      # the previous chat doesn't reappear in this one's input (#89). The input
      # binds to @composer[:body].value, which otherwise keeps the stale text.
      composer: empty_composer(),
      # Drop any staged quote-reply (#71) — its target is the old conversation's.
      reply_to: nil,
      thread_reply_to: nil,
      # Thread following (#57) is per-room: reset the panel + seed the per-thread
      # unread badges from the DB for the room just opened.
      thread_following: false,
      thread_list_open: false,
      thread_list: [],
      # Threads are rooms-only — skip the (always-empty) query for DMs/groups.
      thread_unreads:
        if(conversation.channel_id,
          do: Chat.thread_unread_counts(scope, conversation.id),
          else: %{}
        ),
      last_flat: last_flat,
      thread_last_flat: nil,
      compacts: Map.new(messages, &{&1.id, &1.compact}),
      thread_participants: facepiles(scope, conversation, messages),
      # In-room search is per-room state — closed on every selection.
      room_search_open: false,
      room_search: "",
      room_results: nil
    )
    |> stream(:thread, [], reset: true)
    |> stream(:messages, messages, reset: true)
    # Re-stream the sidebar so the active highlight follows the selection (stream
    # items don't re-render on assign changes) and the opened conversation's
    # unread badge clears. In channel mode the rooms list plays that role —
    # without the refresh, an opened room kept its stale unread badge.
    |> refresh_sidebar()
    |> refresh_rooms()
    # Reading a room clears its unread, which lowers the channel's rail badge.
    |> then(fn s -> if conversation.channel_id, do: refresh_rail(s), else: s end)
  end

  defp refresh_sidebar(socket), do: stream_conversations(socket, reset: true)

  # Re-stream the conversation list honoring the active folder filter.
  # No-op in channel mode: the DM stream's container isn't rendered there, so
  # stream operations would target a missing element.
  defp stream_conversations(socket, opts) do
    if socket.assigns.channel do
      socket
    else
      user = socket.assigns.current_scope.user
      convos = Chat.list_conversations(socket.assigns.current_scope, socket.assigns.folder_id)
      # Remember the DM peers on display so presence_diff can skip a re-query when
      # no peer's status changed (#94 review). Groups have no peer/dot → excluded.
      peers = for c <- convos, p = peer(c, user), not is_nil(p), do: p.id

      socket
      |> assign(sidebar_peer_ids: peers)
      |> stream(:conversations, convos, opts)
    end
  end

  # User ids whose presence changed in a `presence_diff` payload (keys are the
  # tracked user ids as strings). Empty for a payload without joins/leaves.
  defp presence_changed_ids(%{joins: joins, leaves: leaves}),
    do: Enum.map(Map.keys(joins) ++ Map.keys(leaves), &String.to_integer/1)

  defp presence_changed_ids(_), do: []

  defp refresh_folders(socket) do
    scope = socket.assigns.current_scope
    folders = Chat.list_folders(scope)
    ids = Enum.map(folders, & &1.id)
    folder_id = if socket.assigns.folder_id in ids, do: socket.assigns.folder_id, else: nil

    assign(socket,
      folders: folders,
      folder_id: folder_id,
      folder_tabs: List.insert_at(folders, Chat.all_chats_position(scope), :all)
    )
  end

  # Insert/refresh one conversation in the sidebar, honoring the active folder:
  # drop it from the view if it isn't in the selected folder. Room activity
  # never touches the DM stream — it refreshes the channel sidebar instead.
  defp put_sidebar_conversation(socket, conversation_id, insert_opts \\ []) do
    scope = socket.assigns.current_scope

    case Chat.get_conversation_summary(scope, conversation_id) do
      # DM activity only touches the stream when its container is rendered.
      {:ok, %{channel_id: nil}} when not is_nil(socket.assigns.channel) ->
        socket

      {:ok, %{channel_id: nil} = summary} ->
        fid = socket.assigns.folder_id

        if is_nil(fid) or fid in Chat.conversation_folder_ids(scope, conversation_id) do
          stream_insert(socket, :conversations, summary, insert_opts)
        else
          stream_delete_by_dom_id(socket, :conversations, "conversations-#{conversation_id}")
        end

      {:ok, _room} ->
        # Badge refresh if we're looking at this room's channel; cross-channel
        # rail badges arrive with #32.
        refresh_rooms_if_current(socket, conversation_id)

      {:error, _} ->
        socket
    end
  end

  defp refresh_rooms_if_current(socket, conversation_id) do
    if socket.assigns.channel && Enum.any?(socket.assigns.rooms, &(&1.id == conversation_id)) do
      refresh_rooms(socket)
    else
      socket
    end
  end

  defp refresh_rooms(socket) do
    case socket.assigns.channel do
      nil ->
        socket

      channel ->
        assign(socket, rooms: Chat.list_rooms(socket.assigns.current_scope, channel.id))
    end
  end

  # The visibility picker hides when renaming general — the Town Square is
  # always open (the changeset guard enforces it server-side too).
  defp room_modal_visibility?({:rename, room_id}, rooms) do
    case Enum.find(rooms, &(&1.id == room_id)) do
      %{is_general: true} -> false
      _ -> true
    end
  end

  defp room_modal_visibility?(_modal, _rooms), do: true

  # nil (not []) for a blank query: the templates gate the search views on the
  # trimmed query, and nil keeps "not searching" distinct from "no matches".
  defp run_room_search(socket, search_scope, q) do
    if String.trim(q) == "" do
      nil
    else
      Chat.search_rooms(socket.assigns.current_scope, search_scope, q)
    end
  end

  # A pending knock was approved while its window is open: the room now appears
  # in the sidebar — clear the knock window so the user can open it.
  defp maybe_clear_knock(%{assigns: %{knock_room: %{id: id}}} = socket) do
    if Chat.room_member?(id, socket.assigns.current_scope.user.id) do
      assign(socket, knock_room: nil, knock_pending: false)
    else
      socket
    end
  end

  defp maybe_clear_knock(socket), do: socket

  # Recompute the rail's per-channel unread badges (the channel list carries
  # the aggregate). Called when room activity arrives or a room is read.
  defp refresh_rail(socket) do
    assign(socket, channels: Channels.list_channels(socket.assigns.current_scope))
  end

  defp refresh_channel_access(socket, channel_id) do
    case Channels.get_channel(socket.assigns.current_scope, channel_id) do
      {:ok, channel} ->
        socket |> assign(channel: channel) |> maybe_refresh_members(channel_id)

      {:error, :not_found} ->
        # Removal is announced separately; just stop touching this channel.
        socket
    end
  end

  defp maybe_refresh_members(socket, channel_id) do
    if socket.assigns.members_open do
      case Channels.list_members(socket.assigns.current_scope, channel_id) do
        {:ok, members} -> assign(socket, members: members)
        _ -> socket
      end
    else
      socket
    end
  end

  # Tolerates a role lost mid-flight (list_invites turning :forbidden).
  defp refresh_invites(socket) do
    case Channels.list_invites(socket.assigns.current_scope, socket.assigns.channel.id) do
      {:ok, invites} -> assign(socket, invites: invites)
      {:error, _} -> assign(socket, invites_open: false)
    end
  end

  ## Threads + flat room layout helpers

  # Consecutive same-author messages within this window collapse (no repeated
  # avatar/name) in the room flat layout — the Mattermost grouping.
  @compact_window_s 300

  # Marks each message's virtual `compact` flag and returns the run tracker
  # for live appends. DMs keep bubbles — no marking there.
  defp mark_compact(messages, %{channel_id: nil}), do: {messages, nil}

  defp mark_compact(messages, _room) do
    Enum.map_reduce(messages, nil, fn message, prev ->
      {%{message | compact: compact?(message, prev)}, {message.sender_id, message.inserted_at}}
    end)
  end

  defp compact?(message, {sender_id, ts}) do
    message.sender_id == sender_id and
      DateTime.diff(message.inserted_at, ts) < @compact_window_s
  end

  defp compact?(_message, nil), do: false

  # Continue/break the thread panel's compact run for a live reply (#105), mirroring
  # the main stream's last_flat logic. Threads are rooms-only, so always flat.
  defp mark_thread_compact(socket, reply) do
    marked = %{reply | compact: compact?(reply, socket.assigns.thread_last_flat)}
    {marked, assign(socket, thread_last_flat: {reply.sender_id, reply.inserted_at})}
  end

  # Re-streaming a row (reaction/thumbnail) loses the virtual compact flag (the
  # broadcast struct doesn't carry it); restore it from what we recorded when the
  # row was first streamed so the flat layout stays put.
  defp restore_compact(socket, message),
    do: %{message | compact: Map.get(socket.assigns.compacts, message.id, message.compact)}

  # After paging in an older batch, the message that WAS the on-screen top may now
  # continue the newest older message's run — recompute its compact flag and
  # re-stream it so the seam doesn't show a stray avatar/name (#105). DMs use
  # bubbles, so there's nothing to stitch.
  defp restitch_seam(socket, %{channel_id: nil}, _older), do: socket

  defp restitch_seam(socket, _room, older) do
    case socket.assigns.oldest_msg do
      %{} = top ->
        newest_older = List.last(older)
        compact = compact?(top, {newest_older.sender_id, newest_older.inserted_at})

        if compact == top.compact do
          socket
        else
          stitched = %{top | compact: compact}

          socket
          |> stream_insert(:messages, stitched)
          |> assign(compacts: Map.put(socket.assigns.compacts, stitched.id, compact))
        end

      _ ->
        socket
    end
  end

  # Apply a {:reaction_changed, message} to the right stream. A top-level message
  # / thread root lives in the main stream (refresh the panel head too when this
  # root's thread is open); a reply lives only in the thread panel — re-rendered
  # only when its thread is the one open (matched by sharing root_id with the open
  # root), never the main stream. Any other reply is a no-op for this view.
  # A tombstone reaching here (a reaction that raced a delete-for-both) must not
  # be re-inserted — {:message_deleted} already removed the row.
  defp apply_reaction_change(socket, %{deleted_at: deleted} = _message, _root)
       when not is_nil(deleted),
       do: socket

  defp apply_reaction_change(socket, %{root_id: nil} = message, root) do
    socket = stream_insert(socket, :messages, restore_compact(socket, message))
    if root && root.id == message.id, do: assign(socket, thread_root: message), else: socket
  end

  defp apply_reaction_change(socket, %{root_id: root_id} = message, %{id: root_id}),
    do: stream_insert(socket, :thread, message)

  defp apply_reaction_change(socket, _message, _root), do: socket

  defp facepiles(_scope, %{channel_id: nil}, _messages), do: %{}

  defp facepiles(scope, room, messages) do
    root_ids = for m <- messages, m.reply_count > 0, do: m.id
    Chat.thread_participants(scope, room.id, root_ids)
  end

  # A reply arrived: bump the facepile locally (no query) — newest first, capped.
  defp bump_facepile(socket, root_id, sender) do
    participants =
      [sender | Map.get(socket.assigns.thread_participants, root_id, [])]
      |> Enum.uniq_by(& &1.id)
      |> Enum.take(5)

    assign(
      socket,
      :thread_participants,
      Map.put(socket.assigns.thread_participants, root_id, participants)
    )
  end

  defp thread_open_for?(socket, root_id) do
    match?(%{id: ^root_id}, socket.assigns.thread_root)
  end

  # The open panel's root was deleted (for both) or hidden (for me): the panel
  # would keep showing the stale root forever — close it instead.
  defp close_thread_if_root_gone(socket, message_id) do
    if thread_open_for?(socket, message_id) do
      assign(socket, thread_root: nil)
    else
      socket
    end
  end

  # Permalinks may point at a reply — those live in the thread panel, not the
  # main stream, so open the thread first and focus inside it.
  defp focus_message_target(socket, message_id) do
    case Chat.thread_root_for(socket.assigns.current_scope, message_id) do
      {:ok, root_id} ->
        socket
        |> open_thread(root_id)
        |> push_event("focus_message", %{domId: "thread-#{message_id}"})

      _ ->
        push_event(socket, "focus_message", %{domId: "messages-#{message_id}"})
    end
  end

  defp open_thread(socket, root_id) do
    scope = socket.assigns.current_scope

    case Chat.list_thread(scope, root_id) do
      {:ok, root, replies} ->
        # Opening a thread reads it: clear the unread (server + the local badge)
        # and surface the follow state in the header bell.
        Chat.mark_thread_read(scope, root.id)
        %{following: following} = Chat.thread_follow_state(scope, root.id)
        # Collapse consecutive same-author replies, same as the main flat stream,
        # so the panel doesn't repeat avatar+name on every reply (#105).
        {replies, thread_last_flat} = mark_compact(replies, socket.assigns.selected)

        socket
        |> assign(
          thread_root: root,
          thread_following: following,
          thread_unreads: Map.put(socket.assigns.thread_unreads, root.id, 0),
          thread_last_flat: thread_last_flat,
          reply_composer: to_form(%{"body" => ""}, as: "reply"),
          # Fresh thread → no stale typers from a previously-open one (#103).
          thread_typing_users: %{},
          last_thread_typing_at: nil
        )
        |> stream(:thread, replies, reset: true)
        |> restream_root_if_loaded(root)

      {:error, _} ->
        put_flash(socket, :error, gettext("Thread not found."))
    end
  end

  # Set one thread's unread badge from the authoritative server state — drops the
  # key when the viewer doesn't follow. Keeps the local map in lockstep with the
  # DB across every lifecycle event (new reply, reply delete), not just guesses.
  defp sync_thread_unread(socket, root_id) do
    %{following: following, unread: unread} =
      Chat.thread_follow_state(socket.assigns.current_scope, root_id)

    unreads =
      if following,
        do: Map.put(socket.assigns.thread_unreads, root_id, unread),
        else: Map.delete(socket.assigns.thread_unreads, root_id)

    assign(socket, :thread_unreads, unreads)
  end

  # Re-stream a root ONLY when it's in the loaded message window (tracked by the
  # `compacts` map). The `:messages` stream is unbounded with manual paging, so
  # inserting a paged-out root would resurrect it out of order at the stream end.
  defp restream_root_if_loaded(socket, root) do
    if Map.has_key?(socket.assigns.compacts, root.id),
      do: stream_insert(socket, :messages, restore_compact(socket, root)),
      else: socket
  end

  # Reload the Threads list panel when it's open (cheap; only while shown).
  defp refresh_thread_list(socket) do
    if socket.assigns.thread_list_open and socket.assigns.selected do
      assign(
        socket,
        :thread_list,
        Chat.list_followed_threads(socket.assigns.current_scope, socket.assigns.selected.id)
      )
    else
      socket
    end
  end

  # How many followed threads carry unread replies — the toolbar badge.
  defp unread_thread_count(unreads), do: Enum.count(unreads, fn {_id, n} -> n > 0 end)

  defp parse_folder_id(""), do: nil

  defp parse_folder_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end

  # When the updated user is a member of the open conversation, re-preload its
  # members (header/title/member-list) and, for a group, re-stream messages so
  # bubble sender labels pick up the new name.
  defp refresh_selected_for(%{assigns: %{selected: %{} = conv}} = socket, user) do
    if Enum.any?(conv.memberships, &(&1.user_id == user.id)) do
      reload_selected(socket, conv)
    else
      socket
    end
  end

  defp refresh_selected_for(socket, _user), do: socket

  defp reload_selected(socket, conv) do
    scope = socket.assigns.current_scope

    case Chat.get_conversation(scope, conv.id) do
      {:ok, %{is_group: true} = fresh} ->
        {:ok, messages} = Chat.list_messages(scope, conv.id, limit: @page)
        socket |> assign(selected: fresh) |> stream(:messages, messages, reset: true)

      {:ok, fresh} ->
        assign(socket, selected: fresh)

      {:error, _} ->
        socket
    end
  end

  defp unsubscribe(socket) do
    if id = socket.assigns[:subscribed_id], do: Chat.unsubscribe(id)
    # Leaving a conversation's topic means its typers are no longer relevant —
    # clear them here so every deselect path (not just chat-switch) drops them
    # (#94 review). Stale TTL timers fire later and self-ignore on token mismatch.
    socket |> assign(subscribed_id: nil) |> clear_typing()
  end

  defp title(%{is_group: true, title: title}, _user) when is_binary(title) and title != "",
    do: title

  defp title(%{is_group: true} = conversation, user),
    do: conversation |> others(user) |> Enum.map_join(", ", & &1.display_name)

  defp title(conversation, user) do
    case others(conversation, user) do
      [first | _] -> first.display_name
      [] -> gettext("Just you")
    end
  end

  defp others(conversation, user) do
    conversation.memberships
    |> Enum.reject(&(&1.user_id == user.id))
    |> Enum.map(& &1.user)
  end

  # The single other participant of a 1:1 (nil for groups), used for the avatar.
  defp peer(%{is_group: true}, _user), do: nil
  defp peer(conversation, user), do: conversation |> others(user) |> List.first()

  # The peer's id for the header click target (nil for groups, which open the
  # member list rather than a single profile).
  defp peer_id(conversation, user), do: conversation |> peer(user) |> then(&(&1 && &1.id))

  defp member_count(conversation), do: length(conversation.memberships)

  # Avatar image URL for a user, cache-busted by the avatar key (nil → initials).
  defp avatar_src(%{avatar_key: key, id: id}) when is_binary(key),
    do: ~p"/users/#{id}/avatar?v=#{:erlang.phash2(key)}"

  defp avatar_src(_user), do: nil

  defp initials(name), do: name |> String.first() |> String.upcase()

  # Online state is shown for 1:1s (the other participant); groups don't show a dot.
  defp online?(%{is_group: true}, _user, _online_ids), do: false

  defp online?(conversation, user, online_ids) do
    case others(conversation, user) do
      [other | _] -> MapSet.member?(online_ids, other.id)
      [] -> false
    end
  end

  # Read receipts: the other participant's last_read_at for a 1:1 (nil for groups).
  defp other_read_at(%{is_group: true}, _user), do: nil

  defp other_read_at(conversation, user) do
    conversation.memberships
    |> Enum.find(&(&1.user_id != user.id))
    |> then(&(&1 && &1.last_read_at))
  end

  defp read?(_message, nil), do: false
  defp read?(message, read_at), do: DateTime.compare(message.inserted_at, read_at) != :gt

  defp empty_composer, do: to_form(%{}, as: "message")

  # Cancel every staged attachment upload (the composer tray). Used both by the
  # explicit "clear tray" action and on conversation switch so media staged in
  # one chat can't be sent into another (#89).
  defp cancel_staged_attachments(socket) do
    socket
    |> then(fn s ->
      Enum.reduce(s.assigns.uploads.attachment.entries, s, fn entry, acc ->
        cancel_upload(acc, :attachment, entry.ref)
      end)
    end)
    # A cleared tray or a conversation switch abandons the staged send, so drop the
    # sending flag + any queued client_ids + the progress gate (#95) — else a stale
    # `true` hides the overlay next staging, or a stranded id mis-stamps a later
    # send. Runs on cancel_all_uploads + select_conversation.
    |> assign(sending_media: false, media_client_ids: [], last_media_pct: nil)
  end

  ## Typing indicator (#11)

  # Tell the open conversation we're typing — throttled (composer_changed fires
  # per keystroke) and only with real content. Monotonic ms so the throttle is
  # immune to wall-clock changes.
  defp maybe_broadcast_typing(%{assigns: %{selected: nil}} = socket, _body), do: socket

  defp maybe_broadcast_typing(socket, body) do
    now = System.monotonic_time(:millisecond)
    last = socket.assigns.last_typing_at

    if String.trim(body) != "" and (is_nil(last) or now - last >= @typing_throttle_ms) do
      Chat.broadcast_typing(socket.assigns.current_scope, socket.assigns.selected.id)
      assign(socket, last_typing_at: now)
    else
      socket
    end
  end

  # Thread-reply typing (#103): same throttle, tagged with the thread root's id so
  # receivers route it to the thread panel only. No-op without an open thread.
  defp maybe_broadcast_thread_typing(%{assigns: %{selected: nil}} = socket, _body), do: socket
  defp maybe_broadcast_thread_typing(%{assigns: %{thread_root: nil}} = socket, _body), do: socket

  defp maybe_broadcast_thread_typing(socket, body) do
    now = System.monotonic_time(:millisecond)
    last = socket.assigns.last_thread_typing_at

    if String.trim(body) != "" and (is_nil(last) or now - last >= @typing_throttle_ms) do
      Chat.broadcast_typing(
        socket.assigns.current_scope,
        socket.assigns.selected.id,
        socket.assigns.thread_root.id
      )

      assign(socket, last_thread_typing_at: now)
    else
      socket
    end
  end

  # (Re)arm a typer's TTL in `field` (:typing_users for the room, :thread_typing_users
  # for the open thread, #103). Each arm gets a fresh token carried in the expiry
  # message; only the matching (latest) expiry drops the typer, so an earlier timer that
  # already fired can't drop someone who just re-armed (#94 review). Superseded timers
  # aren't cancelled — a stale one fires within the TTL and is ignored on token mismatch,
  # which keeps this allocation-free and race-free.
  defp track_typing(socket, field, user_id, name) do
    token = make_ref()
    Process.send_after(self(), {:typing_expired, field, user_id, token}, @typing_ttl_ms)
    assign(socket, field, Map.put(socket.assigns[field], user_id, %{name: name, token: token}))
  end

  defp drop_typing(socket, field, user_id),
    do: assign(socket, field, Map.delete(socket.assigns[field], user_id))

  defp clear_thread_typing(socket),
    do: assign(socket, thread_typing_users: %{}, last_thread_typing_at: nil)

  defp clear_typing(socket) do
    # Pending timers just fire later with stale tokens and are ignored — no cancel
    # needed (bounded: at most ~TTL/throttle timers per typer). Clears both the room
    # and the thread indicators (a conversation switch tears both down).
    assign(socket,
      typing_users: %{},
      last_typing_at: nil,
      thread_typing_users: %{},
      last_thread_typing_at: nil
    )
  end

  # "Anna is typing…" / "Anna and Oleg are typing…" / "Several people are typing…".
  defp typing_label(typing_users) do
    case Map.values(typing_users) |> Enum.map(& &1.name) |> Enum.sort() do
      [] -> ""
      [a] -> gettext("%{name} is typing…", name: a)
      [a, b] -> gettext("%{a} and %{b} are typing…", a: a, b: b)
      _ -> gettext("Several people are typing…")
    end
  end

  defp send_text(socket, scope, conversation, body, client_id, reply_to_id) do
    attrs = %{"body" => body, "client_id" => client_id, "reply_to_id" => reply_to_id}

    case Chat.create_message(scope, conversation.id, attrs) do
      {:ok, _message} ->
        # The form path clears the input via the composer assign; the hook path
        # (client_id present) already cleared it client-side, so leave the assign
        # alone to avoid clobbering text typed during a slow round-trip. A reply
        # always clears the tray.
        socket = if client_id, do: socket, else: assign(socket, composer: empty_composer())
        socket = if reply_to_id, do: assign(socket, reply_to: nil), else: socket
        # Just sent → reset the typing throttle so the next keystroke re-broadcasts
        # "typing" at once instead of waiting out the window (#94 review).
        socket = assign(socket, last_typing_at: nil)
        ack(socket, client_id)

      {:error, _changeset} ->
        socket
        |> put_flash(:error, gettext("Message is too long (up to 4000 characters)."))
        |> nack(client_id)
    end
  end

  # When a send comes from the client SendQueue hook (client_id present), reply so
  # it can clear or flag its optimistic bubble; a plain form submit gets :noreply.
  defp ack(socket, nil), do: {:noreply, socket}
  defp ack(socket, client_id), do: {:reply, %{"ack" => client_id}, socket}
  defp nack(socket, nil), do: {:noreply, socket}
  defp nack(socket, client_id), do: {:reply, %{"nack" => client_id}, socket}

  # Push the album's overall upload progress to the optimistic node's ring (#95),
  # addressed to the send's client_id (the oldest queued — media sends are serialized
  # client-side, so that's the in-flight one). Fires per entry as chunks arrive, so
  # we gate on the integer percent CHANGING — else a 10-photo album floods a slow
  # link with no-op frames. `ceil` lets the arc actually reach 100%.
  defp handle_attachment_progress(:attachment, _entry, socket) do
    pct = overall_progress(socket.assigns.uploads)

    if pct == socket.assigns.last_media_pct do
      {:noreply, socket}
    else
      socket = assign(socket, last_media_pct: pct)
      id = List.first(socket.assigns.media_client_ids)
      {:noreply, push_event(socket, "media_progress", %{percent: pct, id: id})}
    end
  end

  defp overall_progress(%{attachment: %{entries: []}}), do: 0

  defp overall_progress(%{attachment: %{entries: entries}}),
    do: ceil(Enum.sum(Enum.map(entries, & &1.progress)) / length(entries))

  # Stash a media send's client_id FIFO, bounded so a misbehaving client can't grow
  # it unbounded (sends are serialized, so 1-2 is the real depth) (#95).
  defp stash_cid(socket, id), do: Enum.take(socket.assigns.media_client_ids ++ [id], 16)

  defp pop_media_client_id([id | rest]), do: {id, rest}
  defp pop_media_client_id([]), do: {nil, []}

  # Tell the hook to drop the exact optimistic media node for a send that produced
  # no real row (server error or no consumed entry), so it doesn't spin forever and
  # pin its preview data-URLs (#95). A nil id (no twin tracked) is a no-op.
  defp push_media_failed(socket, nil), do: socket
  defp push_media_failed(socket, id), do: push_event(socket, "media_failed", %{id: id})

  # Both paths are framework/app-generated, never user input: `path` is the
  # LiveView upload temp file, `stable` is tmp_dir + the entry's server-side
  # uuid. So the File.cp!/File.rm traversal warnings are false positives.
  # sobelow_skip ["Traversal.FileModule"]
  defp send_attachment(socket, scope, conversation, body, reply_to_id, client_id) do
    # consume_uploaded_entries cleans up each temp file as its callback returns,
    # so to build ONE album from several entries we copy each to a stable temp,
    # then persist them together (atomic) and remove the temps.
    sources =
      consume_uploaded_entries(socket, :attachment, fn %{path: path}, entry ->
        stable = Path.join(System.tmp_dir!(), "eden-upload-" <> entry.uuid)
        File.cp!(path, stable)
        {:ok, %{path: stable, filename: entry.client_name}}
      end)

    # The upload has been consumed (entries are now []), so the normal composer
    # returns regardless; clear the flag (+ progress gate) so the next staging
    # shows the overlay and a fresh ring starts from 0.
    socket = assign(socket, sending_media: false, last_media_pct: nil)

    case sources do
      # No entry was consumed (still uploading or failed client-side validation).
      # The media never sends, so drop its optimistic ghost (#95); keep a caption
      # the user typed as a plain text message (the twin is a photo, not the text).
      [] ->
        socket = push_media_failed(socket, client_id)

        if String.trim(body) == "",
          do: {:noreply, socket},
          else: send_text(socket, scope, conversation, body, nil, reply_to_id)

      sources ->
        # client_id correlates the real album message with the hook's optimistic node
        # so the data-client-id swap drops the exact twin when it streams in (#95).
        opts = %{body: body, reply_to_id: reply_to_id, client_id: client_id}
        result = Chat.create_attachments(scope, conversation.id, sources, opts)
        Enum.each(sources, &File.rm(&1.path))

        case result do
          {:ok, _messages} ->
            # Reset the typing throttle on send too, same as send_text (#94 review).
            {:noreply,
             assign(socket, composer: empty_composer(), reply_to: nil, last_typing_at: nil)}

          {:error, reason} ->
            # No real row will stream in, so the optimistic media node would spin
            # forever (and pin its preview data-URLs in memory) — tell the hook to
            # drop that exact twin (#95). Text sends have nack/markFailed.
            {:noreply,
             socket |> put_flash(:error, attachment_error(reason)) |> push_media_failed(client_id)}
        end
    end
  end

  # Consume a staged channel-avatar upload (#70), if any → {channel, error_or_nil}.
  defp consume_channel_avatar(socket, scope, channel) do
    case consume_uploaded_entries(socket, :channel_avatar, fn %{path: path}, _entry ->
           {:ok, Channels.set_channel_avatar(scope, channel.id, path)}
         end) do
      [{:ok, updated}] -> {updated, nil}
      [{:error, reason}] -> {channel, reason}
      [] -> {channel, nil}
    end
  end

  defp attachment_error(:too_large), do: gettext("That file is too large.")
  defp attachment_error(:empty), do: gettext("That file is empty.")

  defp attachment_error(:too_many),
    do: gettext("Too many files (up to %{n}).", n: Chat.max_album_entries())

  defp attachment_error(_other), do: gettext("Couldn't send that file.")

  # Client-side upload validation errors surfaced by `allow_upload/3`.
  defp upload_error_text(:too_large), do: gettext("File too large")

  defp upload_error_text(:too_many_files),
    do: gettext("Up to %{n} files", n: Chat.max_album_entries())

  defp upload_error_text(_other), do: gettext("Invalid file")

  # Prefer the lighter thumbnail once it exists; fall back to the original while
  # the worker is still generating it.
  defp thumb_src(%{thumbnail_key: key, id: id}) when is_binary(key), do: ~p"/files/#{id}/thumb"
  defp thumb_src(%{id: id}), do: ~p"/files/#{id}"

  # Composer upload entry helpers (client-side; for preview only, not trusted —
  # the server re-classifies by magic bytes and decides the actual album split).
  defp image_entry?(%{client_type: "image/" <> _}), do: true
  defp image_entry?(_entry), do: false

  defp video_entry?(%{client_type: "video/" <> _}), do: true
  defp video_entry?(_entry), do: false

  defp media_entry?(entry), do: image_entry?(entry) or video_entry?(entry)

  defp entry_icon(%{client_type: "video/" <> _}), do: "hero-film-micro"
  defp entry_icon(%{client_type: "audio/" <> _}), do: "hero-musical-note-micro"
  defp entry_icon(_entry), do: "hero-document-micro"

  # Human-readable byte size (e.g. "3.4 MB"), used for files in the composer + bubble.
  defp human_size(bytes) when is_integer(bytes) and bytes >= 0 do
    cond do
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  defp human_size(_bytes), do: ""

  # Reserve the player's box before metadata loads, when dimensions are known
  # (the worker fills them in for video); avoids a layout jump.
  defp video_ratio(%{width: w, height: h})
       when is_integer(w) and is_integer(h) and w > 0 and h > 0,
       do: "aspect-ratio: #{w} / #{h}"

  defp video_ratio(_attachment), do: nil

  # Reserve an inline photo's display box BEFORE its bytes load. Image dimensions
  # are known at create time (image_dimensions reads the header), so a definite
  # width within the 20rem design cap + aspect-ratio holds the box — without it a
  # just-sent/streamed photo collapsed to a sliver then popped to full height (the
  # "photo shrinks then reopens, the stream jumps" bug; `width:auto` reserves
  # nothing pre-load). max-width:100% keeps it responsive on narrow screens with
  # the ratio held; we never upscale a small image (scale capped at 1).
  defp img_box(%{width: w, height: h}) when is_integer(w) and is_integer(h) and w > 0 and h > 0 do
    scale = min(min(320 / w, 320 / h), 1.0)
    dw = round(w * scale)
    "width:#{dw}px; max-width:100%; aspect-ratio:#{w}/#{h}; height:auto;"
  end

  defp img_box(_attachment),
    do: "max-width:min(20rem,100%); max-height:20rem; width:auto; height:auto;"
end
