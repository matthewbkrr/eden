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
  import EdenWeb.PresenceHelpers, only: [status_label: 1, status_color_var: 1]

  alias Eden.{Accounts, Channels, Chat}
  alias EdenWeb.ChatLive.AlbumLayout
  alias EdenWeb.Markup

  @page 50
  # Per-page size for the profile media gallery (#136); a "Load more" fetches the next page.
  @gallery_page 30

  # Typing indicator (#11): throttle outgoing "typing" broadcasts to at most one
  # per this window while composing; each received broadcast keeps the indicator
  # alive for the (longer) TTL, after which it auto-expires. TTL > throttle so a
  # continuous typer never flickers off between broadcasts.
  @typing_throttle_ms 2_000
  @typing_ttl_ms 4_000
  # "Last seen" heartbeat (#102): touch last_active_at on connect and periodically
  # while active, from this (sandboxed) LiveView process. Frozen while idle. The
  # idle/active transitions also touch, so this only needs coarse granularity.
  @touch_active_ms 300_000

  # Per-chunk upload timeout (#…). LiveView's default is 10s; a multi-file send opens one upload
  # channel PER file, so on a thin cross-border link the concurrent chunks split the bandwidth and
  # a 64KB chunk can't land in 10s → the push errors and the file stalls (a lone file uploads fine
  # on full bandwidth). 60s tolerates ~1KB/s per concurrent upload and still sits under the 90s
  # no-progress stall watchdog, so a genuinely wedged upload still surfaces as failed.
  @upload_chunk_timeout 60_000

  # Uploads cancelable via the shared "cancel_upload" event. A closed map, so a
  # crafted "upload" value can neither crash the LiveView (vs String.to_existing_atom)
  # nor reach an unrelated upload (e.g. :channel_avatar). #104.
  @cancelable_uploads %{
    "attachment" => :attachment,
    "thread_attachment" => :thread_attachment
  }

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket) do
      # Track with the user's effective status; an invisible user isn't tracked at
      # all (appears offline) but still subscribes to see others (#102).
      eff = EdenWeb.Presence.manual_to_effective(scope.user.presence_status)
      if eff != :invisible, do: EdenWeb.Presence.track_user(self(), scope.user.id, eff)
      Phoenix.PubSub.subscribe(Eden.PubSub, EdenWeb.Presence.topic())
      # The user chat topic carries sidebar-sync events (folders/activity/removed/read/…).
      # Notifications ride a SEPARATE topic owned by EdenWeb.NotifyHook (#272), so the two
      # subscriptions don't overlap — no double delivery of anything.
      Chat.subscribe_user(scope)
      Accounts.subscribe_user_updates()
      Accounts.subscribe_presence(scope)
      # Start the "last seen" heartbeat (#102); the first touch happens below via
      # touch_if_visible/1 (once assigns exist), so the invisible/online rule lives
      # in one place.
      Process.send_after(self(), :touch_active, @touch_active_ms)
    end

    socket =
      socket
      |> assign(
        page_title: gettext("Chats"),
        selected: nil,
        subscribed_id: nil,
        show_new: false,
        profile: nil,
        # #136: the expanded conversation-profile panel (DM peer card OR group card + members)
        # with a per-dialog media gallery. profile_open gates the panel; profile_peer is the
        # loaded peer User for a DM (nil for a group, which renders from @selected). The
        # gallery holds the active tab kind, the loaded page, and whether more exist.
        profile_open: false,
        profile_peer: nil,
        # Inline group-rename (#165): true while the owner/admin is editing the name.
        group_renaming: false,
        gallery_tab: "image",
        gallery_media: [],
        gallery_more: false,
        # Carry-and-drop forward: the message being carried (preloaded source) or nil. The id
        # is mirrored to sessionStorage by the .ForwardCarry hook, so the plaque survives
        # navigation/remount — every mount re-hydrates via forward_prompt. Send drops it here.
        pending_forward: nil,
        # Multi-select (Telegram-style): nil = off, else a MapSet of selected message ids
        # (may be empty while the mode stays on). Scoped to the open conversation; the bottom
        # action bar (forward/copy/delete) replaces the composer while it's non-nil.
        selection: nil,
        # Which surface the selection lives in — :main (room/DM stream) or :thread (the open
        # thread panel). Drives which container gets `.ed-selecting` + which composer the bar
        # replaces, so selecting in a thread stays in the thread.
        select_surface: nil,
        # The delete-selection confirm sheet: nil, or %{count, all_mine} (whether every selected
        # message is the user's own, which gates the "delete for everyone" option).
        sel_delete: nil,
        people: [],
        has_more: false,
        oldest_id: nil,
        # "Jump to message" target for the main stream (#jump): the .ScrollBottom hook reads
        # these off #message-scroll and scrolls to messages-<focus_id> instead of the bottom.
        # focus_nonce is monotonic so re-jumping the SAME message still re-fires.
        focus_id: nil,
        focus_nonce: 0,
        other_read_at: nil,
        statuses: EdenWeb.Presence.statuses(),
        my_status: scope.user.presence_status,
        # Auto-away (#102): true while this session is idle. Effective status is
        # recomputed from (my_status, idle?) — "auto" shows away when idle.
        idle?: false,
        # Tab is in the foreground (#206): default true (we just mounted in a focused tab; a
        # background mount corrects it via visibilitychange). While false, an incoming message
        # in the open chat is NOT auto-marked read — the user isn't looking.
        tab_visible: true,
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
        # Metadata for an in-flight failed-card Resend (#…): stashed by retry_prepare (client_id,
        # caption, as_file, media?, conversation), read by handle_retry_progress when the
        # :attachment_retry auto-upload completes to build the message. nil when no retry is live.
        pending_retry: nil,
        # FIFO of client_ids for in-flight media sends (#95): the hook pushes one on
        # media_sending just before each upload submit; send_attachment pops the
        # oldest to stamp the real message so its optimistic twin swaps out.
        media_client_ids: [],
        # Sequential send (TG-attachments): the queue metadata for in-flight sends and the
        # single item currently uploading on :attachment_seq. `send_queues` is a bounded list
        # of `%{queue_id, group_id, conv_id, root_id, caption, caption_id, as_file, albums,
        # files_left, caption_used}` (albums = %{album_cid => %{expected, sources}}); a send
        # appends one on queue_start. `seq_pending` is the item feeding right now — one at a
        # time — set on seq_item and cleared when it settles or resets.
        send_queues: [],
        seq_pending: nil,
        # Last upload percent pushed to the ring; gates redundant media_progress
        # frames so a slow link isn't flooded with no-op diffs (#95). The album
        # ring is a single percent; per-file rings (#149) gate by upload ref.
        last_media_pct: nil,
        last_file_pct: %{},
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
        # Which context the add-members modal acts on (#165 reuses it for groups).
        add_target: :channel,
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
        # In-thread search (#189): a separate search over the open thread's replies,
        # mirroring the in-room search bar but scoped to this thread.
        thread_search_open: false,
        thread_search: "",
        thread_results: nil,
        last_flat: nil,
        # The newest grouped-file run tracker {sender_id, group_id, id, pos} — lets a live file
        # message continue/break its merged-bubble run (TG-attachments), like last_flat for compact.
        last_group: nil,
        # Per-id group position, restored on a re-streamed row so the merged bubble keeps shape.
        group_pos: %{},
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
        # The viewer's double-click reaction (#106), read into #composer's dataset so
        # the .ContextMenu hook reacts with it; mount-only, like my_quick above.
        my_dbl: Chat.dbl_click_reaction(scope),
        # Quote-reply (#71): the message currently being replied to (or nil). Shown
        # in the composer tray; its id rides the next send. `thread_reply_to` is the
        # same for the thread panel's own composer (a quote within the thread).
        reply_to: nil,
        thread_reply_to: nil,
        # The message currently being edited (#164), or nil — drives the composer's
        # edit banner + pre-fill and routes "send" to edit_message. `%{id, body}`.
        editing: nil,
        # Same for a THREAD reply being edited (#164): drives the reply-composer's edit
        # banner + pre-fill and routes "send_reply" to edit_message. A thread reply edits
        # in the thread composer, not the main one.
        thread_editing: nil,
        # A MEDIA message being edited (#164 PR-2), or nil — drives the edit-media
        # modal (replace the album + caption). `%{message, kept}` where `kept` is the
        # MapSet of still-kept attachment ids; new photos ride the :edit_media upload.
        edit_media: nil,
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
      |> then(fn s ->
        convos = Chat.list_conversations(scope)
        s |> assign(sidebar_top: top_conv_id(convos)) |> stream(:conversations, convos)
      end)
      |> stream(:messages, [])
      # Accept anything: the server classifies by magic bytes and enforces the
      # per-kind size cap; the client cap is the largest (video). Images/video get
      # special rendering, everything else becomes a downloadable file.
      |> allow_upload(:attachment,
        accept: :any,
        # Stage up to max_staged_entries (#193): a pick past the album cap is split into a
        # sequence of albums server-side, so the config must accept more than one album's
        # worth at once (else the excess errors at config level and the whole upload wedges).
        max_entries: Chat.max_staged_entries(),
        max_file_size: Chat.max_attachment_bytes(),
        # A multi-file send opens ONE upload channel PER file, all pushing chunks concurrently
        # over the single LiveView socket (#…). On a slow cross-border link they split the
        # bandwidth, so a 64KB chunk can't finish in the DEFAULT 10s → the chunk push errors and
        # the file "stalls" — while a lone file (full bandwidth) uploads fine. Raise the per-chunk
        # timeout to @upload_chunk_timeout (still under the 90s no-progress watchdog) so a batch on
        # a thin link keeps going instead of stalling.
        chunk_timeout: @upload_chunk_timeout,
        # Feed the in-stream optimistic node a determinate progress ring (#95) —
        # Telegram-style, instead of an indeterminate spinner that can't show how
        # far a slow cross-border upload has gotten.
        progress: &handle_attachment_progress/3
      )
      # Dedicated Resend channel (#…): re-sending a stalled attachment can't reuse :attachment —
      # cancelling its in-flight entry leaves the config unable to accept new entries + racing the
      # cancelled upload's late progress (a crash). This SEPARATE config is NEVER cancelled, so a
      # retry stages into a pristine slot. auto_upload → the clones upload the instant they stage;
      # handle_retry_progress consumes + sends when done. Same caps/accept as :attachment.
      |> allow_upload(:attachment_retry,
        accept: :any,
        max_entries: Chat.max_staged_entries(),
        max_file_size: Chat.max_attachment_bytes(),
        chunk_timeout: @upload_chunk_timeout,
        auto_upload: true,
        progress: &handle_retry_progress/3
      )
      # Sequential send channel (TG-attachments): a batch uploads ONE item at a time here
      # (photos first, then files) instead of the concurrent :attachment path — each item
      # gets the full link so a thin cross-border connection stops starving the per-chunk
      # timeout (the batch-stall bug), and each file message / album lands progressively.
      # The client feeds a single clone at a time (feed → done → feed next), so at most one
      # entry is ever in flight; handle_seq_progress consumes it and drives the next.
      |> allow_upload(:attachment_seq,
        accept: :any,
        max_entries: Chat.max_staged_entries(),
        max_file_size: Chat.max_attachment_bytes(),
        chunk_timeout: @upload_chunk_timeout,
        auto_upload: true,
        progress: &handle_seq_progress/3
      )
      # Edit-media album (#164 PR-2): the photos ADDED while editing a media message.
      # Same caps as :attachment; the total (kept + these) is re-checked server-side by
      # edit_message_media. No progress ring — the modal shows staged previews, not a
      # streaming bubble.
      |> allow_upload(:edit_media,
        accept: :any,
        max_entries: Chat.max_album_entries(),
        max_file_size: Chat.max_attachment_bytes(),
        chunk_timeout: @upload_chunk_timeout
      )
      # Thread-reply album (#104): same accept/caps as :attachment, a separate upload so
      # the thread composer stages independently. No progress callback — a thread reply
      # appears on the {:thread_reply} broadcast (no optimistic ring, like text replies).
      |> allow_upload(:thread_attachment,
        accept: :any,
        max_entries: Chat.max_album_entries(),
        max_file_size: Chat.max_attachment_bytes(),
        chunk_timeout: @upload_chunk_timeout
      )
      # Channel avatar (#70): a single image, processed server-side to a square.
      |> allow_upload(:channel_avatar,
        accept: ~w(.png .jpg .jpeg .gif .webp),
        max_entries: 1,
        max_file_size: 5_000_000
      )
      # Group avatar (#178): click the big avatar in the profile panel → pick → it's
      # set at once (auto_upload + progress), processed server-side to a square.
      |> allow_upload(:group_avatar,
        accept: ~w(.png .jpg .jpeg .gif .webp),
        max_entries: 1,
        max_file_size: 5_000_000,
        auto_upload: true,
        progress: &consume_group_avatar/3
      )

    # "Last seen" (#102): record now on connect, reusing the heartbeat's guard
    # (skipped while invisible) so the rule lives in one place.
    socket = if connected?(socket), do: touch_if_visible(socket), else: socket

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
      thread_editing: nil,
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
  def handle_event("composer_changed", %{"message" => params}, socket) do
    # Track the value server-side so resetting to "" after send produces a real diff
    # that clears the input. Whitelist the two real fields — the chat input
    # (message[body]) and the media overlay's caption (message[caption]) — so a crafted
    # or extra key can't ride into @composer. Separate entities: typing a caption never
    # mirrors into the chat input. Typing broadcasts on the body only — a caption is not
    # a message-in-progress to the peer.
    fields = Map.take(params, ["body", "caption"])

    {:noreply,
     socket
     |> assign(composer: to_form(fields, as: "message"))
     |> maybe_broadcast_typing(fields["body"] || "")}
  end

  # Fired the instant a media send is submitted (#95): close the preview overlay now
  # (the in-stream node takes over) AND stash the send's client_id + caption FIFO. Both
  # ride this fire-and-forget push, which reaches us BEFORE the upload's "send" (same
  # channel → ordered), so send_attachment can stamp the real message with its caption
  # and its optimistic twin swaps out. The caption rides HERE — captured by the hook at
  # submit, while the overlay is still open — not in @composer, which a composer_changed
  # during the (slow) upload (e.g. typing another message) could clobber, dropping it.
  def handle_event("media_sending", params, socket) when is_map(params) do
    # `id` is the media album's optimistic client_id (nil for a files-only send);
    # `files` is a `%{upload_ref => client_id}` map so each file message gets its
    # OWN id and its optimistic card swaps independently (#149). A send carrying
    # neither (legacy/edge) just flips the flag without stashing junk.
    # #193: a pick is split into a sequence of albums, so the album optimistic ids ride as a
    # LIST (one per album). `id` (singular) is the legacy single-album client still cached
    # during a deploy — accept it as a one-element list.
    album_ids = sanitize_album_ids(params["album_ids"] || params["id"])
    files = sanitize_file_cids(params["files"])

    if album_ids == [] and files == %{} do
      {:noreply, assign(socket, sending_media: true)}
    else
      caption = if is_binary(params["caption"]), do: params["caption"], else: ""
      # caption_id is the client_id of the optimistic text node a files-only send draws
      # for its caption BELOW the pile (#149) — so the caption rides as its own trailing
      # message, not under the first file. A photo+caption leaves this nil (the caption
      # rides the album).
      caption_id = if is_binary(params["caption_id"]), do: params["caption_id"], else: nil
      # #122: "Send as file" rides here (captured by the hook at submit, while the overlay
      # is open) so each queued batch keeps its own choice — same reason caption does.
      as_file = params["as_file"] == true

      {:noreply,
       assign(socket,
         sending_media: true,
         media_client_ids:
           stash_cid(socket, album_ids, caption, selected_id(socket), files, caption_id, as_file)
       )}
    end
  end

  # A malformed (non-map) media_sending payload must not crash the LiveView — there is no
  # global handle_event/3 fallback, so without this a crafted event raises FunctionClause.
  # Mirror the legacy behaviour: just flip the in-flight flag.
  def handle_event("media_sending", _params, socket),
    do: {:noreply, assign(socket, sending_media: true)}

  # Sequential send (TG-attachments) — the client opens a queue at Send. It carries the whole
  # plan (albums + file client_ids + caption placement + as_file); the server pins the
  # conversation, mints a group_id for a multi-file send (≥2 files → the rows render as one
  # merged bubble; a lone file stays a normal bubble), stashes the queue, and cancels the
  # now-superseded staged :attachment entries (the client re-feeds clones into :attachment_seq
  # one at a time). Replies with the group_id so the optimistic file-group node can carry it.
  def handle_event("queue_start", params, socket) when is_map(params) do
    queue_id = sanitize_cid(params["queue_id"])
    file_cids = sanitize_album_ids(params["file_cids"])
    albums = build_album_specs(params["albums"])
    caption = if is_binary(params["caption"]), do: params["caption"], else: ""
    caption_id = sanitize_cid(params["caption_id"])
    as_file = params["as_file"] == true
    root_id = sanitize_root_id(params["root_id"])

    if queue_id == nil or (albums == %{} and file_cids == []) do
      {:reply, %{ok: false}, socket}
    else
      # ≥2 files → one shared group_id (merged bubble); a lone file stays ungrouped.
      group_id = if length(file_cids) >= 2, do: Ecto.UUID.generate(), else: nil

      queue = %{
        queue_id: queue_id,
        group_id: group_id,
        conv_id: selected_id(socket),
        # root_id (phase F): the thread composer sends the root — the file steps become REPLIES under
        # it (Chat.create_album_reply re-validates access + threading). The main composer sends none.
        root_id: root_id,
        caption: caption,
        caption_id: caption_id,
        as_file: as_file,
        albums: albums,
        files_left: length(file_cids),
        caption_used: false
      }

      socket =
        socket
        |> cancel_seq_staged(root_id)
        |> assign(
          # `sending_media` gates the MAIN composer's UI (overlay/pick-queue). A thread send (root_id)
          # runs its own panel and must not mark the main composer busy — but it must preserve a main
          # send already in flight (don't clobber a concurrent true).
          sending_media: root_id == nil or socket.assigns.sending_media,
          # Tail, not head: on overflow keep the NEWEST queues (the one we just appended + reply
          # {ok} for), so the client's items always find their stashed queue. Realistic depth is
          # 1-2 (the feeder drains sequentially); the cap is a runaway backstop.
          send_queues: Enum.take(socket.assigns.send_queues ++ [queue], -16)
        )

      {:reply, %{ok: true, group_id: group_id}, socket}
    end
  end

  def handle_event("queue_start", _params, socket), do: {:reply, %{ok: false}, socket}

  # Resume a send interrupted by a page reload (TG-attachments, phase E): the client rebuilt this
  # queue from its durable IndexedDB records and re-opens it here. Like queue_start, but it REUSES
  # the send's original group_id (if the caller owns that group — else mints a fresh one) so resumed
  # rows rejoin their merged bubble, and it reports which items already landed before the reload
  # (`already_sent` file client_ids + `done_albums`) so the client drops them instead of re-uploading
  # — the idempotent resume, backed by the (sender_id, client_id) unique index.
  def handle_event("queue_resume", params, socket) when is_map(params) do
    queue_id = sanitize_cid(params["queue_id"])
    conv_id = selected_id(socket)
    file_cids = sanitize_album_ids(params["file_cids"])
    albums = build_album_specs(params["albums"])
    caption = if is_binary(params["caption"]), do: params["caption"], else: ""
    caption_id = sanitize_cid(params["caption_id"])
    as_file = params["as_file"] == true
    root_id = sanitize_root_id(params["root_id"])
    scope = socket.assigns.current_scope

    if queue_id == nil or is_nil(conv_id) or (albums == %{} and file_cids == []) do
      {:reply, %{ok: false}, socket}
    else
      group_id = resolve_resume_group_id(scope, conv_id, params["group_id"], file_cids)

      sent = Chat.sent_client_ids(scope, conv_id, file_cids ++ List.wrap(caption_id))
      already_sent = Enum.filter(file_cids, &(&1 in sent))
      done_albums = Chat.sent_client_ids(scope, conv_id, Map.keys(albums))

      remaining_albums = Map.drop(albums, done_albums)
      files_left = length(file_cids) - length(already_sent)

      socket =
        if files_left <= 0 and remaining_albums == %{} do
          # Everything already landed before the reload — nothing to re-upload.
          socket
        else
          queue = %{
            queue_id: queue_id,
            group_id: group_id,
            conv_id: conv_id,
            root_id: root_id,
            caption: caption,
            caption_id: caption_id,
            as_file: as_file,
            albums: remaining_albums,
            files_left: files_left,
            # The trailing files-only caption may already have been posted — don't re-send it.
            caption_used: caption_id != nil and caption_id in sent
          }

          assign(socket,
            sending_media: true,
            send_queues: Enum.take(socket.assigns.send_queues ++ [queue], -16)
          )
        end

      {:reply,
       %{ok: true, group_id: group_id, already_sent: already_sent, done_albums: done_albums},
       socket}
    end
  end

  def handle_event("queue_resume", _params, socket), do: {:reply, %{ok: false}, socket}

  # Announce the next item BEFORE feeding its clone (reply-gated, like retry_prepare): the reply
  # guarantees seq_pending is set before the entry's first progress tick, so a fast upload can't
  # race ahead of its metadata. Single slot → busy-gate a second item while one is in flight.
  def handle_event("seq_item", params, socket) when is_map(params) do
    if socket.assigns.seq_pending != nil do
      {:reply, %{ok: false, busy: true}, socket}
    else
      pending = %{
        queue_id: sanitize_cid(params["queue_id"]),
        client_id: sanitize_cid(params["client_id"]),
        kind: if(params["kind"] == "media", do: :media, else: :file),
        album_cid: sanitize_cid(params["album_cid"])
      }

      # The queue must still be stashed — else (e.g. it was evicted on overflow) accepting the item
      # would upload an entry no progress handler can consume, orphaning it + wedging seq_pending.
      queue_exists? = Enum.any?(socket.assigns.send_queues, &(&1.queue_id == pending.queue_id))

      if pending.queue_id == nil or pending.client_id == nil or not queue_exists? do
        {:reply, %{ok: false}, socket}
      else
        {:reply, %{ok: true}, assign(socket, seq_pending: pending)}
      end
    end
  end

  def handle_event("seq_item", _params, socket), do: {:reply, %{ok: false}, socket}

  # The client watchdog fires this when the in-flight item stalled: abort it and free the slot so
  # the queue skips to the NEXT item (the batch keeps going; the stalled item's card is marked
  # failed client-side and re-sendable via the retry channel, inheriting its group_id). Idempotent
  # — a double fire (stall race) finds the slot already clear.
  def handle_event("seq_reset", _params, socket) do
    pending = socket.assigns.seq_pending

    socket =
      socket
      |> cancel_seq_entries()
      |> assign(seq_pending: nil)
      # The aborted item never lands, so drop it from its queue's accounting (a file decrements
      # files_left; an album photo decrements THAT album's expected — per-photo, phase D) — else
      # files_left/albums never reach zero and the queue can't finalize, leaving sending_media stuck.
      |> drop_pending_from_queue(pending)
      |> maybe_end_sending()

    {:noreply, socket}
  end

  # A queued item the client cancelled BEFORE it was fed (so no seq_pending server-side): drop its
  # accounting so the queue can still finalize. Mirrors seq_reset for the not-yet-in-flight case.
  def handle_event("seq_drop", params, socket) when is_map(params) do
    queue_id = sanitize_cid(params["queue_id"])
    kind = if params["kind"] == "media", do: :media, else: :file
    album_cid = sanitize_cid(params["album_cid"])

    {:noreply, socket |> drop_queue_item(queue_id, kind, album_cid) |> maybe_end_sending()}
  end

  def handle_event("seq_drop", _params, socket), do: {:noreply, socket}

  # The watchdog hook fires this when an upload stalled (30s no progress): the link died
  # after the optimistic node + media_sending, so "send" never fired and the entries are
  # still staged. Do NOT just clear sending_media to re-show the overlay for retry — after a
  # conversation switch the staged previews are gone (blank tiles), and worse, the still-
  # staged entries sit in a limbo that the NEXT chat switch silently cancels (files vanish
  # with no error). Instead ABORT cleanly: cancel the staged entries so nothing lingers, and
  # surface the failure so the loss is never silent. Already-completed files in a batch (#149,
  # each posts the moment it finishes) have left as real messages and are unaffected.
  def handle_event("media_send_reset", _params, socket) do
    # The client marked the stalled node(s) as a visible FAILED card (!, with resend + delete);
    # this just cancels the wedged staged entries and resets the send flags
    # (cancel_staged_attachments does both), so nothing lingers to be nuked on a switch and new
    # picks aren't blocked. No flash — the inline ! is the visible failure.
    #
    # GUARD (#309 review P1): a multi-file send arms one stall watchdog PER optimistic card, so
    # several fire this event. The first abort clears sending_media; if a second (or a straggler
    # armed 90s earlier) re-reduced over the just-cancelled ghosts it would GenServer.call a dead
    # upload channel and crash the LiveView — and a late straggler could nuke a batch the user has
    # since re-staged. Gate on sending_media so every reset after the first is a no-op.
    if socket.assigns.sending_media,
      do: {:noreply, cancel_staged_attachments(socket)},
      else: {:noreply, socket}
  end

  # Failed-card Resend, step 1 (#…): stash what the retry needs — the fresh optimistic client_id,
  # the caption, the "send as file" flag, whether it's media or a plain file, and the conversation
  # it belongs to (captured now, so navigating away can't misroute it). The client feeds the
  # cloned File(s) into :attachment_retry only after this reply lands, so the metadata is ready
  # when handle_retry_progress fires.
  #
  # pending_retry is a SINGLE slot and :attachment_retry a SHARED config (#310 review P0/P1):
  #   - BUSY-GATE: refuse while a retry is already in flight, else the second prepare would
  #     clobber the first's metadata and send_retry would merge both batches into one message
  #     (wrong caption/conversation). The client keeps the card failed and retries once free.
  #   - CLEAN SLATE: cancel any stray :attachment_retry entries before this retry so a paste/queue
  #     that leaked in (or an orphaned prior retry) can't ride along into send_retry's consume.
  def handle_event("retry_prepare", params, socket) do
    cond do
      socket.assigns.pending_retry != nil ->
        {:reply, %{ok: false, busy: true}, socket}

      match?(%{id: _}, socket.assigns.selected) ->
        pending = %{
          client_id: params["client_id"],
          caption: params["caption"] || "",
          as_file: params["as_file"] == true,
          media: params["media"] == true,
          # A failed FILE re-sends into its original group (TG-attachments) so the resent row
          # rejoins the merged bubble. Validated as a UUID; nil for a media album retry.
          group_id: sanitize_group_id(params["group_id"]),
          conversation_id: socket.assigns.selected.id
        }

        {:reply, %{ok: true}, socket |> cancel_retry_entries() |> assign(pending_retry: pending)}

      true ->
        {:reply, %{ok: false}, socket}
    end
  end

  # Failed-card Resend, abort (#…): a stalled retry (its watchdog fired) cancels the pristine
  # :attachment_retry entries and drops the pending metadata, so the card re-shows its failed
  # state and a later retry starts clean. (:attachment_retry is auto_upload, so no send flags.)
  def handle_event("retry_reset", _params, socket) do
    {:noreply, socket |> cancel_retry_entries() |> assign(pending_retry: nil)}
  end

  # The hook caps a pick at max_staged_entries (#193) — more than the upload config takes at
  # once would tag the excess :too_many_files and wedge the whole upload. Surface why nothing
  # staged via the standard flash instead of a silent drop.
  def handle_event("media_too_many", params, socket) do
    max = if is_integer(params["max"]), do: params["max"], else: Chat.max_staged_entries()

    {:noreply,
     put_flash(
       socket,
       :error,
       gettext("You can attach at most %{count} files at once.", count: max)
     )}
  end

  # A client on cached PRE-redesign JS still uses the old two-pass and pushes the
  # id on this event instead of media_sending. Stash it the same way so its send
  # still correlates during the deploy window; a malformed payload is ignored.
  # Safe to delete (this clause + the catch-all below) once no client can still be
  # serving cached pre-#95 JS — i.e. one asset-cache lifetime after the deploy.
  def handle_event("media_client_id", %{"id" => id}, socket) when is_binary(id) do
    {:noreply,
     assign(socket,
       media_client_ids: stash_cid(socket, [id], "", selected_id(socket), %{}, nil, false)
     )}
  end

  def handle_event("media_client_id", _params, socket), do: {:noreply, socket}

  def handle_event("send", %{"message" => %{"body" => body} = msg}, socket) do
    conversation = socket.assigns.selected

    # Carry-and-drop forward: while carrying a message, Send drops it into this conversation
    # (top-level). Handled before the normal dispatch, which stays within complexity limits.
    if socket.assigns.pending_forward && conversation,
      do: drop_forward(socket, conversation.id),
      else: send_dispatch(socket, body, msg)
  end

  # Ignore malformed send payloads (e.g. a crafted event) instead of crashing.
  def handle_event("send", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref} = params, socket) do
    # Defaults to :attachment (the main composer); the thread tray passes
    # phx-value-upload="thread_attachment" (#104). An unknown key (crafted event)
    # is ignored rather than crashing the process.
    case Map.fetch(@cancelable_uploads, Map.get(params, "upload", "attachment")) do
      # The main composer cancel handles both the tray (before send) and the in-flight
      # cancel (#137): aborting the last entry of a send must also clear sending_media.
      {:ok, :attachment} -> {:noreply, cancel_attachment_entry(socket, ref)}
      {:ok, upload} -> {:noreply, cancel_upload(socket, upload, ref)}
      :error -> {:noreply, socket}
    end
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

  # Expanded conversation profile (#136): a full panel with the DM peer's card OR the group's
  # card + member list, plus the per-dialog media gallery. DM + groups; a room (channel_id set)
  # or a missing conversation no-ops. The peer is derived from @selected — never a client-sent
  # id — so the card and the gallery always describe the same conversation (P2-A).
  def handle_event("open_profile", _params, socket) do
    %{current_scope: scope, selected: selected} = socket.assigns

    with %{channel_id: nil} <- selected,
         {:ok, peer} <- panel_peer(scope, selected) do
      {:noreply,
       socket |> assign(profile_open: true, profile_peer: peer) |> load_gallery("image")}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("close_profile_panel", _params, socket) do
    {:noreply,
     assign(socket,
       profile_open: false,
       profile_peer: nil,
       group_renaming: false,
       gallery_media: [],
       gallery_more: false
     )}
  end

  # Switch gallery tab; the kind is client-supplied, so validate against the closed set.
  def handle_event("gallery_tab", %{"tab" => tab}, socket)
      when tab in ~w(image video file audio) do
    {:noreply, load_gallery(socket, tab)}
  end

  def handle_event("gallery_tab", _params, socket), do: {:noreply, socket}

  # Append the next page of the active gallery tab (#136 pagination).
  def handle_event("gallery_more", _params, socket), do: {:noreply, load_more_gallery(socket)}

  # The user picks a presence status (#102). Persist it; the per-user broadcast
  # feeds this tab (and any other) back through {:presence_status_changed, ...},
  # which mirrors it onto the tracked presence and the UI — one path for all
  # sessions. An invalid value is rejected by the changeset and ignored.
  def handle_event("set_status", %{"status" => status}, socket) do
    case Accounts.set_presence_status(socket.assigns.current_scope.user, status) do
      {:ok, _user} -> :ok
      {:error, _changeset} -> :ok
    end

    {:noreply, socket}
  end

  # Auto-away (#102): the .IdleTracker hook reports this session going idle/active.
  # Only "auto" users change effective status on idle (manual statuses ignore it),
  # so maybe_apply_idle skips the presence write otherwise; idle? is tracked
  # regardless so switching to "auto" later picks up the current idle state. No
  # last_active touch here — an idle user is still online, so the heartbeat keeps
  # "last seen" fresh until they actually disconnect.
  def handle_event("presence_idle", _params, socket) do
    {:noreply, maybe_apply_idle(assign(socket, idle?: true))}
  end

  def handle_event("presence_active", _params, socket) do
    {:noreply, maybe_apply_idle(assign(socket, idle?: false))}
  end

  # Tab hidden (#206): stop auto-marking incoming messages read while the user isn't looking
  # (presence already went away via presence_idle from the same visibilitychange).
  def handle_event("tab_hidden", _params, socket),
    do: {:noreply, assign(socket, tab_visible: false)}

  # Tab visible again (#206): resume, and read whatever arrived in the open chat while away
  # (mark_read broadcasts {:read} → the badges refresh via #204).
  def handle_event("tab_visible", _params, socket) do
    socket = assign(socket, tab_visible: true)

    case socket.assigns.selected do
      %{id: id} -> Chat.mark_read(socket.assigns.current_scope, id)
      _ -> :ok
    end

    {:noreply, socket}
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

      {:error, :owner} ->
        {:noreply,
         put_flash(socket, :error, gettext("Transfer ownership before leaving the group."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't delete that chat."))}
    end
  end

  # Group role management (#165). Distinct events from the channel ones (which act on
  # @channel) — these act on the open GROUP conversation (@selected). The context
  # authorizes; we just surface a flash on failure. The member list + roles refresh live
  # via the {:group_members_changed} broadcast below.
  def handle_event(
        "group_remove_member",
        %{"id" => id},
        %{assigns: %{selected: %{id: sel_id}}} = socket
      ) do
    case Chat.remove_group_member(socket.assigns.current_scope, sel_id, id) do
      :ok ->
        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't remove that member."))}
    end
  end

  # No-op with nothing selected (@selected nil): the event can be pushed from any page.
  def handle_event("group_remove_member", _params, socket), do: {:noreply, socket}

  # No guard: the context validates the role and errors on crafted values.
  def handle_event("group_set_role", %{"id" => id, "role" => role}, socket) do
    case Chat.set_group_member_role(
           socket.assigns.current_scope,
           socket.assigns.selected.id,
           id,
           role
         ) do
      :ok -> {:noreply, socket}
      {:error, _} -> {:noreply, put_flash(socket, :error, gettext("Couldn't change that role."))}
    end
  end

  def handle_event("group_transfer_ownership", %{"id" => id}, socket) do
    case Chat.transfer_group_ownership(
           socket.assigns.current_scope,
           socket.assigns.selected.id,
           id
         ) do
      :ok ->
        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't transfer ownership."))}
    end
  end

  # #165: inline group rename (owner/admin). The pencil toggles the edit; the form saves.
  def handle_event("start_group_rename", _params, socket),
    do: {:noreply, assign(socket, group_renaming: true)}

  def handle_event("cancel_group_rename", _params, socket),
    do: {:noreply, assign(socket, group_renaming: false)}

  def handle_event("rename_group", %{"title" => title}, socket) do
    case Chat.rename_group(socket.assigns.current_scope, socket.assigns.selected.id, title) do
      {:ok, _renamed} ->
        {:noreply,
         socket |> assign(group_renaming: false) |> put_flash(:info, gettext("Group renamed."))}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(group_renaming: false)
         |> put_flash(:error, gettext("Couldn't rename the group."))}
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

  def handle_event("open_channel_edit", _params, %{assigns: %{channel: %{} = channel}} = socket) do
    if channel.role in ~w(owner admin) do
      form = to_form(Channels.change_channel(channel))
      {:noreply, assign(socket, show_channel_edit: true, channel_form: form)}
    else
      {:noreply, socket}
    end
  end

  # No-op outside channel mode (@channel nil): a client can push this event from any
  # page, but there's nothing to edit without a channel (#259).
  def handle_event("open_channel_edit", _params, socket), do: {:noreply, socket}

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

  # #178: the group-avatar file input lives in a form so the auto-upload registers;
  # the actual work happens in the progress callback (consume_group_avatar/3).
  def handle_event("validate_group_avatar", _params, socket) do
    # Pin which group the in-flight upload belongs to (the open one when it started), so
    # the progress callback applies it correctly even if the user navigates away.
    target =
      case socket.assigns.selected do
        %{is_group: true, id: id} -> id
        _ -> nil
      end

    {:noreply, assign(socket, group_avatar_target: target)}
  end

  # #178: owner/admin clears the group photo from the profile panel (back to initials).
  def handle_event("remove_group_avatar", _params, socket) do
    case Chat.remove_group_avatar(socket.assigns.current_scope, socket.assigns.selected.id) do
      {:ok, updated} ->
        {:noreply,
         assign(socket, selected: %{socket.assigns.selected | avatar_key: updated.avatar_key})}

      {:error, _} ->
        {:noreply, socket}
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

  def handle_event("open_new_room", _params, %{assigns: %{channel: %{} = channel}} = socket) do
    if channel.role in ~w(owner admin) do
      {:noreply,
       assign(socket, room_modal: :new, room_form: to_form(Chat.change_room(), as: :room))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("open_new_room", _params, socket), do: {:noreply, socket}

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

  ## In-thread search (#189): scoped to the open thread's replies.

  def handle_event("toggle_thread_search", _params, socket) do
    open = !socket.assigns.thread_search_open
    {:noreply, assign(socket, thread_search_open: open, thread_search: "", thread_results: nil)}
  end

  def handle_event("thread_search", %{"q" => q}, socket) do
    case socket.assigns.thread_root do
      %{id: root_id} ->
        results = run_thread_search(socket, root_id, q)
        {:noreply, assign(socket, thread_search: q, thread_results: results)}

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

  def handle_event("open_channel_members", _params, %{assigns: %{channel: %{id: cid}}} = socket) do
    case Channels.list_members(socket.assigns.current_scope, cid) do
      {:ok, members} -> {:noreply, assign(socket, members_open: true, members: members)}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_event("open_channel_members", _params, socket), do: {:noreply, socket}

  def handle_event("close_channel_members", _params, socket) do
    {:noreply, assign(socket, members_open: false)}
  end

  def handle_event("open_add_members", _params, %{assigns: %{channel: %{} = channel}} = socket) do
    with true <- channel.role in ~w(owner admin),
         {:ok, members} <-
           Channels.list_members(socket.assigns.current_scope, channel.id) do
      member_ids = MapSet.new(members, & &1.user.id)

      addable =
        socket.assigns.current_scope
        |> Accounts.list_other_users()
        |> Enum.reject(&MapSet.member?(member_ids, &1.id))

      {:noreply,
       assign(socket,
         add_open: true,
         add_target: :channel,
         addable: addable,
         add_selected: MapSet.new()
       )}
    else
      # Not an admin anymore / kicked between render and click — no modal.
      _ -> {:noreply, socket}
    end
  end

  def handle_event("open_add_members", _params, socket), do: {:noreply, socket}

  # #165: add eden users to a group (owner/admin). Reuses the add-members modal via
  # add_target; addable = everyone the actor can see who isn't already an active member.
  def handle_event("open_group_add_members", _params, socket) do
    conv = socket.assigns.selected

    with %{is_group: true} <- conv,
         role when role in ~w(owner admin) <-
           Chat.group_role(socket.assigns.current_scope, conv.id) do
      member_ids = MapSet.new(active_members(conv), & &1.user_id)

      addable =
        socket.assigns.current_scope
        |> Accounts.list_other_users()
        |> Enum.reject(&MapSet.member?(member_ids, &1.id))

      {:noreply,
       assign(socket,
         add_open: true,
         add_target: :group,
         addable: addable,
         add_selected: MapSet.new()
       )}
    else
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
    scope = socket.assigns.current_scope

    result =
      case socket.assigns.add_target do
        :group -> Chat.add_group_members(scope, socket.assigns.selected.id, ids)
        _ -> Channels.add_members(scope, socket.assigns.channel.id, ids)
      end

    case result do
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

  # Carry-and-drop forward: "Forward" picks the message up (plaque on the composer) instead of
  # opening a target modal. The .ForwardCarry hook re-fires this on every mount with the id it
  # kept in sessionStorage, so the carry survives navigation across DMs, rooms and channels.
  # "Forward" from a single message's menu — carry just that one. Forwarding from a thread reply
  # closes the thread panel (like the bar's forward_selection), so the plaque lands on the room's
  # main composer and the drop is visible there — not hidden behind the still-open thread panel.
  def handle_event("forward_prompt", %{"id" => id} = params, socket) do
    socket = if params["surface"] == "thread", do: close_thread_panel(socket), else: socket
    {:noreply, carry(socket, [id])}
  end

  # "Forward" from the multi-select bar — carry the whole selection (ordered) and exit select.
  # Carrying FROM a thread also closes the thread panel, so the plaque lands on the room's main
  # composer: Send then drops into the room (or navigate elsewhere). Otherwise a Send in the
  # thread composer would just re-drop the carry back into the same thread — never the room.
  def handle_event("forward_selection", _params, socket) do
    ids = socket.assigns.selection |> then(&((&1 && MapSet.to_list(&1)) || []))
    from_thread? = socket.assigns.select_surface == :thread

    socket =
      socket
      |> assign(selection: nil, sel_delete: nil, select_surface: nil)
      |> then(&if(from_thread?, do: close_thread_panel(&1), else: &1))
      |> carry(ids)

    {:noreply, socket}
  end

  # Re-hydrate the carry after a navigation/remount (the .ForwardCarry hook replays the ids it
  # kept in sessionStorage). Gone/unauthorized ids drop out; an empty result clears the plaque.
  def handle_event("forward_rehydrate", %{"ids" => ids}, socket) when is_list(ids),
    do: {:noreply, carry(socket, ids)}

  def handle_event("forward_rehydrate", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_forward", _params, socket) do
    {:noreply, socket |> assign(pending_forward: nil) |> push_event("carry_clear", %{})}
  end

  # Multi-select (Telegram-style). "Select" from the message menu enters the mode with this
  # message picked; tapping a row toggles it; the mode ends on Close / Escape / chat switch. The
  # `surface` ("thread" | "main") keeps a thread selection in the thread panel.
  def handle_event("enter_select", %{"id" => id} = params, socket) do
    case safe_int(id) do
      nil ->
        {:noreply, socket}

      mid ->
        surface = if params["surface"] == "thread", do: :thread, else: :main
        {:noreply, assign(socket, selection: MapSet.new([mid]), select_surface: surface)}
    end
  end

  def handle_event("toggle_select", %{"id" => id}, socket) do
    case {socket.assigns.selection, safe_int(id)} do
      {%MapSet{} = sel, mid} when is_integer(mid) ->
        sel = if MapSet.member?(sel, mid), do: MapSet.delete(sel, mid), else: MapSet.put(sel, mid)
        # Deselecting the last one exits the mode (Telegram-style) — no dead bar of disabled
        # actions.
        {:noreply, assign(socket, selection: if(MapSet.size(sel) == 0, do: nil, else: sel))}

      _ ->
        {:noreply, socket}
    end
  end

  # Shift-click range: the .SelectSync hook computes the ids between the anchor and the clicked
  # row (DOM order) and adds them all at once.
  def handle_event("select_range", %{"ids" => ids}, socket) when is_list(ids) do
    case socket.assigns.selection do
      %MapSet{} = sel ->
        add = ids |> Enum.map(&safe_int/1) |> Enum.filter(&is_integer/1) |> MapSet.new()
        {:noreply, assign(socket, selection: MapSet.union(sel, add))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("select_range", _params, socket), do: {:noreply, socket}

  def handle_event("exit_select", _params, socket),
    do: {:noreply, assign(socket, selection: nil, sel_delete: nil, select_surface: nil)}

  # The client copied the selection (assembled + written within the gesture) — confirm + exit.
  def handle_event("selection_copied", _params, socket) do
    {:noreply,
     socket
     |> assign(selection: nil, sel_delete: nil, select_surface: nil)
     |> put_flash(:info, gettext("Copied."))}
  end

  # Delete the selection: open a confirm sheet. "Delete for everyone" is offered only when every
  # selected message is the user's own (the context re-checks per message regardless).
  def handle_event("delete_prompt", _params, socket) do
    case socket.assigns.selection do
      %MapSet{} = sel ->
        me = socket.assigns.current_scope.user.id
        messages = Chat.get_messages(socket.assigns.current_scope, MapSet.to_list(sel))
        # "Delete for everyone" is available only when every selected message is the user's own
        # AND none is a root with replies (delete_message_for_both refuses those) — so the
        # option we offer never silently skips a message.
        for_all =
          messages != [] and
            Enum.all?(messages, &(&1.sender_id == me and not root_with_replies?(&1)))

        {:noreply, assign(socket, sel_delete: %{count: MapSet.size(sel), for_all: for_all})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_delete", _params, socket),
    do: {:noreply, assign(socket, sel_delete: nil)}

  def handle_event("delete_selection", %{"scope" => scope}, socket) do
    # Guard a stale/forged event arriving after the selection was cleared (nil isn't a MapSet).
    ids = (socket.assigns.selection || MapSet.new()) |> MapSet.to_list()
    user = socket.assigns.current_scope

    deleted =
      case scope do
        "both" -> Chat.delete_messages_for_both(user, ids)
        _ -> Chat.delete_messages_for_me(user, ids)
      end

    socket = assign(socket, selection: nil, sel_delete: nil, select_surface: nil)

    # Honest feedback: the bulk delete is best-effort (a vanished/undeletable id is skipped), so
    # only claim "Deleted." when something actually was.
    socket =
      if deleted > 0,
        do: put_flash(socket, :info, gettext("Deleted.")),
        else: put_flash(socket, :error, gettext("Those messages couldn't be deleted."))

    {:noreply, socket}
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
    {:noreply, socket |> reset_thread_select() |> close_thread_panel()}
  end

  # The Threads list panel (#57): the room's followed threads, drill into any.
  def handle_event("open_threads", _params, %{assigns: %{selected: %{id: sel_id}}} = socket) do
    scope = socket.assigns.current_scope

    {:noreply,
     assign(socket,
       thread_list_open: true,
       thread_root: nil,
       thread_reply_to: nil,
       thread_editing: nil,
       thread_list: Chat.list_followed_threads(scope, sel_id)
     )}
  end

  # Threads are a room feature; no-op with nothing open (@selected nil, #259).
  def handle_event("open_threads", _params, socket), do: {:noreply, socket}

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

  # #164: enter edit mode — pre-fill the chat input with the message's current body and
  # show the edit banner. The menu only offers this for your own non-system messages;
  # edit_message re-checks on save. A staged reply is dropped (you're editing, not replying).
  # Edit (#164): fetch the message (scoped, author re-checked below) and branch — a media
  # message opens the edit-media modal (replace album + caption, #164 PR-2); a text message
  # edits inline in the composer (banner + pre-fill). Fetching centralises the choice and
  # avoids trusting a client-passed body.
  def handle_event("start_edit", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    message = Chat.get_message(scope, id)

    cond do
      is_nil(message) or message.sender_id != scope.user.id or message.kind == "system" ->
        {:noreply, socket}

      match?([_ | _], message.attachments) ->
        {:noreply,
         assign(socket,
           edit_media: %{
             message: message,
             kept: initial_kept_ids(message),
             caption: message.body
           }
         )}

      not is_nil(message.root_id) ->
        # A thread reply (rooms-only, #57) edits in the THREAD composer, not the main one —
        # its banner + pre-fill live in the reply-composer (targeted push, F3).
        {:noreply,
         socket
         |> assign(
           thread_editing: %{id: message.id, body: message.body},
           thread_reply_to: nil,
           editing: nil
         )
         |> push_event("set_thread_composer_body", %{body: message.body})}

      true ->
        {:noreply,
         socket
         |> assign(
           editing: %{id: message.id, body: message.body},
           reply_to: nil,
           edit_media: nil,
           thread_editing: nil
         )
         |> push_event("set_composer_body", %{body: message.body})}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, socket |> assign(editing: nil) |> push_event("set_composer_body", %{body: ""})}
  end

  def handle_event("cancel_thread_edit", _params, socket) do
    {:noreply,
     socket |> assign(thread_editing: nil) |> push_event("set_thread_composer_body", %{body: ""})}
  end

  # --- Edit-media modal (#164 PR-2) -------------------------------------------------

  # Toggle-remove a still-kept attachment; removing the last one is allowed (Save just
  # disables until something is staged, so an accidental "remove all" can't post an empty
  # album). Re-open to reset.
  def handle_event("edit_media_remove", %{"att" => att_id}, socket) do
    case socket.assigns.edit_media do
      %{kept: kept} = em ->
        kept = MapSet.delete(kept, safe_int(att_id))
        {:noreply, assign(socket, edit_media: %{em | kept: kept})}

      _ ->
        {:noreply, socket}
    end
  end

  # Cancel a photo staged (but not yet saved) in the edit-media upload.
  def handle_event("edit_media_cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :edit_media, ref)}
  end

  # The upload form's phx-change: LiveView validates staged entries here (caps/accept). Also
  # persist the typed caption into @edit_media so it's server-tracked — otherwise removing a
  # tile (edit_media_remove re-renders the modal) resets the caption input to the original
  # body and the in-progress caption is lost (like #compose-caption's @form[:caption]).
  def handle_event("validate_edit_media", params, socket) do
    case socket.assigns.edit_media do
      %{} = em ->
        caption = params |> Map.get("message", %{}) |> Map.get("body", em.caption)
        {:noreply, assign(socket, edit_media: %{em | caption: caption})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("close_edit_media", _params, socket) do
    {:noreply, cancel_all_edit_media_uploads(socket) |> assign(edit_media: nil)}
  end

  def handle_event("save_edit_media", params, socket) do
    save_edit_media(socket, Map.get(params, "message", %{}))
  end

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
         # Load a window around the root: in a long room the root sits above the loaded
         # page, so without this the client has no row to scroll to (jump silently fails).
         |> load_messages_around(socket.assigns.selected, id)
         |> assign_focus(id)}

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

    # Carry-and-drop forward: dropping from the thread composer forwards INTO this thread.
    if socket.assigns.pending_forward && root,
      do: drop_forward(socket, root.conversation_id, root.id),
      else: send_reply_dispatch(socket, body, reply)
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
      socket = assign(socket, profile: nil)

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
    # A message delivered on a conversation's topic just before we unsubscribed (a fast chat
    # switch A→B) can arrive after B is selected — it must NOT stream into B's window or mark
    # A read (#260). Only handle it for the conversation that's actually open. Other handlers
    # ({:message_edited}, {:thread_reply}, {:message_deleted}) already guard this way.
    if open?(socket, message.conversation_id),
      do: stream_new_message(socket, message),
      else: {:noreply, socket}
  end

  # #164: a message's text/caption was edited — update the row in place (same dom id, no
  # reorder) and refresh the sidebar preview. A thread reply (rooms-only, #57) lives in the
  # :thread stream, NOT the main one — route it there so an edited reply doesn't leak into
  # the main chat (and updates where it actually renders).
  def handle_info({:message_edited, message}, socket) do
    cond do
      not is_nil(message.root_id) ->
        if thread_open_for?(socket, message.root_id),
          do: {:noreply, stream_insert(socket, :thread, message)},
          else: {:noreply, socket}

      # Only restream a message that's in the viewer's loaded window (compacts tracks it,
      # like restream_root_if_loaded): a bare stream_insert of a paginated-out message would
      # APPEND it to the bottom, out of order. It re-renders edited when scrolled into view.
      open?(socket, message.conversation_id) and Map.has_key?(socket.assigns.compacts, message.id) ->
        streamed =
          restore_group_pos(
            socket,
            %{message | compact: Map.get(socket.assigns.compacts, message.id, false)}
          )

        {:noreply,
         socket
         |> stream_insert(:messages, streamed)
         |> maybe_update_thread_root(message)
         |> refresh_sidebar()}

      open?(socket, message.conversation_id) ->
        {:noreply, socket |> maybe_update_thread_root(message) |> refresh_sidebar()}

      true ->
        {:noreply, refresh_sidebar(socket)}
    end
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
       # #136: drop the deleted message's media from an open profile gallery.
       |> maybe_drop_gallery(message)
       # Re-fuse the merged file bubble if a group member was the one deleted.
       |> reshape_group(message.conversation_id, message.group_id)
       |> forget_row(message.id)
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
  def handle_info({:message_hidden, conversation_id, message_id, group_id}, socket) do
    socket =
      if open?(socket, conversation_id),
        do:
          socket
          |> stream_delete_by_dom_id(:messages, "messages-#{message_id}")
          |> stream_delete_by_dom_id(:thread, "thread-#{message_id}")
          |> close_thread_if_root_gone(message_id)
          # Re-fuse the merged file bubble if a group member was hidden.
          |> reshape_group(conversation_id, group_id)
          |> forget_row(message_id),
        else: socket

    {:noreply, put_sidebar_conversation(socket, conversation_id)}
  end

  # A thumbnail finished generating: swap the full image for it, in place. Routes by
  # root_id so a thread reply's thumbnail (#104) updates the thread panel, not the main
  # stream. Guard against a late broadcast arriving after the user switched away.
  def handle_info({:thumbnail_ready, message}, socket) do
    selected = socket.assigns.selected

    if selected && selected.id == message.conversation_id do
      {:noreply, restream_message_in_place(socket, message, socket.assigns.thread_root)}
    else
      {:noreply, socket}
    end
  end

  # A reaction was toggled (anyone, this conversation): re-render the message's
  # chips, restoring its compact flag so the flat row doesn't sprout an avatar.
  def handle_info({:reaction_changed, message}, socket) do
    selected = socket.assigns.selected

    if selected && selected.id == message.conversation_id do
      {:noreply, restream_message_in_place(socket, message, socket.assigns.thread_root)}
    else
      {:noreply, socket}
    end
  end

  # The other participant read up to read_at — refresh delivery ticks. Re-stream
  # without reset so existing rows are morphed in place (keeps an open action menu
  # and any loaded older messages) instead of being torn down and recreated.
  def handle_info({:read, reader_id, read_at}, socket) do
    %{current_scope: scope, selected: conversation} = socket.assigns

    cond do
      is_nil(conversation) ->
        {:noreply, socket}

      reader_id != scope.user.id ->
        # The peer read — advance their marker so our sent DM messages flip to ✓✓.
        # Read receipts are DM-only (#142): rooms (flat layout) render none, and
        # re-streaming the raw list there drops the virtual `compact` flag — every
        # collapsed author header springs back on the sender's screen (#155). So only
        # re-stream where a receipt actually shows; in a room just record the marker.
        socket = assign(socket, other_read_at: read_at)

        if conversation.channel_id do
          {:noreply, socket}
        else
          {:ok, messages} = Chat.list_messages(scope, conversation.id, limit: @page)
          {:noreply, stream(socket, :messages, messages)}
        end

      true ->
        # WE read the open chat (on open, or auto-read when a message arrives while it's open):
        # its unread is now cleared in the DB, so recompute the badges live — the row's own
        # badge, the folder tab badges, and the channel rail — none of which refresh otherwise
        # (#204). Mirrors the increment on {:conversation_activity}, minus the reorder (a read
        # must not bump the chat to the top).
        {:noreply,
         socket
         |> put_sidebar_conversation(conversation.id)
         |> refresh_folders()
         |> refresh_rail()}
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

  # #165: removed from a group. If it's the open one, leave it; otherwise just drop it
  # from the sidebar. Reloads fully (push_navigate) so the group vanishes everywhere.
  def handle_info({:removed_from_conversation, conversation_id}, socket) do
    if open?(socket, conversation_id) do
      {:noreply,
       socket
       |> put_flash(:error, gettext("You were removed from the group."))
       |> push_navigate(to: ~p"/app")}
    else
      {:noreply, refresh_sidebar(socket)}
    end
  end

  # #165: a group's roster/roles changed — refresh the open group's member list + the
  # profile panel (roles, the action matrix, who's listed) in place.
  def handle_info({:group_members_changed, conversation_id}, socket) do
    if open?(socket, conversation_id) do
      {:noreply, reload_selected_members(socket)}
    else
      {:noreply, socket}
    end
  end

  # #165: a group was renamed — update the open header/panel title; the sidebar refresh
  # is driven by the {:conversation_activity} ping (notify_members) on each member's topic.
  def handle_info({:conversation_renamed, conv}, socket) do
    socket = refresh_sidebar(socket)

    if open?(socket, conv.id) do
      {:noreply, assign(socket, selected: %{socket.assigns.selected | title: conv.title})}
    else
      {:noreply, socket}
    end
  end

  # #178: a group's photo changed — same live-refresh as a rename (header/panel from
  # `selected`, sidebar from the re-stream; non-viewers update via {:conversation_activity}).
  def handle_info({:conversation_avatar_changed, conv}, socket) do
    socket = refresh_sidebar(socket)

    if open?(socket, conv.id) do
      {:noreply,
       assign(socket, selected: %{socket.assigns.selected | avatar_key: conv.avatar_key})}
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
    # Header status + open profile read @statuses (plain assigns) and refresh on
    # this update for free. The sidebar dots live in a `phx-update="stream"` list,
    # so they need a re-stream (#10) — but only when a conversation *peer's* status
    # actually changed; otherwise skip the per-diff DB re-query, since presence is
    # one global topic and every connect/nav by anyone fans a diff to all sessions
    # (#94 review). A status-only change (away↔online) lands in the diff's
    # joins+leaves keys too, so the same gate catches it. No-op in channel mode
    # (rooms show no per-message presence dot).
    socket = assign(socket, statuses: EdenWeb.Presence.statuses())
    changed = presence_changed_ids(payload)
    socket = stamp_peer_offline(socket, changed)
    peers = socket.assigns.sidebar_peer_ids

    if socket.assigns.channel || Enum.all?(changed, &(&1 not in peers)) do
      {:noreply, socket}
    else
      {:noreply, stream_conversations(socket, [])}
    end
  end

  # The user changed their own status (this tab's set_status, another tab, or the
  # Settings page) — all funnel through the per-user presence topic (#102). Mirror
  # it onto this connection's tracked presence and own UI so every session agrees.
  def handle_info({:presence_status_changed, status}, socket) do
    scope = socket.assigns.current_scope
    # Keep current_scope.user in step with the new status so nothing downstream
    # re-derives presence from a stale struct (#102 review).
    scope = %{scope | user: %{scope.user | presence_status: status}}

    socket =
      socket
      |> assign(current_scope: scope, my_status: status)
      |> apply_presence()

    {:noreply, assign(socket, statuses: EdenWeb.Presence.statuses())}
  end

  # "Last seen" heartbeat (#102): refresh last_active_at while online (any non-
  # invisible session, idle or not — they're still "в сети"), then reschedule.
  def handle_info(:touch_active, socket) do
    socket = touch_if_visible(socket)
    Process.send_after(self(), :touch_active, @touch_active_ms)
    {:noreply, socket}
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
      <%!-- Auto-away (#102): reports this session idle/active to the server. --%>
      <div id="idle-tracker" phx-hook=".IdleTracker" hidden></div>
      <%!-- Carry-and-drop forward: re-hydrates the plaque from sessionStorage on every mount,
            so a carried message survives navigation across DMs, rooms and channels. --%>
      <div id="forward-carry" phx-hook=".ForwardCarry" hidden></div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ForwardCarry">
        export default {
          mounted() {
            // Re-hydrate: if messages are being carried, re-arm the server-side plaque with
            // the ids kept across this navigation/remount.
            let ids = []
            try { ids = JSON.parse(sessionStorage.getItem("ed:carry") || "[]") } catch (_e) {}
            // Tolerate a malformed / legacy single-id value (JSON.parse("123") → a number).
            if (!Array.isArray(ids)) ids = ids ? [ids] : []
            if (ids.length) this.pushEvent("forward_rehydrate", { ids })
            this.handleEvent("carry_set", ({ ids }) =>
              sessionStorage.setItem("ed:carry", JSON.stringify(ids)),
            )
            this.handleEvent("carry_clear", () => sessionStorage.removeItem("ed:carry"))
          },
        }
      </script>
      <%!-- Notification renderer host (#215 sound / #217 desktop), shared with every
            authed page via EdenWeb.Notifier + NotifyHook (#272). --%>
      <.notifier prefs={@notify_prefs} />
      <%!-- Tab unread badge (#216): reflects total unread (DMs/groups + unmuted channels)
            in the browser tab as a "(N)" title prefix, so a backgrounded tab shows there's
            something waiting. data-count is recomputed on every rail refresh. --%>
      <div
        id="tab-badge"
        phx-hook=".TabBadge"
        data-count={tab_unread_total(@messenger_unread, @channels)}
        hidden
      >
      </div>
      <%!-- Below the header so it never covers the header buttons; the wrapper
            ignores pointer events so only the toast itself is interactive. --%>
      <div class="fixed top-20 left-1/2 -translate-x-1/2 z-40 w-full max-w-sm px-4 pointer-events-none">
        <.ed_flash flash={@flash} />
      </div>

      <%!-- Discord-style shell: the messenger is the rail's top-left item. On
            mobile the rail hides with the sidebar while a chat is open. --%>
      <.rail
        channels={@channels}
        messenger_unread={@messenger_unread}
        active={(@channel && @channel.id) || :messenger}
        class={@selected && "hidden md:flex"}
        me={@current_scope.user}
        my_status={@my_status}
        my_dot={rail_dot_status(@my_status, @idle?)}
      />

      <aside
        :if={@channel}
        class={[
          "flex-1 min-w-0 md:flex-none md:w-80 border-r flex flex-col",
          @selected && "hidden md:flex"
        ]}
        style="background: var(--ed-surface); border-color: var(--ed-border);"
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
        style="background: var(--ed-surface); border-color: var(--ed-border);"
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
          <div id="conversations" phx-hook=".SidebarReorder" phx-update="stream" class="space-y-0.5">
            <.conversation_item
              :for={{dom_id, conversation} <- @streams.conversations}
              id={dom_id}
              conversation={conversation}
              user={@current_scope.user}
              statuses={@statuses}
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
            statuses={@statuses}
          />
        </div>
      </aside>

      <main
        id="chat-dropzone"
        phx-hook=".DropZone"
        class={
          [
            "ed-dropzone flex-1 flex flex-col min-w-0",
            # Hidden on mobile when no room is open — UNLESS a private-room knock
            # window is pending (it lives in here; without this it'd be invisible on
            # mobile, #91). selected is nil during a knock, so guard on knock_room.
            !@selected && is_nil(@knock_room) && "hidden md:flex"
          ]
        }
        style="background: var(--ed-bg);"
      >
        <.drop_overlay label={gettext("Drop files to send")} />
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
              phx-click="open_profile"
              aria-label={gettext("View profile")}
            >
              <.avatar
                name={title(@selected, @current_scope.user)}
                src={conversation_avatar_src(@selected, @current_scope.user)}
                status={peer_status(@selected, @current_scope.user, @statuses)}
                size={:sm}
              />
              <div class="min-w-0">
                <div class="font-semibold truncate" style="font-size:0.9375rem;">
                  {title(@selected, @current_scope.user)}
                </div>
                <div
                  :if={not @selected.is_group}
                  style={"font-size:0.6875rem; color: var(#{status_color_var(peer_status(@selected, @current_scope.user, @statuses))});"}
                >
                  <%= if status = peer_status(@selected, @current_scope.user, @statuses) do %>
                    {status_label(status)}
                  <% else %>
                    <.last_seen peer={peer(@selected, @current_scope.user)} />
                  <% end %>
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
                the top of the message area, each result is a permalink.
                The SLOT is always rendered (stable sibling) — toggling the bar with
                a bare `:if` here made morphdom detach #message-scroll to re-insert it,
                which reset its scrollTop to 0 (chat jumped to the top on open/close).
                Only the bar's CONTENTS toggle now, so the scroller never moves. --%>
          <div id="room-search-slot" class="shrink-0">
            <div :if={@room_search_open and @selected.channel_id} class="relative">
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
          </div>

          <%!-- Localized lightbox button labels (#95 review): gettext isn't reachable
                inside the colocated .Lightbox hook, so the hook reads these. --%>
          <div
            class="flex-1 overflow-y-auto overscroll-x-contain p-4"
            id="message-scroll"
            phx-hook=".ScrollBottom"
            data-conversation-id={@selected.id}
            data-has-more={to_string(@has_more)}
            data-focus-id={@focus_id}
            data-focus-nonce={@focus_nonce}
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
              class={[
                "flex flex-col",
                (@selected.channel_id && "ed-flat-list") || "gap-2",
                (@selection != nil and @select_surface == :main) && "ed-selecting"
              ]}
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
                    statuses={@statuses}
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
            <%!-- Room empty-state (#154), shown while #messages holds no streamed rows. It MUST
                  live OUTSIDE the stream container (CSS :has() on the sibling reveals it): a
                  non-stream child inside #messages breaks LiveView's append anchoring — with
                  .DateRail's ds-* separators present, appended messages land at the TOP of the
                  list instead of the bottom (the "forward/message only shows after refresh"
                  bug). Rooms only (DMs / threads carry their own placeholders). --%>
            <div :if={@selected.channel_id} id="messages-empty" role="status" class="ed-room-empty">
              <div class="ed-room-empty__medallion" aria-hidden="true">
                <.icon name="hero-chat-bubble-left-right" class="size-7" />
              </div>
              <p class="ed-room-empty__title">{gettext("No messages yet")}</p>
              <p class="ed-room-empty__sub">
                {gettext("Be the first to post in #%{room}.", room: @selected.name)}
              </p>
            </div>
            <%!-- Optimistic, not-yet-acked sends live here (JS-managed; LiveView leaves it alone). --%>
            <div class="flex flex-col gap-2 mt-2" id="pending-messages" phx-update="ignore"></div>
          </div>
          <%!-- Live presence for the flat message list (#102): the rows live in a
                `phx-update="stream"` container, so a server re-render never reaches
                existing avatars' dots. This sibling carries the current statuses
                map; the .RoomPresence hook re-applies dot classes by user id on
                every change. Rooms only. --%>
          <div
            :if={@selected.channel_id}
            id="room-presence"
            phx-hook=".RoomPresence"
            data-statuses={Jason.encode!(Map.take(@statuses, room_member_ids(@selected)))}
            hidden
          >
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

          <.selection_bar
            :if={@selection != nil and @select_surface == :main}
            selection={@selection}
            confirming={@sel_delete != nil}
            container="#messages"
          />

          <.form
            for={@composer}
            id="composer"
            phx-hook=".SendQueue"
            data-conversation-id={@selected.id}
            data-layout={if @selected.channel_id, do: "flat", else: "bubble"}
            data-is-group={to_string(@selected.is_group)}
            data-sender-id={@current_scope.user.id}
            data-sender-name={@current_scope.user.display_name}
            data-dbl-react={@my_dbl}
            data-max-body={Chat.Message.max_body()}
            data-max-album={Chat.max_album_entries()}
            data-max-staged={Chat.max_staged_entries()}
            data-sending-media={to_string(@sending_media)}
            data-failed={gettext("Not delivered")}
            data-resend={gettext("Resend")}
            data-delete={gettext("Delete")}
            data-resend-many={gettext("Resend {count} messages")}
            data-not-sent={gettext("Not sent")}
            data-sending-label={gettext("Sending {name}")}
            data-cancel-label={gettext("Cancel upload")}
            data-queued-label={gettext("In queue")}
            phx-submit="send"
            phx-change="composer_changed"
            class={[
              "flex flex-col gap-2 p-3 border-t shrink-0",
              (@selection != nil and @select_surface == :main) && "hidden"
            ]}
            style="border-color: var(--ed-border);"
          >
            <%!-- Forward carry: the message being carried. data-forward-active defers the send
                  to the server (drop_forward) — Send drops it into THIS conversation. Survives
                  navigation via the .ForwardCarry hook (sessionStorage). --%>
            <div
              :if={@pending_forward}
              class="ed-reply-bar ed-reply-bar--forward"
              data-forward-active
              phx-window-keydown="cancel_forward"
              phx-key="Escape"
            >
              <span class="ed-reply-bar__accent" aria-hidden="true"></span>
              <div class="ed-reply-bar__body">
                <span class="ed-reply-bar__name">
                  <.icon name="hero-arrow-uturn-right-micro" class="size-3.5" />
                  {gettext("Forwarding: pick a chat and send")}
                </span>
                <span class="ed-reply-bar__text">{forward_plaque_label(@pending_forward)}</span>
              </div>
              <button
                type="button"
                class="ed-btn--icon shrink-0"
                phx-click="cancel_forward"
                aria-label={gettext("Cancel forward")}
              >
                <.icon name="hero-x-mark-micro" class="size-4" />
              </button>
            </div>
            <%!-- Edit tray (#164): the message being edited. data-edit-active defers the
                  send to the server (edit_message) — an edit updates an existing row, so
                  there's no optimistic node and no hidden field (the id lives in @editing). --%>
            <div
              :if={@editing}
              class="ed-reply-bar ed-reply-bar--edit"
              data-edit-active
              phx-window-keydown="cancel_edit"
              phx-key="Escape"
            >
              <span class="ed-reply-bar__accent" aria-hidden="true"></span>
              <div class="ed-reply-bar__body">
                <span class="ed-reply-bar__name">
                  <.icon name="hero-pencil-square-micro" class="size-3.5" />
                  {gettext("Editing")}
                </span>
                <span class="ed-reply-bar__text">{@editing.body}</span>
              </div>
              <button
                type="button"
                class="ed-btn--icon shrink-0"
                phx-click="cancel_edit"
                aria-label={gettext("Cancel edit")}
              >
                <.icon name="hero-x-mark-micro" class="size-4" />
              </button>
            </div>
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
            <%!-- Dedicated Resend upload input (#…): always present + never inert, so a
                  failed-card Resend can feed cloned Files into the pristine :attachment_retry
                  config (auto_upload) at any time — even while the compose modal is open. --%>
            <.live_file_input upload={@uploads.attachment_retry} class="sr-only" tabindex="-1" />
            <%!-- Sequential send input (TG-attachments): the client feeds one clone at a time
                  here (auto_upload) so a batch uploads item-by-item instead of concurrently.
                  Always present + never inert, like the Resend input. --%>
            <.live_file_input upload={@uploads.attachment_seq} class="sr-only" tabindex="-1" />
            <%!-- Composer bar: attach + message + emoji + send. ALWAYS rendered (#130)
                  so it never vanishes/jumps — the compose modal (below) floats on top
                  of it when files are staged, instead of replacing it. While that modal
                  is open the bar goes `inert` (non-interactive + unfocusable, "second
                  plane") so the caption is the only live input and nothing leaks here. --%>
            <div
              class="flex items-center gap-2"
              inert={live_entries(@uploads.attachment) != [] and not @sending_media}
            >
              <%!-- Attach stays live while a send uploads (#119): picking the next batch
                    queues it client-side (the SendQueue hook intercepts the pick, holds the
                    Files off the shared :attachment config, and feeds them in once the
                    in-flight send frees the config). Only ONE batch is ever in the config,
                    so the #95 single-in-flight invariant (exact progress average + FIFO
                    swap) still holds — only the visible block is gone. --%>
              <label
                class="ed-btn--icon cursor-pointer"
                aria-label={gettext("Attach a file")}
              >
                <.icon name="hero-paper-clip-micro" class="size-5" />
                <%!-- sr-only (not hidden) keeps the input focusable / keyboard-reachable.
                      Only ONE live_file_input may exist per upload (same id) — when the
                      compose modal is open it owns "Add more", so the bar's drops out
                      (#130). The bar is behind the scrim then anyway. --%>
                <.live_file_input
                  :if={live_entries(@uploads.attachment) == [] or @sending_media}
                  upload={@uploads.attachment}
                  class="sr-only"
                />
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
                class="ed-btn ed-btn--primary ed-btn--send shrink-0"
                type="submit"
                aria-label={gettext("Send")}
              >
                <.icon name="hero-paper-airplane-micro" class="size-4" />
              </button>
            </div>
            <%!-- Attachment compose modal (#58): floats on TOP of the always-present
                  bar when files are staged (#130) — no longer replaces it, so the bar
                  never vanishes. Its caption is a SEPARATE field (name="message[caption]"),
                  so it never mirrors into the bar's chat input (name="message[body]").
                  data-upload-preview routes the send through the SendQueue media path. --%>
            <.compose_overlay
              :if={live_entries(@uploads.attachment) != [] and not @sending_media}
              upload={@uploads.attachment}
              form={@composer}
              editing={@editing != nil}
            />
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
      <aside
        :if={@thread_root && @selected}
        id="thread-dropzone"
        phx-hook=".DropZone"
        class="ed-dropzone ed-thread"
        aria-label={gettext("Thread")}
      >
        <.drop_overlay label={gettext("Drop files into the thread")} />
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
          <%!-- Search within this thread's replies (#189): separate from the
                room's main-stream search. --%>
          <button
            type="button"
            class={["ed-btn--icon", @thread_search_open && "ed-btn--icon--on"]}
            phx-click="toggle_thread_search"
            title={gettext("Search in thread")}
            aria-label={gettext("Search in thread")}
            aria-expanded={to_string(@thread_search_open)}
          >
            <.icon name="hero-magnifying-glass-mini" class="size-5" />
          </button>
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

        <%!-- In-thread search (#189): a bar under the header; each result is a permalink
              into the open thread (opens + focuses the reply, then closes this panel).
              Stable slot (see #room-search-slot): a bare `:if` here let morphdom detach
              #thread-scroll on toggle and reset its scrollTop to 0. --%>
        <div id="thread-search-slot" class="shrink-0">
          <div :if={@thread_search_open} class="relative">
            <form
              class="ed-search"
              style="margin-bottom: 0;"
              phx-change="thread_search"
              phx-submit="thread_search"
            >
              <.icon name="hero-magnifying-glass-micro" class="size-4 shrink-0" />
              <input
                type="search"
                name="q"
                value={@thread_search}
                placeholder={gettext("Search in thread")}
                autocomplete="off"
                class="ed-search__input"
                phx-debounce="200"
                phx-mounted={JS.focus()}
                aria-label={gettext("Search in thread")}
              />
              <button
                type="button"
                class="ed-btn--icon"
                phx-click="toggle_thread_search"
                aria-label={gettext("Close search")}
              >
                <.icon name="hero-x-mark-micro" class="size-4" />
              </button>
            </form>
            <div :if={String.trim(@thread_search) != ""} class="ed-room-search__panel">
              <p
                :if={(@thread_results || []) == []}
                class="text-center py-6"
                style="color: var(--ed-muted); font-size:0.875rem;"
              >
                {gettext("No results for “%{query}”", query: String.trim(@thread_search))}
              </p>
              <.link
                :for={message <- @thread_results || []}
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
                    <.highlighted text={snippet(message.body, @thread_search)} query={@thread_search} />
                  </span>
                </span>
              </.link>
            </div>
          </div>
        </div>

        <div
          class="flex-1 overflow-y-auto overscroll-x-contain p-4"
          id="thread-scroll"
          phx-hook=".ScrollBottom"
          data-pending-id="thread-pending"
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
            statuses={@statuses}
          />
          <div class="ed-thread__sep">
            {ngettext("%{count} reply", "%{count} replies", @thread_root.reply_count)}
          </div>
          <div
            class={[
              "flex flex-col ed-flat-list",
              (@selection != nil and @select_surface == :thread) && "ed-selecting"
            ]}
            id="thread-replies"
            phx-update="stream"
          >
            <.flat_message
              :for={{dom_id, reply} <- @streams.thread}
              id={dom_id}
              message={reply}
              conversation_id={@selected.id}
              mine={reply.sender_id == @current_scope.user.id}
              me={@current_scope.user.id}
              quick={@my_quick}
              in_thread
              statuses={@statuses}
            />
          </div>
          <%!-- Optimistic "not delivered" thread replies live here (#142, JS-managed by
                .ThreadSendQueue). The .ScrollBottom riser (data-pending-id above) drops a
                node from here when its real reply streams into #thread-replies. --%>
          <div class="flex flex-col ed-flat-list" id="thread-pending" phx-update="ignore"></div>
        </div>

        <%!-- Thread typing indicator (#103): only peers typing IN THIS thread. --%>
        <.typing_row typers={@thread_typing_users} />

        <%!-- Multi-select in the thread panel: the bar replaces the reply composer, and drives
              #thread-replies (not the room's #messages). --%>
        <.selection_bar
          :if={@selection != nil and @select_surface == :thread}
          selection={@selection}
          confirming={@sel_delete != nil}
          container="#thread-replies"
          compact
        />

        <.form
          for={@reply_composer}
          id="reply-composer"
          phx-hook=".ThreadSendQueue"
          data-thread-root={@thread_root && @thread_root.id}
          data-failed={gettext("Not delivered")}
          data-resend={gettext("Resend")}
          data-delete={gettext("Delete")}
          data-resend-many={gettext("Resend {count} messages")}
          phx-change="reply_changed"
          phx-submit="send_reply"
          class={[
            "flex flex-col gap-2 p-3 border-t shrink-0",
            (@selection != nil and @select_surface == :thread) && "hidden"
          ]}
          style="border-color: var(--ed-border);"
        >
          <%!-- Forward carry in a thread: dropping from here forwards INTO this thread.
                `.ed-reply-bar` makes .ThreadSendQueue.onSubmit defer (no optimistic node). --%>
          <div
            :if={@pending_forward}
            class="ed-reply-bar ed-reply-bar--forward"
            data-forward-active
            phx-window-keydown="cancel_forward"
            phx-key="Escape"
          >
            <span class="ed-reply-bar__accent" aria-hidden="true"></span>
            <div class="ed-reply-bar__body">
              <span class="ed-reply-bar__name">
                <.icon name="hero-arrow-uturn-right-micro" class="size-3.5" />
                {gettext("Forwarding: send to add it here")}
              </span>
              <span class="ed-reply-bar__text">{forward_plaque_label(@pending_forward)}</span>
            </div>
            <button
              type="button"
              class="ed-btn--icon shrink-0"
              phx-click="cancel_forward"
              aria-label={gettext("Cancel forward")}
            >
              <.icon name="hero-x-mark-micro" class="size-4" />
            </button>
          </div>
          <%!-- Thread edit tray (#164): editing a thread reply. `.ed-reply-bar` makes
                .ThreadSendQueue.onSubmit defer to the server (send_reply → edit_message),
                so there's no optimistic node; the id lives in @thread_editing. --%>
          <div
            :if={@thread_editing}
            class="ed-reply-bar ed-reply-bar--edit"
            data-edit-active
            phx-window-keydown="cancel_thread_edit"
            phx-key="Escape"
          >
            <span class="ed-reply-bar__accent" aria-hidden="true"></span>
            <div class="ed-reply-bar__body">
              <span class="ed-reply-bar__name">
                <.icon name="hero-pencil-square-micro" class="size-3.5" />
                {gettext("Editing")}
              </span>
              <span class="ed-reply-bar__text">{@thread_editing.body}</span>
            </div>
            <button
              type="button"
              class="ed-btn--icon shrink-0"
              phx-click="cancel_thread_edit"
              aria-label={gettext("Cancel edit")}
            >
              <.icon name="hero-x-mark-micro" class="size-4" />
            </button>
          </div>
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
          <%!-- Staged thread-reply album (#104): a compact thumbnail tray; the reply
                input below doubles as the caption. Sends as one album on submit. --%>
          <div :if={@uploads.thread_attachment.entries != []} class="ed-thread-tray">
            <div
              :for={entry <- @uploads.thread_attachment.entries}
              class="ed-thread-tray__item"
              data-key={"#{entry.client_name}:#{entry.client_size}:#{entry.client_last_modified}"}
            >
              <.live_img_preview
                :if={image_entry?(entry)}
                entry={entry}
                class="ed-thread-tray__img"
              />
              <span :if={video_entry?(entry)} class="ed-thread-tray__file" aria-hidden="true">
                <.icon name="hero-film" class="size-5" />
              </span>
              <span :if={!media_entry?(entry)} class="ed-thread-tray__file" aria-hidden="true">
                <.icon name={entry_icon(entry)} class="size-5" />
              </span>
              <button
                type="button"
                class="ed-thread-tray__remove"
                phx-click="cancel_upload"
                phx-value-ref={entry.ref}
                phx-value-upload="thread_attachment"
                aria-label={gettext("Remove %{name}", name: entry.client_name)}
              >
                <.icon name="hero-x-mark-micro" class="size-3" />
              </button>
            </div>
          </div>
          <p :for={{name, err} <- compose_errors(@uploads.thread_attachment)} class="ed-attach-err">
            {name}: {upload_error_text(err)}
          </p>
          <div class="flex items-center gap-2">
            <label class="ed-btn--icon cursor-pointer shrink-0" aria-label={gettext("Attach a file")}>
              <.icon name="hero-paper-clip-micro" class="size-5" />
              <.live_file_input upload={@uploads.thread_attachment} class="sr-only" />
            </label>
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
              phx-hook=".PasteUpload"
            />
            <%!-- Fixed-width circle matching the main composer's send button, so the
                  icon never reflows. (No phx-disable-with: on an icon-only button it
                  swaps the glyph for text and the button visibly shrinks — #104.) --%>
            <button
              class="ed-btn ed-btn--primary ed-btn--send shrink-0"
              type="submit"
              aria-label={gettext("Send")}
            >
              <.icon name="hero-paper-airplane-micro" class="size-4" />
            </button>
          </div>
        </.form>
      </aside>

      <%!-- Conversation profile (#136): the DM peer's card OR the group's card + members,
            plus a per-dialog media gallery. DM + groups (never rooms — channel_id guards the
            header), so it never collides with the rooms-only thread panels above; shares the
            RHS aside slot (full-screen on mobile). --%>
      <.conv_profile_panel
        :if={@profile_open && @selected}
        conversation={@selected}
        peer={@profile_peer}
        user={@current_scope.user}
        group_renaming={@group_renaming}
        upload={@uploads.group_avatar}
        statuses={@statuses}
        tab={@gallery_tab}
        media={@gallery_media}
        more={@gallery_more}
      />

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
      <.profile_popover
        :if={@profile}
        user={@profile}
        status={status_of(@profile.id, @statuses)}
        self={@profile.id == @current_scope.user.id}
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
        statuses={@statuses}
      />
      <.channel_members_modal
        :if={@members_open && @channel}
        members={@members}
        channel={@channel}
        me={@current_scope.user}
        statuses={@statuses}
      />
      <.add_members_modal
        :if={@add_open}
        addable={@addable}
        selected={@add_selected}
        statuses={@statuses}
      />
      <.invites_modal :if={@invites_open && @channel} invites={@invites} new_url={@new_invite_url} />
      <.edit_media_modal :if={@edit_media} edit_media={@edit_media} upload={@uploads.edit_media} />
      <.delete_confirm :if={@sel_delete} sel_delete={@sel_delete} />

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
      <script :type={Phoenix.LiveView.ColocatedHook} name=".RoomPresence">
        // Live presence for the flat message list (#102). The rows sit in a
        // phx-update="stream" container, so the server never re-renders an
        // existing avatar's dot. This host carries data-statuses (a {uid: status}
        // map) that DOES re-render on every change; on each update we re-apply the
        // dot class to every managed dot ([data-presence-uid]) by user id. The
        // initial server render already sets the right class, so there is no flash.
        export default {
          mounted() { this.apply() },
          updated() { this.apply() },
          apply() {
            let map = {}
            try { map = JSON.parse(this.el.dataset.statuses || "{}") } catch (e) { return }
            document
              .querySelectorAll("#messages [data-presence-uid], #thread-replies [data-presence-uid]")
              .forEach((dot) => {
                const s = map[dot.dataset.presenceUid] || null
                dot.classList.toggle("ed-avatar__dot--hidden", !s)
                dot.classList.toggle("ed-avatar__dot--away", s === "away")
                dot.classList.toggle("ed-avatar__dot--dnd", s === "dnd")
              })
          }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".TabBadge">
        // #216: reflect total unread in the browser tab as a "(N) " prefix on the title, so a
        // backgrounded tab shows there's something waiting. The count rides data-count (recomputed
        // server-side on every unread change). The title is kept in sync with live_title via a
        // MutationObserver: live_title rewrites <title> on navigation, which would otherwise drop
        // our prefix. NOTE (was a favicon dot too): dynamically rewriting the favicon <link> is
        // unreliable across browsers — Firefox caches it, so the dot would stick after the count
        // cleared and the brand mark wouldn't reliably show. The favicon now stays the static
        // brand icon from the layout (never touched here); the title carries the count.
        export default {
          mounted() {
            this.titleEl = document.querySelector("title")
            this.apply()
            this.obs = new MutationObserver(() => this.apply())
            if (this.titleEl) {
              this.obs.observe(this.titleEl, { childList: true, characterData: true, subtree: true })
            }
          },
          updated() { this.apply() },
          destroyed() {
            if (this.obs) this.obs.disconnect()
            this.apply(0)
          },
          count() { return parseInt(this.el.dataset.count || "0", 10) || 0 },
          apply(force) {
            const n = force === 0 ? 0 : this.count()
            // Strip any prefix we added so we re-read the base title live_title set.
            const base = document.title.replace(/^\(\d+\+?\)\s+/, "")
            const next = n > 0 ? "(" + (n > 99 ? "99+" : n) + ") " + base : base
            if (document.title !== next) document.title = next // re-fires the observer; the
            // guard above makes the second pass a no-op (base strips back to the same string).
          },
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".IdleTracker">
        // Auto-away (#102): after IDLE_MS of no input this session reports idle;
        // the next activity reports active. Only transitions are pushed (no spam),
        // and the server only acts on it for "auto" users.
        export default {
          mounted() {
            this.IDLE_MS = 10 * 60 * 1000
            this.idle = false
            // Match the server's mount default (tab_visible: true) so we only push on a real
            // change, not on every mount.
            this.active = true
            this.events = ["mousemove", "keydown", "wheel", "touchstart", "click", "scroll"]
            this.bump = () => {
              clearTimeout(this.timer)
              if (this.idle) { this.idle = false; this.pushEvent("presence_active", {}) }
              this.timer = setTimeout(() => {
                this.idle = true
                this.pushEvent("presence_idle", {})
              }, this.IDLE_MS)
            }
            // "Actively looking here" = the tab is visible AND the window has focus. document.hidden
            // alone misses an alt-tab to ANOTHER APP (the tab stays "visible"), which is exactly when
            // an OPEN chat should still ping you — otherwise it suppresses its own notification while
            // you're not even in the browser (#206 follow-up). Drives tab_visible/tab_hidden, which
            // gate notification suppression AND auto-read. Pushed only on a real change.
            this.syncActive = () => {
              const active = !document.hidden && document.hasFocus()
              if (active === this.active) return
              this.active = active
              this.pushEvent(active ? "tab_visible" : "tab_hidden", {})
              if (active) this.bump()
            }
            // Auto-away to OTHERS tracks the tab being HIDDEN (switched/minimized), not a mere window
            // blur: briefly alt-tabbing to another app shouldn't broadcast "away" — you're still here.
            this.onVisibility = () => {
              if (document.hidden) {
                clearTimeout(this.timer)
                if (!this.idle) { this.idle = true; this.pushEvent("presence_idle", {}) }
              }
              this.syncActive()
            }
            this.events.forEach((e) => window.addEventListener(e, this.bump, { passive: true }))
            document.addEventListener("visibilitychange", this.onVisibility)
            window.addEventListener("blur", this.syncActive)
            window.addEventListener("focus", this.syncActive)
            this.bump()
            this.syncActive()
          },
          destroyed() {
            clearTimeout(this.timer)
            this.events.forEach((e) => window.removeEventListener(e, this.bump))
            document.removeEventListener("visibilitychange", this.onVisibility)
            window.removeEventListener("blur", this.syncActive)
            window.removeEventListener("focus", this.syncActive)
          }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".LastSeen">
        // "last seen" timestamp (#102), formatted in the viewer's locale: just the
        // time when today, otherwise a short date + time so it's never ambiguous.
        export default {
          mounted() { this.fmt() },
          updated() { this.fmt() },
          fmt() {
            const d = new Date(this.el.getAttribute("datetime"))
            if (isNaN(d)) return
            const sameDay = d.toDateString() === new Date().toDateString()
            this.el.textContent = sameDay
              ? d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
              : d.toLocaleString([], { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" })
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
      <script :type={Phoenix.LiveView.ColocatedHook} name=".FocusTrap">
        // Modal a11y: move focus into the dialog on open, keep Tab cycling within
        // it, and restore focus to the trigger on close. For role=dialog panels.
        export default {
          mounted() {
            this._prev = document.activeElement
            const f = this._focusables()
            ;(f[0] || this.el).focus()
            this._onKey = (e) => {
              if (e.key !== "Tab") return
              const els = this._focusables()
              if (!els.length) { e.preventDefault(); this.el.focus(); return }
              const first = els[0], last = els[els.length - 1], a = document.activeElement
              if (e.shiftKey && (a === first || a === this.el)) { e.preventDefault(); last.focus() }
              else if (!e.shiftKey && a === last) { e.preventDefault(); first.focus() }
            }
            this.el.addEventListener("keydown", this._onKey)
          },
          destroyed() {
            this.el.removeEventListener("keydown", this._onKey)
            if (this._prev && this._prev.focus) this._prev.focus()
          },
          _focusables() {
            return [...this.el.querySelectorAll(
              'a[href],button:not([disabled]),textarea:not([disabled]),input:not([disabled]),select:not([disabled]),[tabindex]:not([tabindex="-1"])'
            )].filter((el) => el.offsetParent !== null)
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
      <script :type={Phoenix.LiveView.ColocatedHook} name=".GalleryTabs">
        // Profile media-gallery tabs (#136): slide a cobalt underline under the active tab
        // (the panel persists across tab clicks, so it transitions rather than teleports) and
        // wire ←/→ keyboard navigation per the APG tabs pattern (roving tabindex on the server).
        export default {
          mounted() {
            this.indicator = this.el.querySelector("[data-gallery-indicator]")
            this.place(false)
            this.ro = new ResizeObserver(() => this.place(false))
            this.ro.observe(this.el)
            this.onKeyBound = (e) => this.onKey(e)
            this.el.addEventListener("keydown", this.onKeyBound)
          },
          updated() { this.place(true) },
          destroyed() {
            this.ro && this.ro.disconnect()
            this.el.removeEventListener("keydown", this.onKeyBound)
          },
          onKey(e) {
            if (e.key !== "ArrowLeft" && e.key !== "ArrowRight") return
            const tabs = [...this.el.querySelectorAll('[role="tab"]')]
            const i = tabs.findIndex((t) => t.getAttribute("aria-selected") === "true")
            if (i < 0) return
            e.preventDefault()
            const n = tabs.length
            const next = e.key === "ArrowRight" ? (i + 1) % n : (i - 1 + n) % n
            tabs[next].focus()
            tabs[next].click()
          },
          place(animate) {
            const active = this.el.querySelector(".ed-gallery-tab--on")
            if (!active || !this.indicator) return
            // offsetLeft is relative to the sticky tab bar (its offsetParent), so the
            // underline tracks the active tab even when the bar scrolls horizontally.
            this.indicator.style.transition = animate ? "" : "none"
            this.indicator.style.width = `${active.offsetWidth}px`
            this.indicator.style.transform = `translateX(${active.offsetLeft}px)`
            this.indicator.style.opacity = "1"
            if (!animate) {
              void this.indicator.offsetWidth
              this.indicator.style.transition = ""
            }
          }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".GalleryMonths">
        // Profile gallery month dividers (#136): groups the photo/video grid by month in the
        // viewer's LOCAL timezone from each tile's data-ts (UTC unix), like the message
        // DateRail (#83) — so a busy gallery stays scannable. Re-derived on every patch
        // (pagination append, live prepend, tab switch) since morphdom drops injected nodes.
        export default {
          mounted() {
            this.locale = this.el.dataset.locale || undefined
            this.reconcile()
          },
          updated() { this.reconcile() },
          reconcile() {
            this.el.querySelectorAll(".ed-gallery-month").forEach((h) => h.remove())
            const thisYear = new Date().getFullYear()
            let last = null
            for (const tile of [...this.el.querySelectorAll("[data-ts]")]) {
              const d = new Date(Number(tile.dataset.ts) * 1000)
              const key = `${d.getFullYear()}-${d.getMonth()}`
              if (key === last) continue
              last = key
              const opts = d.getFullYear() === thisYear
                ? { month: "long" }
                : { month: "long", year: "numeric" }
              let label = d.toLocaleDateString(this.locale, opts)
              label = label.charAt(0).toUpperCase() + label.slice(1)
              const h = document.createElement("div")
              h.className = "ed-gallery-month"
              h.setAttribute("role", "heading")
              h.setAttribute("aria-level", "3")
              h.textContent = label
              this.el.insertBefore(h, tile)
            }
          }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".SidebarReorder">
        // FLIP reorder for the DM sidebar (#194): when a chat bumps to the top on new activity
        // the server delete+re-inserts its row, so it's a fresh node at index 0. Instead of
        // teleporting, animate the swap: beforeUpdate snapshots each row's First top by dom-id;
        // updated measures Last and plays the inverse via the Web Animations API (compositor-only,
        // interruption-safe). The bumped row is matched by its STABLE dom-id, so it rises from its
        // old slot while the displaced rows ease down (the space opening above it). Rows that did
        // not move animate nothing; reduced-motion skips the animation (instant reorder).
        export default {
          rows() {
            return [...this.el.children].filter((c) => c.id && c.id.startsWith("conversations-"))
          },
          beforeUpdate() {
            // Each row's top RELATIVE to the list container, so a shift of the whole list (the
            // folder tabs above re-rendering) cancels out and only a real reorder registers.
            const base = this.el.getBoundingClientRect().top
            this.first = new Map()
            this.firstOrder = this.rows().map((r) => r.id).join(",")
            for (const row of this.rows()) this.first.set(row.id, row.getBoundingClientRect().top - base)
          },
          updated() {
            const first = this.first
            this.first = null
            if (!first || window.matchMedia("(prefers-reduced-motion: reduce)").matches) return
            // Animate ONLY a pure reorder: same SET of chats, different order. An unchanged order
            // is a no-op (re-send into the chat already on top); a changed SET is a folder switch
            // / new chat / filter, where morphdom repositioning the shared rows must not look like
            // a bump (#194).
            const ids = this.rows().map((r) => r.id)
            if (ids.join(",") === this.firstOrder) return
            if (ids.slice().sort().join(",") !== [...first.keys()].sort().join(",")) return
            const base = this.el.getBoundingClientRect().top
            // Animate the LIVE node refs (not getElementById — a delete+insert can leave the old
            // node briefly resolvable). The bumped row is a fresh node at the top: its First is
            // its OLD slot, so it RISES; the row it passed is pushed DOWN — a clean cross.
            const moves = []
            for (const row of this.rows()) {
              const f = first.get(row.id)
              if (f == null) continue // a brand-new conversation: let it appear, no FLIP
              const delta = f - (row.getBoundingClientRect().top - base)
              if (Math.abs(delta) >= 1) moves.push([row, delta])
            }
            for (const [row, delta] of moves) {
              row.animate(
                [{ transform: `translateY(${delta}px)` }, { transform: "translateY(0)" }],
                { duration: 320, easing: "cubic-bezier(0.16, 1, 0.3, 1)" }
              )
            }
          },
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollBottom">
        export default {
          mounted() {
            // Remember which conversation we're pinned to; a switch is a patch (no
            // remount), so updated() must re-pin instantly rather than mounted (#109).
            this.convId = this.el.dataset.conversationId
            // Permalink / "jump to root": the server marks a main-stream focus target via
            // data-focus-* (and, for the long-history case, loads a window AROUND it so it's
            // even IN the DOM — #jump). On a fresh load, scroll to that target instead of the
            // bottom; otherwise land at the latest as usual.
            const focus = this.checkFocus()
            if (focus) this.focusOn(focus)
            else this.toBottom()
            // Thread-reply targets (`thread-<id>`, a different container with no
            // scroll-to-bottom of its own) arrive as an event rather than via data-focus-*.
            this.handleEvent("focus_message", ({ domId }) => this.focusOn(domId))
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
              // Which optimistic-node container this scroller owns (#142): the main
              // pane uses #pending-messages; the thread panel passes data-pending-id.
              const pendingId = this.el.dataset.pendingId || "pending-messages"
              for (const mut of muts) {
                for (const node of mut.addedNodes) {
                  if (node.nodeType !== 1) continue
                  const row = node.matches?.(".ed-msg, .ed-flat") ? node
                    : node.querySelector?.(".ed-msg, .ed-flat")
                  if (!row) continue
                  // An optimistic node sitting in #pending already animated itself
                  // (addOptimistic / addOptimisticMedia); never re-animate it.
                  const inPending = !!row.closest("#" + pendingId)
                  if (inPending) continue
                  if (row.dataset.clientId) {
                    // My own message just streamed in. A media send still renders an
                    // optimistic twin (local preview + progress ring) — drop it in this
                    // same microtask, BEFORE paint, and don't animate: it already rose
                    // in, so a second animation would double up. Text sends render no
                    // optimistic node anymore, so there's no twin → fall through and
                    // rise in like a thread reply (one smooth transition, shared by the
                    // whole list — DMs, rooms, and threads alike).
                    const twin = document.getElementById(pendingId)
                      ?.querySelector(`[data-client-id="${row.dataset.clientId}"]`)
                    if (twin) {
                      // Carry the local poster frame(s) onto the real <video>(s) so a
                      // just-sent clip shows its frame while /files loads, instead of
                      // flashing gray/"unsupported" until it decodes (#130). The server
                      // poster ({:thumbnail_ready}) then takes over via morphdom. Only
                      // when the poster↔video count is unambiguous (a lone clip or an
                      // all-video album), so a mixed album never lands a photo's frame
                      // on a video.
                      const posters = [...twin.querySelectorAll("img")].map((i) => i.src)
                      const vids = [...row.querySelectorAll("video")]
                      if (vids.length && posters.length === vids.length) {
                        vids.forEach((v, i) => {
                          if (!v.getAttribute("poster")) v.setAttribute("poster", posters[i])
                        })
                      }
                      // Same idea for PHOTOS: carry the local snapshot onto the real <img>(s)
                      // (BEFORE paint) so a just-sent photo shows instantly instead of flashing
                      // the cobalt bubble + "Photo" alt while /files loads — the thumbnail isn't
                      // generated yet, so the real src is the full original (a slow fetch).
                      // morphdom swaps to the server thumb on {:thumbnail_ready}, keeping this
                      // frame until the thumb decodes. Skip avatar/header imgs (flat rooms).
                      const realImgs = [...row.querySelectorAll("img")].filter(
                        (i) => !i.closest(".ed-avatar, .ed-flat__gutter, .ed-flat__head"),
                      )
                      if (realImgs.length && realImgs.length === posters.length) {
                        realImgs.forEach((img, i) => {
                          if (posters[i]?.startsWith("data:")) img.src = posters[i]
                        })
                      }
                      // A twin left a merged file group — re-fuse the remaining optimistic rows so
                      // the shrinking in-flight bubble stays one bubble (its owner is the SendQueue
                      // hook, which listens for this).
                      const gid = twin.dataset.groupId
                      twin.remove()
                      if (gid) window.dispatchEvent(new CustomEvent("ed:regroup", { detail: { groupId: gid } }))
                      continue
                    }
                  }
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
            // `follow` is a STICKY "stay at the bottom" intent: unlike `pinned` (which
            // beforeUpdate recomputes to false the instant content grows taller than the
            // viewport), it survives content growing below — a late-decoding image, the
            // real row swapping in for its optimistic twin. Cleared only when the user
            // scrolls UP. The image-load re-pin honors it so a just-sent photo lands fully
            // in view even when its grow exceeds the pinned threshold (#104).
            this.follow = true
            this.lastTop = this.el.scrollTop
            this.onScroll = () => {
              const top = this.el.scrollTop
              this.pinned = this.el.scrollHeight - top - this.el.clientHeight < 48
              if (this.pinned) this.follow = true
              else if (top < this.lastTop - 2) this.follow = false
              this.lastTop = top
              this.maybeLoadOlder()
            }
            this.el.addEventListener("scroll", this.onScroll, { passive: true })
            // The reply bar / typing row live OUTSIDE #message-scroll (in the composer),
            // so their appearing never triggers this hook's updated(). A ResizeObserver
            // catches the viewport shrinking and keeps the last message visible above the
            // composer instead of letting it hide behind the reply bar.
            this.ro = new ResizeObserver(() => {
              if (this.pinned && !this._focusing()) this.toBottom(false)
            })
            this.ro.observe(this.el)
            // After a send the user always wants their message at the bottom, but the send
            // settles in stages (optimistic node, modal→bar composer resize, the real row,
            // late media decode) — each can leave it short, and `pinned`/`follow` are too
            // fragile across those transients (esp. Firefox) (#104). So when SendQueue
            // signals a send, glue to the bottom for a short window, then stop. This is
            // send-only, so it never yanks someone scrolled up reading history.
            this.onAfterSend = () => {
              // ed:after-send is dispatched ONLY by the main composer (SendQueue); the open
              // thread panel shares this hook but must NOT stick on a main-stream send (#187
              // review: a main send was yanking a scrolled-up thread to its bottom). The thread
              // composer scrolls its own pane separately, never via this event.
              if (this.el.id !== "message-scroll") return
              this.stickUntil = performance.now() + 1200
              if (this._sticking) return
              this._sticking = true
              const tick = () => {
                if (performance.now() > this.stickUntil) { this._sticking = false; return }
                this.toBottom(false)
                requestAnimationFrame(tick)
              }
              requestAnimationFrame(tick)
            }
            window.addEventListener("ed:after-send", this.onAfterSend)
            // A just-sent (or received) photo/video/file row grows AFTER we scrolled — its
            // media decodes late (no server dimensions yet) or its card lays out a frame
            // later — leaving it below the fold (#104). The earlier per-image `load` re-pin
            // was timing-fragile (worked in Chrome, missed Firefox; never covered files).
            // Instead observe the message CONTENT's height and re-pin on ANY growth while
            // `follow` (sticky-bottom) holds — covers images, video posters, and file cards
            // uniformly, on every browser. The separator churn (#83) nets to zero before
            // this fires (the MutationObserver re-adds it in the same task), so it doesn't
            // trigger here.
            this.content = this.el.querySelector("#messages")
            if (this.content) {
              this.contentRo = new ResizeObserver(() => {
                if (this.follow && !this._focusing()) this.toBottom(false)
              })
              this.contentRo.observe(this.content)
            }
          },
          maybeLoadOlder() {
            if (this.loadingMore || this.el.dataset.hasMore !== "true") return
            if (this.el.scrollTop > 300) return
            this.loadingMore = true
            this.prevHeight = this.el.scrollHeight
            this.pushEvent("load_more", {})
          },
          // True while a jump highlight is in its dwell window — used to suppress every
          // auto-scroll-to-bottom path (mount, conv re-pin, ResizeObservers) so they can't
          // yank the view off the message we just jumped to.
          _focusing() {
            return this.focusUntil && Date.now() < this.focusUntil
          },
          // The server flags a main-stream jump target on #message-scroll as
          // data-focus-id (+ a monotonic data-focus-nonce so re-jumping the SAME message
          // re-fires). Returns the dom id to focus, or null when there's nothing new.
          checkFocus() {
            const nonce = this.el.dataset.focusNonce
            const id = this.el.dataset.focusId
            if (!id || nonce === this.lastFocusNonce) return null
            this.lastFocusNonce = nonce
            return "messages-" + id
          },
          // Scroll a message into view and briefly highlight it (permalink / jump-to-root /
          // tapped quote). Robust on a long, busy chat where the server just loaded a window
          // AROUND an older target:
          //   - retry until the row is actually in the DOM,
          //   - stop the auto-follow so a late image-decode can't yank back to the bottom,
          //   - center INSTANTLY (a far jump teleports — a smooth scroll across thousands of
          //     px onto still-settling layout was landing in "random" spots), then
          //   - HOLD it centered for a short window: re-center every frame while images in the
          //     fresh window decode and grow (each grow shifts the target; holding pins it),
          //   - keep a longer dwell so updated() can re-apply the highlight class a re-render
          //     would otherwise strip.
          focusOn(domId) {
            this.follow = false
            this.pinned = false
            this.focusId = domId
            let tries = 0
            const go = () => {
              const el = document.getElementById(domId)
              if (!el) {
                if (tries++ < 12) return setTimeout(go, 50)
                this.focusId = null
                return this.pushEvent("message_unavailable")
              }
              el.classList.add("ed-msg--focus")
              this.focusUntil = Date.now() + 2200
              const holdUntil = Date.now() + 800
              const hold = () => {
                const node = document.getElementById(domId)
                if (!node) return
                node.scrollIntoView({ block: "center", behavior: "auto" })
                if (Date.now() < holdUntil) {
                  requestAnimationFrame(hold)
                } else if (this.el.contains(node)) {
                  // A jump scrolls programmatically, so no 'scroll' event fires to kick
                  // maybeLoadOlder — the top "load older" affordance sat visible-but-idle, and
                  // the target could be stranded at the very top of a deep-jump window (#188).
                  // Trigger one load now; updated()'s prepend path keeps the target put and the
                  // continuation below fills until ~300px of older context sits above it.
                  // Guard: focus_message reaches BOTH the main + thread .ScrollBottom hooks, but
                  // only the pane that actually holds the target should load — else a jump to a
                  // thread reply fires a spurious main-stream load (#188 review).
                  this.maybeLoadOlder()
                }
              }
              hold()
              setTimeout(() => {
                this.focusUntil = 0
                this.focusId = null
                document.getElementById(domId)?.classList.remove("ed-msg--focus")
              }, 2200)
            }
            requestAnimationFrame(go)
          },
          beforeUpdate() {
            this.pinned = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 48
            // Snapshot the message-row count so updated() only re-pins on a genuinely NEW
            // message — never on an incidental re-render (typing here or in a thread, a
            // reaction, a read tick, a reply-count footer). Re-pinning on every patch made
            // the list chase the transient separator height and twitch on every keystroke
            // (#104). Sent messages scroll via SendQueue + the image-load re-pin, not here.
            this.prevCount = this.el.querySelectorAll(".ed-msg, .ed-flat").length
          },
          // A new message while pinned: glide the list up to make room so it
          // eases in from the bottom instead of snapping (the "jerk"). Mount
          // stays instant — no page-load scroll choreography.
          updated() {
            // Re-apply the jump highlight if this patch re-rendered the focused row and
            // morphdom stripped the JS-added class (active rooms re-render rows often). A
            // gone/other-conversation row resolves to null → harmless no-op.
            if (this._focusing()) {
              document.getElementById(this.focusId)?.classList.add("ed-msg--focus")
            }
            // A jump target landed in this patch (the server loaded a window AROUND an older
            // message and bumped data-focus-nonce): scroll to it instead of re-pinning to the
            // bottom. Checked before the conv-switch/re-pin paths so neither fights the jump.
            const focus = this.checkFocus()
            if (focus) {
              this.convId = this.el.dataset.conversationId
              this.loadingMore = false
              this.focusOn(focus)
              return
            }
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
                // Keep filling while a jump is still settling and the top affordance would
                // otherwise sit visible-but-idle (#188): self-terminates once ~300px of older
                // context is above the target (scrollTop > 300) or there's no more — so it never
                // runs away when someone just parks near the top during normal reading.
                if (
                  this._focusing() &&
                  this.el.scrollTop <= 300 &&
                  this.el.dataset.hasMore === "true"
                ) {
                  this.maybeLoadOlder()
                }
              })
              return
            }
            // Only re-pin when a new message actually arrived (row count grew). Incidental
            // patches leave the count unchanged and must NOT move the list (#104). Never
            // while a jump is settling — that would steal the view back to the bottom.
            if (
              this.pinned &&
              !this._focusing() &&
              this.el.querySelectorAll(".ed-msg, .ed-flat").length > this.prevCount
            ) {
              this.toBottom(true)
            }
          },
          destroyed() {
            this.riser && this.riser.disconnect()
            this.ro && this.ro.disconnect()
            this.contentRo && this.contentRo.disconnect()
            this.onScroll && this.el.removeEventListener("scroll", this.onScroll)
            this.onAfterSend && window.removeEventListener("ed:after-send", this.onAfterSend)
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

            // Double-click a message → react with the viewer's configured emoji (#106).
            // Only on real message rows: the same hook also hosts sidebar/channel context
            // menus, which carry no data-message-id — gating the whole setup here keeps
            // those hosts listener-free. Listen on the full message ROW (.ed-msg in DM
            // bubbles, the .ed-flat host in rooms/threads) so the hit area matches rooms,
            // not just the narrow bubble. Skips interactive descendants — buttons, inputs,
            // video, existing chips and real text links (a:not(.ed-photo)); PHOTOS are
            // reactable (<a class="ed-photo">): the .Lightbox hook defers its open ~250ms so
            // a double-click reacts instead. The emoji rides #composer's dataset (present
            // for DM, room AND thread rows).
            if (this.el.dataset.messageId) {
              const dblRow = this.el.closest(".ed-msg") || this.el
              const canReact = (t) =>
                !t.closest("button, input, textarea, video, .ed-reactions, a:not(.ed-photo)")
              // preventDefault on the SECOND mousedown stops the browser selecting the word
              // BEFORE it paints — clearing the selection after dblclick still flickered.
              dblRow.addEventListener("mousedown", (e) => {
                if (e.detail === 2 && canReact(e.target)) e.preventDefault()
              })
              dblRow.addEventListener("dblclick", (e) => {
                if (!canReact(e.target)) return
                const emoji = document.getElementById("composer")?.dataset.dblReact
                if (!emoji) return
                e.preventDefault()
                this.pushEvent("react", { id: this.el.dataset.messageId, emoji })
              })
            }

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
            const trigger = this.el.querySelector("[data-menu-trigger]")
            if (trigger) trigger.setAttribute("aria-expanded", "true")
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
            const trigger = this.el.querySelector("[data-menu-trigger]")
            if (trigger) trigger.setAttribute("aria-expanded", "false")
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
            // The chip is a scroll-only affordance. A LiveView re-render (e.g. typing
            // in the composer fires phx-change) reflows the streamed list and nudges
            // scrollTop by a sub-pixel amount, emitting a "scroll" with no real motion —
            // that flashed the chip on every keystroke (#134). Anchor the last position
            // and ignore movement under a few px (well below a line), so only a genuine
            // scroll updates the chip; the wobble (≤1px, nets to zero) is filtered out.
            this._chipAnchor = this.scroller.scrollTop
            // #150: the chip is a USER-scroll affordance only. Programmatic scrolls move the
            // list too — scroll-to-bottom on send / new message, jump-to-message, the
            // load-older restore, the mount scroll — and must NOT flash the day pill. Track a
            // short "user is scrolling" window opened by wheel / touch-drag / scroll keys and
            // kept alive by the scroll events they produce (trackpad & flick momentum fire no
            // further input events but keep scrolling); a scroll outside it is programmatic.
            this._userScrollUntil = 0
            const scrollKeys = new Set([
              "PageUp", "PageDown", "ArrowUp", "ArrowDown", "Home", "End", " ", "Spacebar"
            ])
            this._markUser = () => { this._userScrollUntil = Date.now() + 150 }
            this._onUserKey = (e) => { if (scrollKeys.has(e.key)) this._markUser() }
            this.scroller.addEventListener("wheel", this._markUser, { passive: true })
            this.scroller.addEventListener("touchmove", this._markUser, { passive: true })
            this.scroller.addEventListener("keydown", this._onUserKey)
            this.onScroll = () => {
              if (this._raf) return
              this._raf = requestAnimationFrame(() => {
                this._raf = null
                const top = this.scroller.scrollTop
                if (Math.abs(top - this._chipAnchor) < 4) return
                this._chipAnchor = top
                // Programmatic scroll (no recent user intent) → re-anchor but don't reveal.
                if (Date.now() >= this._userScrollUntil) return
                // Momentum keeps firing scroll with no input events — extend the window so the
                // chip stays through the glide, then lapses ~150ms after motion stops.
                this._userScrollUntil = Date.now() + 150
                this.updateChip()
              })
            }
            this.scroller.addEventListener("scroll", this.onScroll, { passive: true })
            this.reconcile()
            this.scheduleMidnight()
            // Every LiveView patch makes morphdom drop our injected separators; the
            // hook's updated() only re-adds them a frame later, so the 22px gap is
            // painted and the list visibly twitches (worse in browsers with weak scroll
            // anchoring, e.g. Firefox) (#104). This observer re-derives them in the SAME
            // microtask the drop happens in — before the browser reflows/paints — so
            // scrollHeight never visibly changes.
            this.mo = new MutationObserver(() => this.reconcile())
            this.mo.observe(this.el, { childList: true })
          },
          updated() { this.reconcile() },
          destroyed() {
            if (this.scroller) {
              this.onScroll && this.scroller.removeEventListener("scroll", this.onScroll)
              this._markUser && this.scroller.removeEventListener("wheel", this._markUser)
              this._markUser && this.scroller.removeEventListener("touchmove", this._markUser)
              this._onUserKey && this.scroller.removeEventListener("keydown", this._onUserKey)
            }
            this.mo && this.mo.disconnect()
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
            // Skip the DOM churn only when the day structure is unchanged AND every
            // separator is still sitting immediately before its row. A stream patch can
            // drop the injected nodes (append), and a stream RESET (switching
            // conversations) drops the message rows but leaves the phx-update="ignore"
            // separators and re-adds the rows after them — detaching every separator to
            // one end. A structure-only check would treat that as unchanged and leave them
            // piled up, so verify their positions too.
            const inPlace =
              existing.length === desired.length &&
              desired.every((row) => {
                const prev = row.previousElementSibling
                return prev && prev.id === "ds-" + row.id
              })
            if (sig === this._sig && inPlace) return
            this._sig = sig
            // Suspend the observer around our own edits so re-adding doesn't re-enter
            // reconcile in a loop.
            this.mo && this.mo.disconnect()
            existing.forEach((s) => s.remove())
            for (const row of desired) {
              const sep = document.createElement("div")
              sep.className = "ed-date-sep"
              // id + phx-update="ignore" so LiveView's stream patcher treats the separator
              // as a managed node it must leave alone, instead of a phantom child it strips
              // on every patch. The strip was shrinking scrollHeight and clamping a bottom-
              // pinned scroll up by the separators' height (#104).
              sep.id = "ds-" + row.id
              sep.setAttribute("phx-update", "ignore")
              const span = document.createElement("span")
              span.textContent = this.dayLabel(Number(row.dataset.ts))
              sep.appendChild(span)
              this.el.insertBefore(sep, row)
            }
            this.mo && this.mo.observe(this.el, { childList: true })
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
            // Edit (#164): the server pre-fills (start) / clears (cancel|save) the chat input
            // directly — setting value= via render fights LiveView's controlled input.
            this.handleEvent("set_composer_body", ({ body }) => {
              const input = this.el.querySelector('input[name="message[body]"]')
              if (!input) return
              input.value = body
              input.dispatchEvent(new Event("input", { bubbles: true }))
              if (body) {
                input.focus()
                try { input.setSelectionRange(body.length, body.length) } catch (_e) {}
              }
            })
            this.queue = []
            // Upload queue (#119): File batches picked WHILE a media send is uploading.
            // They can't enter the shared :attachment config (would merge into the in-flight
            // album), so they wait here and are fed in one at a time as the config frees
            // (config-free edge in updated()). prevSm/prevComposeOpen track that edge: the
            // shared config is occupied while EITHER a send uploads (sm) OR a batch is staged
            // in the compose overlay; the queue feeds the next batch the moment it frees.
            this.mediaQueue = []
            this.prevSm = this.el.dataset.sendingMedia === "true"
            this.prevComposeOpen = !!this.el.querySelector("[data-upload-preview]")
            // Client-side "a media send is occupying the config" flag (#119). Set the instant
            // Send is pressed (synchronously, before the media_sending round-trip) and cleared
            // once the config is free again (in updated()). The server's data-sending-media
            // lags by a round-trip — on a slow link that lag is seconds, so a pick made right
            // after Send would otherwise miss the gate and merge into the in-flight album.
            this.mediaInFlight = this.prevSm
            // Per-send delivery watchdogs by client_id (#142): a clock shows while a
            // send awaits ack; if none arrives in time the clock flips to a red ●!.
            // ~20s when online (covers several LiveView reconnects on a flaky link);
            // a window "offline" event shortens any pending wait to ~3s.
            this.sendTimers = new Map()
            this.onOffline = () => this.onWentOffline()
            window.addEventListener("offline", this.onOffline)
            // True while a media send is in flight — gates the overlay re-hide (#130).
            this.sending = false
            // Object URLs for staged video previews (#117), keyed
            // "name:size:lastModified" and shared with the .VideoPreview hook via
            // this element. Revoked when a
            // clip is removed (VideoPreview destroyed) or the conversation switches.
            this.el.edenVideoUrls = new Map()
            // The original picked File objects, keyed "name:size:lastModified", so a failed
            // upload can be RE-SENT (#…): the LiveView entry's File is gone after a cancel, so
            // we stash it at pick. Kept until the composer is torn down (destroyed).
            this.el.edenFiles = new Map()
            this.input = this.el.querySelector('input[name="message[body]"]')
            this.pending = document.getElementById("pending-messages")
            this.scroller = document.getElementById("message-scroll")
            // Expose this instance so the thread composer (.ThreadSendQueue, a separate colocated
            // hook that can't share these methods) can route a thread album/file send through the
            // SAME sequential feeder (phase F trim): one item at a time (no batch stall), each
            // landing as a thread reply progressively. Only the DM/room pane owns the feeder.
            window.__edSendQueue = this
            // Resume any send whose upload was cut off by a reload (phase E): rebuild its optimistic
            // rows from the durable store and re-feed the unfinished items. Fire-and-forget (async).
            this.resumeSends()
            // Re-fuse a merged file group's optimistic rows when a twin swaps out (fired by the
            // riser after it removes a completed twin), so the in-flight bubble stays one bubble.
            this._onRegroup = (e) => this.reGroupOptimistic(e.detail && e.detail.groupId)
            window.addEventListener("ed:regroup", this._onRegroup)
            this.el.addEventListener("submit", (e) => this.onSubmit(e))
            // "Send as file" (#122): a type="button" so it's never the implicit Enter
            // submitter. On click, flag the next submit as uncompressed-document and
            // requestSubmit() through the normal media path (onSubmit reads the flag).
            this._asFile = false
            this.el.addEventListener("click", (e) => {
              if (!e.target.closest("[data-send-as-file]")) return
              this._asFile = true
              this.el.requestSubmit()
            })
            // Observe file picks (in capture) for two reasons: the #119 upload queue
            // (hold a batch picked while another uploads) and the video-preview URLs.
            // Photos are NO LONGER shrunk client-side — the server compresses every
            // photo for storage (#122), and "Send as file" (#122) needs the untouched
            // original — so a normal pick just stages natively (no intercept/re-encode).
            this.onPick = (e) => {
              const input = e.target
              const isFile = input instanceof HTMLInputElement && input.type === "file"
              // The dedicated Resend / sequential feeds target :attachment_retry / :attachment_seq
              // directly — they must NOT be gated/queued like a normal :attachment pick (that would
              // divert them into the main config). Let them propagate untouched (clones already stashed).
              if (isFile && (input.name === "attachment_retry" || input.name === "attachment_seq")) return
              // Capture video object URLs for previews wherever the batch ends up.
              this.captureVideoUrls(e)
              // #119: a pick WHILE a media send is uploading can't enter the shared
              // :attachment config (it would merge into the in-flight album). Hold its
              // Files in the queue and stop the native stage; updated() feeds the next
              // batch once the config frees. Paste routes here too (it dispatches `input`).
              // mediaInFlight is the immediate client truth (set at Send); the server flag
              // is the fallback. Checked BEFORE the this.sending reset below so the pick
              // can't clear the very signal it's testing.
              const busy = this.mediaInFlight || this.el.dataset.sendingMedia === "true"
              // A pick larger than the config accepts at once (max_staged_entries, #193) would
              // tag the excess :too_many_files — a CONFIG-level error that blocks the WHOLE
              // upload (nothing stages, the ring freezes, the 30s watchdog then drops the node).
              // The server splits a pick into albums, but only up to what STAGES; past the cap
              // we stop the native stage and tell the user, instead of wedging silently.
              if (isFile && input.files?.length > this.maxStaged()) {
                e.stopImmediatePropagation()
                e.preventDefault()
                input.value = ""
                this.pushEvent("media_too_many", { max: this.maxStaged() })
                return
              }
              if (isFile && input.files?.length && busy) {
                e.stopImmediatePropagation()
                e.preventDefault()
                this.mediaQueue.push([...input.files])
                input.value = ""
                this.updateQueueHint()
                return
              }
              // A fresh (non-queued) pick starts a new staging cycle — clear the
              // send-in-flight guard so its preview overlay shows again (#130). The
              // event is left to propagate so LiveView stages the file natively.
              if (isFile) this.sending = false
            }
            this.el.addEventListener("input", this.onPick, true)
            this.el.addEventListener("change", this.onPick, true)
            // A media send that errored (or consumed no entry) has no real row to
            // swap its optimistic twin, so the server names the exact client_id to
            // drop — else it spins forever and pins its preview data-URLs (#95).
            this.handleEvent("media_failed", ({ id }) => {
              this.dropPending(id)
            })
            // Settle a failed-card Resend (#…): the server sends it, then names the card's
            // client_id here — ok (the client_id swap already removed the card) vs failed.
            this.handleEvent("retry_done", (payload) => this.onRetryDone(payload))
            // Determinate upload progress for an in-flight send. The server addresses
            // the album's averaged ring by its client_id (#95) and each file's ring by
            // its upload ref (#149); we drive whichever node it names and re-arm that
            // node's stall watchdog.
            this.handleEvent("media_progress", ({ id, ref, percent }) => {
              const node = ref
                ? this.pending?.querySelector(`[data-upload-ref="${ref}"]`)
                : this.pending?.querySelector(`[data-client-id="${id}"]`)
              this.setRing(node, percent)
              this.armStall(node && node.closest(".ed-msg, .ed-flat"))
            })
            // Sequential-send progress (TG-attachments): the server drives ONE node at a time by
            // its client_id — a file card, or an album node (its ring aggregates the album's
            // photos). Same ring + stall-watchdog re-arm as media_progress.
            this.handleEvent("seq_progress", ({ id, percent }) => {
              // A media photo drives its own TILE (data-item-cid); a file its card row (data-client-id).
              const node =
                this.pending?.querySelector(`[data-item-cid="${id}"]`) ||
                this.pending?.querySelector(`[data-client-id="${id}"]`)
              this.setRing(node, percent)
              // Re-arm the CURRENT item's watchdog (seq-aware: fails only this item/photo, fires seq_reset).
              this.armSeqStall(node)
            })
            // One sequential item finished uploading (its real message/album streamed in and
            // swapped its optimistic node) — feed the next item in the queue.
            this.handleEvent("seq_done", ({ id }) => this.onSeqDone(id))
          },
          disconnected() {
            this.connected = false
            // Freeze every in-flight upload's stall watchdog: a dropped link is NOT a stall —
            // LiveView pauses the upload and resumes it on reconnect — so the clock must not run
            // while offline, else a flaky/slow connection loses files after the timeout (the
            // "even on slow internet the file vanishes ~30s later" bug). Re-armed on reconnect.
            if (this.pending) {
              for (const row of this.pending.children) {
                if (row._stall) { clearTimeout(row._stall); row._stall = null }
              }
            }
          },
          destroyed() {
            // Composer torn down (e.g. live_redirect out of chat without a
            // conversation switch): per-tile VideoPreview.destroyed revokes live
            // previews, this sweeps any object URL left without a tile (a rejected
            // or never-rendered entry) so it can't outlive the page (#117).
            if (this.el.edenVideoUrls) {
              for (const url of this.el.edenVideoUrls.values()) URL.revokeObjectURL(url)
              this.el.edenVideoUrls.clear()
            }
            this.el.edenFiles?.clear()
            if (window.__edSendQueue === this) delete window.__edSendQueue
            window.removeEventListener("offline", this.onOffline)
            if (this._onRegroup) window.removeEventListener("ed:regroup", this._onRegroup)
            this.sendTimers.forEach((t) => clearTimeout(t))
            this.sendTimers.clear()
            // The nodeless (thread) stall watchdog lives on the hook, not in sendTimers — clear it
            // too so it can't fire pumpSeq/pushEvent on a torn-down hook.
            if (this._seqStall) clearTimeout(this._seqStall)
            this.closeFailMenu()
          },
          reconnected() {
            this.connected = true
            // Re-arm anything that was in-flight when the link dropped; the
            // server dedups by client_id, so re-sending can't duplicate.
            for (const item of this.queue) item.sent = false
            this.flush()
            // Re-arm the stall watchdog for in-flight upload nodes (frozen on disconnect):
            // LiveView resumes the paused upload now, so the clock restarts from a clean 0.
            if (this.pending) {
              // Retry nodes keep their own dedicated channel + watchdog — re-arm them as before.
              for (const row of this.pending.children) {
                if (row.dataset.retry === "true" &&
                    !row.classList.contains("ed-msg-failed") &&
                    row.querySelector(".ed-media-sending__ring-fill")) {
                  this.armStall(row)
                }
              }
              // Sequential send: only the ONE in-flight item was uploading — re-arm just its node
              // (queued items stay unarmed until their turn), so the watchdog restarts cleanly and,
              // if the resumed upload is truly wedged, skips to the next after the timeout.
              if (this.seqFeeding) {
                const it = this.seqFeeding
                const node = this.pending.querySelector(`[data-client-id="${it.albumCid || it.clientId}"]`)
                this.armSeqStall(node && node.closest(".ed-msg, .ed-flat"))
              }
            }
          },
          updated() {
            // Switched conversation: reset the text send queue/timers, and hide (not wipe)
            // this chat's in-flight media nodes so background-upload progress survives (#144).
            if (this.el.dataset.conversationId !== this.convId) {
              this.convId = this.el.dataset.conversationId
              this.queue = []
              // Queued batches (#119) belong to the chat they were picked in; drop them on
              // a switch (they were never sent) so they can't feed into the new chat.
              this.mediaQueue = []
              this.updateQueueHint()
              this.sending = false
              this.sendTimers.forEach((t) => clearTimeout(t))
              this.sendTimers.clear()
              this.closeFailMenu()
              // #144: a media send keeps uploading after you leave its chat, so don't wipe
              // its optimistic node — only the text twins (untagged; their delivery is
              // queue/timer-bound to this chat, as before). Media/file nodes carry their
              // owning conversation (data-conv-id): hide other chats', re-show this chat's.
              // On re-show, dedup against the just-reset stream — if the real row already
              // arrived while we were away, drop the twin so node + real row never double up.
              if (this.pending) {
                // The main composer's stream is #messages (paired with this.pending =
                // #pending-messages, set in mounted()); the thread composer is a separate
                // hook with its own containers, so this pairing is fixed here.
                const stream = document.getElementById("messages")
                for (const node of [...this.pending.children]) {
                  const conv = node.dataset.convId
                  if (!conv) {
                    node.remove()
                  } else if (conv !== this.convId) {
                    node.style.display = "none"
                  } else if (
                    node.dataset.clientId &&
                    stream?.querySelector(`[data-client-id="${node.dataset.clientId}"]`)
                  ) {
                    node.remove()
                  } else {
                    node.style.display = ""
                  }
                }
              }
              // Revoke staged-clip object URLs from the old conversation (#117) — but NOT
              // while a media send is in flight: its entries (and their previews) survive the
              // switch (#144), so revoking here would blank the tiles if its overlay ever
              // reopens. Cleared normally on a switch with nothing in flight, and on destroy.
              if (this.el.dataset.sendingMedia !== "true") {
                for (const url of this.el.edenVideoUrls.values()) URL.revokeObjectURL(url)
                this.el.edenVideoUrls.clear()
              }
            }
            // A media send is in flight (#130): re-hide the preview overlay on every
            // patch so a re-render beating media_sending — or morphdom restoring the
            // server markup over the JS display:none — can't flash it back. Runs in
            // the patch cycle before paint, so the flash never reaches the screen.
            // Cleared on a fresh pick (onPick) so the next staging shows normally.
            if (this.sending) {
              const ov = this.el.querySelector("[data-upload-preview]")
              if (ov) ov.style.display = "none"
            }
            // #119: feed the next queued batch the moment the shared config FREES — covers a
            // send completing (sm→false) AND a surfaced batch being cancelled (the compose
            // overlay closes). The config is free only when nothing uploads AND nothing is
            // staged, so this also naturally waits out the just-finished entry lingering a
            // beat (it only fires once the overlay is gone). One guarded path, sequential.
            const sm = this.el.dataset.sendingMedia === "true"
            const composeOpen = !!this.el.querySelector("[data-upload-preview]")
            // #164 text→media: when the overlay OPENS during a text edit, seed its caption with
            // the edit text (in #composer-body) so the conversion's caption defaults to the
            // message text — editable + blankable there. On the open transition only, so later
            // patches never clobber the user's caption edits.
            if (composeOpen && !this.prevComposeOpen && this.el.querySelector("[data-edit-active]")) {
              const cap = this.el.querySelector("#compose-caption")
              if (cap && !cap.value && this.input) cap.value = this.input.value
            }
            const configFree = !sm && !composeOpen
            // Never stay gated once the config is genuinely free (else a lost media_sending
            // would leave mediaInFlight stuck true and silently queue every later pick).
            if (configFree) this.mediaInFlight = false
            const justFreed = configFree && (this.prevSm || this.prevComposeOpen)
            if (justFreed && this.mediaQueue.length) this.dequeueNext()
            this.prevSm = sm
            this.prevComposeOpen = composeOpen
          },
          onSubmit(e) {
            // #122: "Send as file" sets this flag (then requestSubmit()s) — read + reset it
            // unconditionally so an aborted/error submit can't leak it into the next send.
            const asFile = this._asFile === true
            this._asFile = false
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
            // #164 text→media: editing a text message + attached media → convert. Unlike a
            // normal media send, an edit updates an EXISTING row (via {:message_edited}), so
            // draw NO optimistic node and push NO media_sending — just close the overlay and
            // let the native submit upload the :attachment entries + fire "send" (the server
            // routes editing+media to edit_message_media). Keep a client-side error visible.
            if (overlay && this.el.querySelector("[data-edit-active]")) {
              if (overlay.querySelector(".ed-attach-err")) {
                e.preventDefault()
                return
              }
              overlay.querySelectorAll("video").forEach((v) => {
                try { v.pause() } catch (_e) {}
              })
              this.sending = true
              overlay.style.display = "none"
              window.dispatchEvent(new CustomEvent("ed:after-send"))
              return
            }
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
              // Capture the caption NOW, while the overlay is still open: it rides the
              // media_sending push (so it can't be lost if the upload is slow) and is
              // drawn in the optimistic node (so it shows during upload, not only on the
              // real row's arrival).
              const caption = (this.el.querySelector("#compose-caption")?.value || "").trim()
              // Media tiles (image/video) are split into albums of maxAlbum (#193): the server
              // splits a big pick into a sequence of albums, so split the optimistic the SAME
              // way NOW — one node per batch, each with its own client_id — so every album
              // appears and uploads on send (Telegram-style), not the overflow popping in
              // already-loaded after the first. Files post one message PER file (#149).
              const mediaTiles = [...overlay.querySelectorAll(".ed-compose__tile")]
              const hasMedia = mediaTiles.length > 0
              // #122: a photos-only "Send as file" lands as document cards — draw the
              // optimistic the same way so a slow upload doesn't show an album that reshapes.
              // A mixed batch (a video present) keeps the album node (video renders inline).
              const asFileDocs = asFile && !overlay.querySelector(".ed-compose__video")
              // Build the SEQUENTIAL upload queue (TG-attachments): album photos first (in album
              // order), then files. Each item is fed one at a time on :attachment_seq so it gets
              // the full link (no concurrent per-chunk-timeout starvation → no batch stall) and its
              // real row/album lands progressively.
              const albumIds = []
              const seqItems = []
              const albumSpecs = []
              for (let i = 0; i < mediaTiles.length; i += this.maxAlbum()) {
                const batch = mediaTiles.slice(i, i + this.maxAlbum())
                const cid = this.uuid()
                albumIds.push(cid)
                albumSpecs.push({ cid, count: batch.length })
                // The caption rides only the FIRST album (matches attachment_steps).
                const cap = i === 0 ? caption : ""
                // Mint a per-photo client_id per tile (phase D: each tile gets its OWN ring + cancel
                // keyed by this id). Queue each photo (looked up in edenFiles by its tile key) under
                // this album — the album message is posted once all its photos have uploaded.
                const photoCids = batch.map(() => this.uuid())
                batch.forEach((tile, j) => {
                  const key = this.tileFileKey(tile)
                  if (key) seqItems.push({ kind: "media", albumCid: cid, clientId: photoCids[j], key })
                })
                // No armStall here: items upload ONE at a time, so the watchdog is armed per-item
                // in pumpSeq when it starts (arming all nodes at Send would false-fail items still
                // WAITING their turn once a slow batch runs past the 90s timeout). Pass the per-photo
                // ids so each tile can carry its own ring + cancel-X.
                if (asFileDocs) this.addOptimisticAsFile(cid, batch, cap, photoCids)
                else this.addOptimisticMedia(cid, batch, cap, photoCids)
              }
              const fileCids = []
              ;[...overlay.querySelectorAll(".ed-attach-file[data-ref]")].forEach((fe) => {
                const cid = this.uuid()
                // The stash key (name:size:lastModified) so a failed card can look its File
                // back up in edenFiles and re-send it.
                const key = fe.dataset.name + ":" + fe.dataset.sizeRaw + ":" + fe.dataset.modified
                // Armed per-item in pumpSeq (see the album note above), not here.
                this.addOptimisticFile(cid, fe.dataset.ref, fe.dataset.name, fe.dataset.size, key)
                fileCids.push(cid)
                // sizeLabel (the human-readable size) rides so a reload can rebuild the file card
                // from the durable record without re-deriving it (phase E).
                seqItems.push({
                  kind: "file",
                  clientId: cid,
                  key,
                  sizeLabel: fe.dataset.size,
                })
              })
              // A files-only caption rides BELOW the whole pile as its own trailing message
              // (#149) — draw its optimistic text node after the file cards. A photo+caption
              // keeps the caption on the album (drawn above).
              let captionId = null
              if (!hasMedia && caption && fileCids.length > 0) {
                captionId = this.uuid()
                // Tag the caption's node with the conversation too (#144), so it survives a
                // switch alongside its file cards instead of vanishing until the real
                // trailing message (sent server-side after the last file) lands.
                const capNode = this.addOptimistic(captionId, caption)
                if (capNode) capNode.dataset.convId = this.convId
              }
              // Open the send: the server pins the conversation, mints a group_id for a multi-file
              // send (≥2 files → merged bubble), cancels the now-superseded staged :attachment tray,
              // and replies the group_id (stamped on the file group). Then pump the items one at a
              // time. #122 asFile rides so photos store uncompressed + render as documents.
              const queueId = this.uuid()
              // Fuse the file rows into the merged bubble IMMEDIATELY (before the server's group_id
              // round-trips) so they never flash as separate cards for a frame. A temporary marker
              // (the queueId) groups them now; the queue_start reply then swaps in the real group_id
              // at the same positions (no reflow). Only for a multi-file send (the server groups ≥2).
              if (fileCids.length >= 2) {
                fileCids.forEach((cid) => {
                  const row = this.pending?.querySelector(`[data-client-id="${cid}"]`)
                  if (row) row.dataset.groupId = queueId
                })
                this.reGroupOptimistic(queueId)
              }
              // Persist each item (its File + metadata) to IndexedDB BEFORE the send (phase E) so a
              // reload mid-upload can resume it from the durable blob. Best-effort — no-ops if the
              // store is unavailable. `storeId` lets seq_done / cancel drop the record as items resolve.
              const store = window.__edenSendStore
              const userId = this.el.dataset.senderId
              const createdAt = Date.now()
              const records = []
              seqItems.forEach((it, order) => {
                it.storeId = queueId + ":" + order
                const f = store && this.el.edenFiles?.get(it.key)
                if (!f) return
                const rec = {
                  id: it.storeId,
                  userId,
                  queueId,
                  order,
                  convId: this.convId,
                  caption,
                  captionId,
                  asFile,
                  kind: it.kind,
                  albumCid: it.albumCid || null,
                  clientId: it.clientId,
                  groupId: null,
                  name: f.name,
                  sizeLabel: it.sizeLabel || null,
                  type: f.type,
                  file: f,
                  status: "queued",
                  createdAt,
                }
                records.push(rec)
                store.put(rec)
              })
              if (store) store.requestPersist()
              this.pushEvent(
                "queue_start",
                {
                  queue_id: queueId,
                  caption,
                  caption_id: captionId,
                  as_file: asFile,
                  albums: albumSpecs,
                  file_cids: fileCids,
                },
                (reply) => {
                  const gid = reply && reply.group_id
                  if (gid) this.stampGroup(fileCids, gid)
                  // Re-put the full records with the server-minted group_id (upsert — robust even if
                  // the initial put hasn't committed yet, so no lost-group-id race), so a resumed row
                  // rejoins its merged bubble.
                  if (store && gid) records.forEach((rec) => store.put({ ...rec, groupId: gid }))
                  ;(this.seqQueues = this.seqQueues || []).push({ queueId, items: seqItems })
                  this.pumpSeq()
                },
              )
              // Mark the send in flight (#130 polish): updated() then re-hides the
              // overlay on EVERY patch until a fresh pick. Without this, a re-render
              // that beats the media_sending round-trip — or morphdom resetting the
              // inline display:none below to the server's markup — flashes the
              // preview back for a frame after Send (visible under screen-recording
              // load, where transients stretch to several frames).
              this.sending = true
              // #119: this batch now occupies the shared config until it completes — gate
              // further picks into the queue from this instant (not after the round-trip).
              this.mediaInFlight = true
              // Pause any previewed clip first: a played <video> left running while the
              // overlay goes display:none keeps the media session active and flashes the OS
              // media-controls HUD until the server re-render tears the overlay down.
              overlay.querySelectorAll("video").forEach((v) => {
                try {
                  v.pause()
                } catch (_e) {
                  /* a detached/!ready element can throw — ignore */
                }
              })
              // Close the preview INSTANTLY (#111) instead of waiting for the
              // media_sending round-trip to re-render — on a slow link the overlay
              // lingered ~seconds after Send. The element stays in the DOM (display
              // none) so the in-flight upload bound to its file input isn't dropped;
              // the server render then swaps it for the normal composer.
              overlay.style.display = "none"
              // Glue the room to the bottom through the multi-stage media settle (#104).
              window.dispatchEvent(new CustomEvent("ed:after-send"))
              // Sequential send owns the upload now (feeds :attachment_seq itself): stop the form
              // submit so the staged :attachment entries don't ALSO upload concurrently.
              e.preventDefault()
              e.stopPropagation()
              return
            }
            // A quote-reply (#71) also defers to the server path so the reply_to_id
            // rides along and the quote renders at the right height (no optimistic
            // node that would pop taller when the real row streams in). An edit (#164)
            // defers too — it updates an existing row, so there's no optimistic node.
            if (this.el.querySelector("[data-reply-active], [data-edit-active], [data-forward-active]")) {
              window.dispatchEvent(new CustomEvent("ed:after-send"))
              return
            }
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
              // 1:1 DMs draw an optimistic node NOW so a "sending" clock shows
              // immediately (#142) — valuable on a slow cross-border link; the real row
              // carries data-client-id, so the riser swaps it in atomically (clock → ✓,
              // then ✓✓ on read). GROUPS (no receipt) and ROOMS (flat) keep #130's
              // no-node happy path — they render no delivery status; a rejected send in
              // any surface still materializes a retry node lazily in markFailed.
              if (this.el.dataset.layout !== "flat" && this.el.dataset.isGroup !== "true") {
                this.addOptimistic(clientId, part)
              }
              this.queue.push({ clientId, body: part, sent: false })
            }
            // Glue to the bottom on our OWN send (#187): rooms (flat) and groups draw no
            // optimistic node — and the node is what scrolls a 1:1 DM down (addOptimistic) — so
            // without this a text send while scrolled up leaves you stranded mid-history. The
            // media + quote-reply paths already dispatch this; mirror it here. onAfterSend is
            // send-only, so reading history (scrolling up without sending) is never yanked.
            window.dispatchEvent(new CustomEvent("ed:after-send"))
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
            // Items stay queued until acked; only then are they removed. An
            // in-flight item (sent) isn't re-sent until a reconnect re-arms it.
            for (const item of this.queue) {
              if (item.sent) continue
              // Arm the delivery watchdog BEFORE the connection gate (#142): a send
              // composed while offline can't go out now, but must still flip to a red
              // ●! after the offline grace (navigator.onLine picks 20s online / 3s
              // offline) instead of a clock stuck forever. Cleared on the reply.
              this.armSendWatchdog(item.clientId, item.body)
              if (!this.connected) continue
              item.sent = true
              this.pushEvent("send", { message: { body: item.body, client_id: item.clientId } }, (reply) => {
                this.clearSendWatchdog(item.clientId)
                this.queue = this.queue.filter((q) => q.clientId !== item.clientId)
                // On success DON'T remove the optimistic node here — the ack
                // races the {:new_message} broadcast, and removing first leaves
                // a frame where the message vanishes (the list dips, then the
                // real row pops in: the "jerk"). The rise-in observer removes it
                // atomically the instant the real row streams in. A nack (server
                // rejection) drops the item from the queue and flags it failed.
                if (reply && reply.nack) this.markFailed(item.clientId, item.body)
              })
            }
          },
          // Delivery watchdog (#142). Online → ~20s (spans several reconnects); offline
          // → ~3s grace. Fires only if the item is still unacked (a reply clears it).
          armSendWatchdog(clientId, body) {
            this.clearSendWatchdog(clientId)
            const ms = navigator.onLine ? 20000 : 3000
            const timer = setTimeout(() => {
              this.sendTimers.delete(clientId)
              if (this.queue.some((q) => q.clientId === clientId)) this.markFailed(clientId, body)
            }, ms)
            this.sendTimers.set(clientId, timer)
          },
          clearSendWatchdog(clientId) {
            const t = this.sendTimers.get(clientId)
            if (t) { clearTimeout(t); this.sendTimers.delete(clientId) }
          },
          // The browser dropped its network: shorten every pending send's wait to the
          // offline grace so a genuine outage surfaces the red ●! quickly (a momentary
          // blip self-heals before the grace elapses).
          onWentOffline() {
            for (const item of this.queue) this.armSendWatchdog(item.clientId, item.body)
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
              // Mirror the REAL bubble exactly — body + meta inside .ed-bubble__cap —
              // so the optimistic node is the same height and the riser's swap doesn't
              // nudge layout (#130). The status slot shows a "sending" clock in 1:1s
              // (#142, clock → ✓ → ✓✓ once the real row swaps in); group bubbles render
              // no receipt (the real row hides it for groups), so leave it empty there
              // (#89) — markFailed overwrites whatever's here with the red ●! on a nack.
              const isGroup = this.el.dataset.isGroup === "true"
              const status =
                isGroup
                  ? ""
                  : '<span class="inline-flex items-center" style="margin-left:2px;">' +
                    '<span class="hero-clock-micro size-3.5"></span></span>'
              bubble.innerHTML =
                '<div class="ed-bubble__cap">' +
                '<span class="break-words"></span>' +
                '<span class="ed-bubble__meta"><time></time>' + status + "</span>" +
                "</div>"
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
            return row
          },
          // Optimistic media node (#95): a local preview of the staged photos with a
          // determinate progress ring, tagged with the send's client_id so the riser
          // observer swaps exactly this twin when the real row streams in. Previews
          // are snapshotted to data-URLs because the overlay's object URLs are
          // revoked on consume. A files-only send (no image/video preview) gets NO
          // node — files render as cards with no meaningful local preview, and an
          // empty album box would just flash; their real rows rise in normally.
          addOptimisticMedia(clientId, composeTiles, caption, photoCids) {
            // Snapshot every staged tile's frame IN ORDER — a photo's <img> or a
            // loaded video's first frame (#117). So a sent clip rises in with its
            // poster at full size, not a blank square that the real video later
            // pops into. A tile whose frame can't be grabbed yet falls back to a
            // fill so the album's tile count still matches the real row.
            // Snapshot each tile's frame AND its source pixel dimensions — the dims let
            // the lone-image case reserve its display box exactly like the real row.
            // `composeTiles` is ONE album's worth of compose tiles (#193): the caller splits a
            // big pick into batches of maxAlbum and builds a node per batch, so each album
            // appears and uploads on send, mirroring the server's per-album split.
            const allTiles = composeTiles.map((tile, i) => {
              const el = tile.querySelector(".ed-compose__img, .ed-compose__video")
              return {
                url: this.snapshot(el),
                w: (el && (el.naturalWidth || el.videoWidth)) || 0,
                h: (el && (el.naturalHeight || el.videoHeight)) || 0,
                video: !!el && el.tagName === "VIDEO",
                name: tile.dataset.name || "",
                size: tile.dataset.size || "",
                // The photo's own client_id (phase D) → drives its per-tile ring + cancel.
                cid: (photoCids && photoCids[i]) || null,
              }
            })
            if (allTiles.length === 0) return
            // A very wide/tall PHOTO (aspect > 5:1) renders as a file card, not inline —
            // mirror the server's strip_photo?/1 so the optimistic node matches the real row
            // (no inline-image → file-card jump on swap). Videos always stay inline.
            const isStrip = (t) =>
              !t.video && t.w > 0 && t.h > 0 && Math.max(t.w, t.h) / Math.min(t.w, t.h) > 5
            const tiles = allTiles.filter((t) => !isStrip(t))
            const strips = allTiles.filter(isStrip)
            const n = tiles.length

            // Match the REAL render so the swap doesn't reflow (#95 review): a message with a
            // SINGLE attachment renders via attachment_view (natural aspect, NOT a square album
            // tile); 2+ use the .ed-album grid. A lone inline photo that rides ALONGSIDE a strip
            // is still a ≥2-attachment message, so the server lays it out as a 1-tile mosaic —
            // hence the `strips.length === 0` guard (else the box→mosaic differ on swap).
            let media = null
            if (n === 1 && tiles[0].url && strips.length === 0) {
              const { w, h, video } = tiles[0]
              media = document.createElement("div")
              const img = document.createElement("img")
              img.src = tiles[0].url
              img.alt = ""
              if (video && w > 0 && h > w) {
                // Portrait video: match the real wide 4:5 box + ambient glow (snapshot as
                // the --vthumb backlight) so the optimistic→real swap doesn't jump narrow→wide.
                media.className = "ed-media-sending ed-media-sending--single ed-video-box--portrait"
                media.style.cssText =
                  "--vthumb:url('" + tiles[0].url + "'); width:min(20rem,80vw); aspect-ratio:4/5;"
                img.className = "ed-video"
                media.appendChild(img)
              } else {
                media.className = "ed-media-sending ed-media-sending--single"
                // Reserve the display box exactly like img_box/1 on the real <img>: an
                // explicit width + aspect-ratio. Without it the data-URL's natural size
                // (up to 800px) drove the bubble to its max while the img capped at 320,
                // leaving empty space to the right — and the box collapsed-then-grew.
                img.style.maxWidth = "100%"
                img.style.height = "auto"
                if (w > 0 && h > 0) {
                  const scale = Math.min(320 / w, 320 / h, 1)
                  img.style.width = Math.round(w * scale) + "px"
                  img.style.aspectRatio = w + " / " + h
                } else {
                  // A video sent before its metadata loaded (videoWidth === 0): no exact
                  // box yet, but cap the width so the data-URL's natural size can't blow
                  // the bubble to its max (the empty-space bug) while it settles.
                  img.style.width = "min(20rem, 100%)"
                }
                media.appendChild(img)
              }
            } else if (n >= 1) {
              // Justified mosaic matching the real album_view (AlbumLayout.rows/1): split into the
              // SAME aspect-balanced rows the server uses (balanceRows), each tile flex-grown by
              // its aspect, so the optimistic→real swap doesn't reflow. (A count-based split here
              // would regroup mixed-aspect rows on swap; a fixed-column grid left a bg strip.)
              media = document.createElement("div")
              media.className = "ed-album ed-media-sending"
              for (const rowTiles of this.balanceRows(tiles)) {
                const row = document.createElement("div")
                row.className = "ed-album__row"
                row.style.aspectRatio = String(
                  rowTiles.reduce((s, t) => s + this.albumAspect(t), 0),
                )
                for (const t of rowTiles) {
                  const tile = document.createElement("span")
                  tile.className = "ed-album__tile"
                  tile.style.flex = this.albumAspect(t) + " 1 0"
                  if (t.url) {
                    const img = document.createElement("img")
                    img.src = t.url
                    img.alt = ""
                    tile.appendChild(img)
                  } else {
                    tile.innerHTML = '<span class="ed-album__tile-fill"></span>'
                  }
                  // Phase D: each tile carries its OWN progress ring + cancel-X, keyed by the photo's
                  // client_id — so its upload fills its own arc and the X drops just that photo.
                  this.addTileControls(tile, t.cid)
                  row.appendChild(tile)
                }
                media.appendChild(row)
              }
            }
            // Strip photos render as file cards (mirrors @rest in album_view) after the
            // inline media — one per strip, with a snapshot thumb + name + size.
            const stripCards = strips.map((t) => {
              const card = document.createElement("div")
              card.className = "ed-file ed-file--photo ed-file--sending"
              const thumb = document.createElement("span")
              thumb.className = "ed-file__thumb"
              if (t.url) {
                const img = document.createElement("img")
                img.src = t.url
                img.alt = ""
                thumb.appendChild(img)
              }
              card.appendChild(thumb)
              const meta = document.createElement("span")
              meta.className = "ed-file__meta"
              const nm = document.createElement("span")
              nm.className = "ed-file__name"
              nm.textContent = t.name
              const sz = document.createElement("span")
              sz.className = "ed-file__size"
              sz.textContent = t.size
              meta.appendChild(nm)
              meta.appendChild(sz)
              card.appendChild(meta)
              return { card, thumb }
            })
            // Invariant from here on: `media` and `stripCards` are never both empty. The early
            // `allTiles.length === 0` return guarantees ≥1 tile; a tile is either inline media
            // (→ `media`) or a strip (→ `stripCards`). So `media || stripCards[0]` always resolves.
            //
            // Per-PHOTO ring + cancel (phase D): each photo fills its OWN arc and its X drops just
            // that photo (the album sends with the rest). Mosaic tiles got theirs above; a LONE
            // inline photo and each strip card get theirs here.
            if (media && n === 1) this.addTileControls(media, tiles[0].cid)
            stripCards.forEach(({ thumb }, k) => this.addTileControls(thumb, strips[k].cid))

            // No strips (the common path): the inline media node IS the content. With strips,
            // the inline media (if any) and the strip cards stack as siblings inside .ed-media.
            let content
            if (stripCards.length === 0) {
              content = media
            } else {
              content = document.createElement("div")
              content.className = "ed-media-sending__group"
              if (media) content.appendChild(media)
              for (const { card } of stripCards) content.appendChild(card)
            }

            const row = this.wrapAndAppendOptimistic(content, clientId, caption)
            // Stash this album's File keys + caption so a failed card can re-send the whole album.
            const keys = composeTiles.map((t) => this.tileFileKey(t)).filter(Boolean)
            if (row && keys.length) {
              row.dataset.fileKeys = JSON.stringify(keys)
              row.dataset.caption = caption || ""
            }
            return row
          },
          // Optimistic node for a photos-only "Send as file" album (#122): mirror the real
          // render — each photo as a document card (snapshot thumb + name + size), never an
          // inline album — so a slow upload doesn't show an album that reshapes into cards on
          // swap. One ring + one cancel for the whole album (its single client_id), matching
          // addOptimisticMedia's model. data-name/size ride the staged tiles.
          addOptimisticAsFile(clientId, tiles, caption, photoCids) {
            // `tiles` is ONE album's worth (#193) — the caller splits a big pick into batches.
            if (tiles.length === 0) return null
            const wrap = document.createElement("div")
            wrap.className = "ed-asfile-sending"
            tiles.forEach((tile, i) => {
              const card = document.createElement("div")
              card.className = "ed-file ed-file--photo ed-file--sending"
              const thumb = document.createElement("span")
              thumb.className = "ed-file__thumb"
              const url = this.snapshot(tile.querySelector(".ed-compose__img"))
              if (url) {
                const img = document.createElement("img")
                img.src = url
                img.alt = ""
                thumb.appendChild(img)
              }
              // Phase D: each "send as file" card fills its OWN ring + cancel-X (its X drops just
              // that photo). data-item-cid on the card → its progress + cancel + stall route to it.
              const cid = photoCids && photoCids[i]
              if (cid) {
                card.dataset.itemCid = cid
                card.classList.add("ed-tile--sending")
                thumb.appendChild(this.buildRing("ed-file__ring"))
                thumb.appendChild(this.buildCancel(() => this.cancelSeqPhoto(cid)))
              }
              card.appendChild(thumb)
              const meta = document.createElement("span")
              meta.className = "ed-file__meta"
              const nm = document.createElement("span")
              nm.className = "ed-file__name"
              nm.textContent = tile.dataset.name || ""
              const sz = document.createElement("span")
              sz.className = "ed-file__size"
              sz.textContent = tile.dataset.size || ""
              meta.appendChild(nm)
              meta.appendChild(sz)
              card.appendChild(meta)
              wrap.appendChild(card)
            })
            // Document cards, not inline media → the normal padded bubble (isFile).
            const row = this.wrapAndAppendOptimistic(wrap, clientId, caption, true)
            // Stash the album's File keys + the as-file flag so a failed card re-sends as docs.
            const keys = tiles.map((t) => this.tileFileKey(t)).filter(Boolean)
            if (row && keys.length) {
              row.dataset.fileKeys = JSON.stringify(keys)
              row.dataset.asFile = "true"
              row.dataset.caption = caption || ""
            }
            return row
          },
          // Mirror album_row_sizes/1 (server): the count plan for N media (4→2+2, a trailing
          // remainder of 1 folded into 2+2). Only its LENGTH is used now — it sets how many
          // rows balanceRows fills; the actual per-row split is aspect-balanced below.
          // The album cap (server's @max_album_entries, #193) — one album's worth of media.
          // A pick beyond it stages whole (max_staged_entries) and the server splits it into
          // albums of this size; the optimistic node mirrors only the first.
          maxAlbum() {
            return Number(this.el.dataset.maxAlbum) || 10
          },
          // Most media one pick may stage at once (server's max_staged_entries, #193). A pick
          // past it is capped in onPick (the config can't take more, and the excess would wedge
          // the whole upload); what stages is split into albums of maxAlbum server-side.
          maxStaged() {
            return Number(this.el.dataset.maxStaged) || 50
          },
          albumRowSizes(n) {
            if (n <= 3) return [n]
            if (n === 4) return [2, 2]
            const r = n % 3
            if (r === 0) return Array(n / 3).fill(3)
            if (r === 1) return Array(Math.floor(n / 3) - 1).fill(3).concat([2, 2])
            return Array(Math.floor(n / 3)).fill(3).concat([2])
          },
          // Mirror album_aspect/1 (server): an item's display aspect, clamped to [0.5, 2.6] and
          // rounded to 4dp so the optimistic flex-grow/row-height math matches the real render
          // exactly (sub-pixel-faithful, no drift on swap). Missing dims fall back to square.
          albumAspect(t) {
            return t.w > 0 && t.h > 0
              ? Math.round(Math.min(2.6, Math.max(0.5, t.w / t.h)) * 1e4) / 1e4
              : 1
          },
          // Mirror chunk_album_rows/1 + balance_rows/3 (server): split tiles into the SAME
          // number of rows as the count plan, but distribute by aspect so each row's aspect-sum
          // is ~equal (→ rows of ~equal height). Uniform photos reproduce the clean count grid;
          // mixed aspects group identically to the server, so the swap never reshuffles rows.
          balanceRows(tiles) {
            const r0 = this.albumRowSizes(tiles.length).length
            const balance = (items, r) => {
              if (r <= 1) return [items]
              const target = items.reduce((s, t) => s + this.albumAspect(t), 0) / r
              const row = []
              let sum = 0
              let i = 0
              while (i < items.length) {
                // Always take ≥1 (row empty); always leave ≥1 for each of the r-1 remaining
                // rows; otherwise fill toward the target aspect-sum.
                if (row.length > 0 && (items.length - i <= r - 1 || sum >= target)) break
                row.push(items[i])
                sum += this.albumAspect(items[i])
                i++
              }
              return [row, ...balance(items.slice(i), r - 1)]
            }
            return balance(tiles, r0)
          },
          // Build the determinate progress ring (#95/#149): a faint track + a fill arc.
          // `cls` styles/sizes the container per context (media = white-on-scrim overlay;
          // file = currentColor, sized to the icon slot). The fill/track circle classes
          // stay shared so setRing drives either one unchanged (same r=16 geometry).
          buildRing(cls) {
            const ring = document.createElement("span")
            ring.className = cls
            ring.setAttribute("aria-hidden", "true")
            ring.innerHTML =
              '<svg viewBox="0 0 36 36">' +
              '<circle class="ed-media-sending__ring-track" cx="18" cy="18" r="16"></circle>' +
              '<circle class="ed-media-sending__ring-fill" cx="18" cy="18" r="16"></circle>' +
              "</svg>"
            return ring
          },
          // An in-flight cancel-X for an optimistic upload node (#137): runs onClick (which
          // aborts the upload + removes the node). Reused on the file card and the media node.
          buildCancel(onClick) {
            const btn = document.createElement("button")
            btn.type = "button"
            btn.className = "ed-sending-cancel"
            btn.setAttribute("aria-label", this.el.dataset.cancelLabel || "Cancel")
            btn.innerHTML = '<span class="hero-x-mark-micro size-3.5" aria-hidden="true"></span>'
            btn.addEventListener("click", (e) => {
              e.preventDefault()
              e.stopPropagation()
              onClick()
            })
            return btn
          },
          // The edenFiles key (name:size:lastModified) for a staged compose tile — read off the
          // inner <img>/<video>, which carry the raw client_size + client_last_modified. Lets a
          // failed album/photo/video card look its original File(s) back up to re-send.
          tileFileKey(tile) {
            const el = tile.querySelector(".ed-compose__img, .ed-compose__video")
            if (!el) return null
            return (el.dataset.name || "") + ":" + (el.dataset.size || "") + ":" + (el.dataset.modified || "")
          },
          // Re-send failed File(s) through the DEDICATED :attachment_retry channel (#…). Reusing
          // :attachment is unreliable: cancelling its in-flight entry leaves the config unable to
          // accept new entries + races the cancelled upload's late progress (a crash). The retry
          // config is auto_upload and NEVER cancelled, so the clones stage + upload cleanly for
          // every kind (lone photo/video, album, file). Clone each File with a nudged lastModified
          // — a fresh identity so LiveView's identity-dedup doesn't drop it as "already seen" (the
          // original entry carried the same identity). Sequence: stash metadata on the server
          // (retry_prepare) FIRST — its reply guarantees pending_retry is set before the auto-
          // upload finishes — THEN feed the clones. `opts`: {node, cid, files, caption, asFile,
          // media}. On completion the server sends the message + pushes retry_done to settle the
          // card. The reply carries {ok}: only feed when the server accepted this retry — it
          // REFUSES (busy) while another retry is in flight (#310 review P1, single pending slot),
          // in which case we revert the card to failed so the user can retry once it frees.
          retrySend(opts) {
            const fresh = opts.files.map(
              (f) => new File([f], f.name, { type: f.type, lastModified: (f.lastModified || 0) + 1 }),
            )
            this.pushEvent(
              "retry_prepare",
              {
                client_id: opts.cid,
                caption: opts.caption || "",
                as_file: !!opts.asFile,
                media: !!opts.media,
                group_id: opts.groupId || null,
              },
              (reply) => {
                if (reply && reply.ok) {
                  const input = this.el.querySelector('input[type="file"][name="attachment_retry"]')
                  if (input) this.feedInput(input, fresh)
                } else {
                  this.onRetryDone({ id: opts.cid, ok: false })
                }
              },
            )
          },
          // Optimistic card for a file/doc send (#149): files post one message PER file, so
          // each gets its own card + client_id and a determinate ring IN the icon slot
          // (data-upload-ref → the server's per-file media_progress drives it). Mirrors the
          // real .ed-file card so the riser's data-client-id swap doesn't reflow.
          addOptimisticFile(clientId, ref, name, size, key) {
            const card = document.createElement("div")
            // mb-1 mirrors the real attachment_view card (#308 review P3): without it the optimistic
            // bubble is 4px shorter and nudges taller when the real row swaps in.
            card.className = "ed-file ed-file--sending mb-1"
            card.dataset.uploadRef = ref
            // Stash the retry key + display bits so a failed card can re-send its File (#…).
            if (key) card.dataset.fileKey = key
            card.dataset.fileName = name || ""
            card.dataset.fileSize = size || ""
            const label = this.el.dataset.sendingLabel
            // Function replacement so a filename with $-patterns ($&, $1) isn't interpreted.
            if (label) card.setAttribute("aria-label", label.replace("{name}", () => name || ""))
            const icon = document.createElement("span")
            icon.className = "ed-file__icon"
            icon.appendChild(this.buildRing("ed-file__ring"))
            // In-flight cancel (#137) centered INSIDE the ring (Telegram-style): the progress
            // arc tracks around the X. Drops THIS file's queued item (+ aborts it if in flight)
            // and removes its row; a late tap after the swap is a harmless no-op.
            icon.appendChild(
              this.buildCancel(() => {
                this.cancelSeqItem(clientId)
                card.closest(".ed-msg, .ed-flat")?.remove()
              }),
            )
            card.appendChild(icon)
            const meta = document.createElement("span")
            meta.className = "ed-file__meta"
            const nm = document.createElement("span")
            nm.className = "ed-file__name"
            // The raw client filename; the real card shows the server-sanitized name, so a
            // name with stripped chars may shift by a frame on swap (cosmetic, #149).
            nm.textContent = name || ""
            const sz = document.createElement("span")
            sz.className = "ed-file__size"
            sz.textContent = size || ""
            meta.appendChild(nm)
            meta.appendChild(sz)
            card.appendChild(meta)
            // No caption on a file card — a files-only caption rides as its own trailing
            // message below the pile (#149). isFile → the normal padded bubble (not --media).
            return this.wrapAndAppendOptimistic(card, clientId, undefined, true)
          },
          // Wrap an optimistic content node (a media node OR a file card) into a bubble/flat
          // row tagged with its client_id, append it to #pending, animate it in, pin to the
          // bottom, and return the row. One shared seam for every kind (#149), so the riser
          // swap + the stall watchdog treat media and files identically.
          wrapAndAppendOptimistic(content, clientId, caption, isFile = false) {
            const row = document.createElement("div")
            row.dataset.clientId = clientId
            // Tag the conversation that owns this in-flight media/file node (#144): the
            // upload keeps running after you leave (it's pinned to its conversation), so
            // a switch HIDES this node instead of wiping it, and re-shows it on return —
            // background-upload progress survives leaving the chat. Text optimistic twins
            // are intentionally NOT tagged (they stay queue/timer-bound to this chat).
            row.dataset.convId = this.convId
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
              main.appendChild(content)
              // Caption below the content, mirroring the real flat row's .ed-flat__body,
              // so it shows during upload (not only when the real row arrives).
              if (caption) {
                const body = document.createElement("div")
                body.className = "break-words ed-flat__body"
                body.textContent = caption
                main.appendChild(body)
              }
              row.appendChild(main)
            } else {
              row.className = "ed-msg flex justify-end"
              const bubble = document.createElement("div")
              const time = new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
              const ticks =
                this.el.dataset.isGroup !== "true"
                  ? '<span class="inline-flex items-center" style="margin-left:2px;">' +
                    '<span class="hero-check-micro size-3.5"></span></span>'
                  : ""
              if (isFile) {
                // A FILE (or "send as file" docs) keeps the NORMAL padded bubble — mirror
                // message_bubble's media?==false branch: no --media (else the card's own
                // translucent fill stacks on the cobalt bubble as "two bubbles" and the time
                // overlay + cancel-X collide). The card sits in the padded bubble; a normal
                // .ed-bubble__cap holds the optional caption + the meta row (time + ticks).
                bubble.className = "ed-bubble ed-bubble--me"
                bubble.appendChild(content)
                const cap = document.createElement("div")
                cap.className = "ed-bubble__cap"
                if (caption) {
                  const capText = document.createElement("span")
                  capText.className = "break-words"
                  capText.textContent = caption
                  cap.appendChild(capText)
                }
                const meta = document.createElement("span")
                meta.className = "ed-bubble__meta"
                meta.innerHTML = "<time>" + time + "</time>" + ticks
                cap.appendChild(meta)
                bubble.appendChild(cap)
              } else {
                // Real inline media: mirror the media bubble EXACTLY so the optimistic twin is
                // the same height (no swap nudge) and frameless — --media zeroes the padding,
                // media fills .ed-media, the time overlays (no caption) or rides .ed-bubble__cap.
                bubble.className = "ed-bubble ed-bubble--me ed-bubble--media"
                const mediaWrap = document.createElement("div")
                mediaWrap.className = "ed-media"
                mediaWrap.appendChild(content)
                if (!caption) {
                  const t = document.createElement("span")
                  t.className = "ed-media-time"
                  t.innerHTML = "<time>" + time + "</time>" + ticks
                  mediaWrap.appendChild(t)
                }
                bubble.appendChild(mediaWrap)
                if (caption) {
                  const cap = document.createElement("div")
                  cap.className = "ed-bubble__cap ed-bubble__cap--media"
                  const capText = document.createElement("span")
                  capText.className = "break-words"
                  capText.textContent = caption
                  cap.appendChild(capText)
                  const meta = document.createElement("span")
                  meta.className = "ed-bubble__meta"
                  meta.innerHTML = "<time>" + time + "</time>" + ticks
                  cap.appendChild(meta)
                  bubble.appendChild(cap)
                }
              }
              row.appendChild(bubble)
            }
            this.pending.appendChild(row)
            row.classList.add("ed-msg--enter")
            setTimeout(() => row.classList.remove("ed-msg--enter"), 200)
            // Pin to the just-sent photo. The preview image decodes async (no height yet),
            // so an immediate scroll lands short; re-pin on each image's load too (#104). This
            // keeps us glued to the bottom through the grow, so the photo never hides below
            // the fold even when the grow exceeds the ScrollBottom pinned threshold.
            const pin = () => {
              if (!this.scroller) return
              const smooth = !window.matchMedia("(prefers-reduced-motion: reduce)").matches
              this.scroller.scrollTo({ top: this.scroller.scrollHeight, behavior: smooth ? "smooth" : "auto" })
            }
            pin()
            row.querySelectorAll("img").forEach((img) => {
              if (!img.complete) img.addEventListener("load", pin, { once: true })
            })
            return row
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
          // Stall watchdog (#95/#149): if an upload makes NO progress for 90s WHILE CONNECTED
          // — a dropped link is frozen in disconnected() and resumes on reconnect, so this only
          // fires for a genuinely wedged upload — mark the node FAILED (red !, with resend +
          // delete) instead of silently dropping it. Takes the optimistic ROW directly; every
          // media_progress tick re-arms it, so a merely-slow upload is never killed; a row
          // removed by the swap leaves a harmless dead timer (no-ops once disconnected).
          armStall(node) {
            if (!node) return
            if (node._stall) clearTimeout(node._stall)
            node._stall = setTimeout(() => {
              if (!node.isConnected) return
              const retry = node.dataset.retry === "true"
              // A whole :attachment batch stalls together, but each optimistic card armed its OWN
              // timer — fail the batch AT ONCE and clear the siblings' timers (#309 review P1), so
              // no straggler later fires a second media_send_reset (the double-fire crash race, or
              // nuking a send the user has since re-staged). Skip retry nodes (their own channel).
              if (!retry && this.pending) {
                for (const row of this.pending.children) {
                  if (row === node || row.dataset.retry === "true" || !row._stall) continue
                  clearTimeout(row._stall)
                  row._stall = null
                  if (row.querySelector(".ed-file--sending, .ed-media-sending, .ed-asfile-sending")) {
                    this.markUploadFailed(row)
                  }
                }
              }
              // Client: turn the node into the visible failed state (keeps it, with resend +
              // delete). Server: cancel the wedged staged entries — WITHOUT the flash (the inline
              // ! is the visible failure). Resend re-stages from the File stash; delete drops it.
              this.markUploadFailed(node)
              // A retrying node lives on the dedicated :attachment_retry channel — reset THAT
              // (drop its pristine entries + pending metadata), not the main :attachment send.
              this.pushEvent(retry ? "retry_reset" : "media_send_reset", {})
            }, 90000)
          },
          // A stalled upload → a visible failure the user controls, never a silent drop. Route by
          // the real per-file FILE card: it carries data-upload-ref (#310 review P1) — a "send as
          // file" doc card or an album strip card is ALSO .ed-file--sending but has no ref, so it
          // belongs to the media pile (markMediaFailed offers its row-level Resend), not the file
          // path (which would find no File key → no Resend button).
          markUploadFailed(node) {
            const card = node.querySelector(".ed-file--sending[data-upload-ref]")
            if (card) return this.markFileFailed(card)
            return this.markMediaFailed(node)
          },
          // Turn an in-flight FILE card into a failed one: red !, "Not sent", + Resend
          // (re-uploads the File stashed at pick) + Delete. Re-send works even when the upload
          // wedged with the link up, since the original File is stashed.
          markFileFailed(card) {
            if (card.classList.contains("ed-file--failed")) return
            card.classList.remove("ed-file--sending")
            card.classList.add("ed-file--failed")
            // Drop the bubble's delivery tick (✓) — it never sent, so a "delivered" check next
            // to "Not sent" is contradictory. The time stays; the ! + Resend/Delete carry the state.
            card.closest(".ed-bubble")?.querySelector(".ed-bubble__meta .inline-flex")?.remove()
            const ref = card.dataset.uploadRef
            const icon = card.querySelector(".ed-file__icon")
            if (icon) {
              icon.innerHTML =
                '<span class="hero-exclamation-circle-mini size-6" aria-hidden="true"></span>'
            }
            const notSent = this.el.dataset.notSent || "Not sent"
            const sz = card.querySelector(".ed-file__size")
            if (sz) sz.textContent = notSent
            // Replace the stale "Sending {name}" SR label — it's no longer sending (#310 review P3).
            card.setAttribute("aria-label", (card.dataset.fileName || "") + " — " + notSent)
            const actions = document.createElement("div")
            actions.className = "ed-file__actions"
            const file = card.dataset.fileKey && this.el.edenFiles?.get(card.dataset.fileKey)
            if (file) {
              const retry = document.createElement("button")
              retry.type = "button"
              retry.className = "ed-file__act"
              retry.textContent = this.el.dataset.resend || "Resend"
              retry.addEventListener("click", (e) => {
                e.preventDefault(); e.stopPropagation()
                this.retryFile(card, ref, file)
              })
              actions.appendChild(retry)
            }
            const del = document.createElement("button")
            del.type = "button"
            del.className = "ed-file__act ed-file__act--danger"
            del.textContent = this.el.dataset.delete || "Delete"
            del.addEventListener("click", (e) => {
              e.preventDefault(); e.stopPropagation()
              // The entry was already cancelled when the stall fired (media_send_reset), so
              // just drop the failed card — no cancel_upload (it would raise on the gone ref).
              card.closest(".ed-msg, .ed-flat")?.remove()
            })
            actions.appendChild(del)
            card.querySelector(".ed-file__meta")?.appendChild(actions)
          },
          // Re-send a failed file: keep the card in place as the in-flight indicator (restore its
          // sending look via markRetrying), give it a FRESH client_id so the real retry message
          // swaps it in, arm the stall watchdog, and fire the send down the dedicated channel.
          retryFile(card, _ref, file) {
            const node = card.closest(".ed-msg, .ed-flat")
            if (!node) return
            // Inherit the send's group_id so the resent row rejoins its merged file bubble.
            const groupId = node.dataset.groupId || null
            const cid = this.uuid()
            node.dataset.clientId = cid
            this.markRetrying(node)
            this.armStall(node)
            this.retrySend({ files: [file], asFile: false, media: false, caption: "", cid, groupId })
          },
          // Re-send a failed media album / lone photo / video / "send as file" pile from the
          // stashed Files, keeping the node as the in-flight indicator (same channel as files).
          retryMedia(node, keys, asFile) {
            const files = keys.map((k) => this.el.edenFiles?.get(k)).filter(Boolean)
            if (!files.length || files.length !== keys.length) return
            const cid = this.uuid()
            node.dataset.clientId = cid
            this.markRetrying(node)
            this.armStall(node)
            this.retrySend({
              files,
              asFile,
              media: true,
              caption: node.dataset.caption || "",
              cid,
            })
          },
          // Turn a FAILED card back into an in-flight one for the duration of a Resend: drop the
          // failed affordances (! / actions / bar) and restore the sending ring, so a re-failure
          // (retry_done !ok or the stall watchdog) can cleanly re-mark it via markUploadFailed.
          markRetrying(node) {
            node.dataset.retry = "true"
            node.classList.add("ed-msg--retrying")
            const fcard = node.querySelector(".ed-file--failed")
            if (fcard) {
              fcard.classList.remove("ed-file--failed")
              fcard.classList.add("ed-file--sending")
              fcard.querySelector(".ed-file__actions")?.remove()
              const icon = fcard.querySelector(".ed-file__icon")
              if (icon) {
                icon.innerHTML = ""
                icon.appendChild(this.buildRing("ed-file__ring"))
              }
              const sz = fcard.querySelector(".ed-file__size")
              if (sz) sz.textContent = fcard.dataset.fileSize || ""
            }
            // Media pile: dropping the failed bar reveals its ring again.
            node.querySelector(".ed-upload-failed__bar")?.remove()
          },
          // Settle a Resend (#…): on success the real message's client_id swap already removed the
          // node, so just kill its watchdog; on failure re-mark it failed (Resend/Delete return).
          onRetryDone({ id, ok }) {
            const node = this.pending?.querySelector(`[data-client-id="${id}"]`)
            if (!node) return
            if (node._stall) {
              clearTimeout(node._stall)
              node._stall = null
            }
            // No longer retrying, either way: on ok the client_id swap removes the node; on failure
            // re-mark it failed (Resend/Delete return). Clear the retry flag so a stale marker
            // can't misroute a later watchdog to retry_reset.
            delete node.dataset.retry
            if (!ok) {
              node.classList.remove("ed-msg--retrying")
              this.markUploadFailed(node)
            }
          },
          // A failed media album / lone photo / video / "send as file" pile: red ! + Resend
          // (re-sends the whole album from the stashed Files) + Delete. Resend shows only when
          // every File is still stashed (edenFiles) — otherwise the album can't be rebuilt.
          markMediaFailed(node) {
            if (node.querySelector(".ed-upload-failed__bar")) return
            const host = node.querySelector(".ed-media-sending, .ed-asfile-sending") || node
            host.querySelectorAll(".ed-sending-cancel").forEach((c) => c.remove())
            const bar = document.createElement("div")
            bar.className = "ed-upload-failed__bar"
            bar.innerHTML =
              '<span class="ed-upload-failed__bang">' +
              '<span class="hero-exclamation-circle-mini size-5" aria-hidden="true"></span></span>'
            let keys = []
            try {
              keys = JSON.parse(node.dataset.fileKeys || "[]")
            } catch (_e) {
              keys = []
            }
            const asFile = node.dataset.asFile === "true"
            const haveAll = keys.length > 0 && keys.every((k) => this.el.edenFiles?.has(k))
            if (haveAll) {
              const retry = document.createElement("button")
              retry.type = "button"
              retry.className = "ed-file__act"
              retry.textContent = this.el.dataset.resend || "Resend"
              retry.addEventListener("click", (e) => {
                e.preventDefault(); e.stopPropagation()
                this.retryMedia(node, keys, asFile)
              })
              bar.appendChild(retry)
            }
            const del = document.createElement("button")
            del.type = "button"
            del.className = "ed-file__act ed-file__act--danger"
            del.textContent = this.el.dataset.delete || "Delete"
            del.addEventListener("click", (e) => {
              e.preventDefault(); e.stopPropagation()
              // Entries were already cancelled when the stall fired (media_send_reset), so just
              // drop the failed node — no cancel_all_uploads (redundant; matches the file card).
              node.remove()
            })
            bar.appendChild(del)
            host.appendChild(bar)
          },
          // Snapshot a loaded preview <img> to a persistent JPEG data-URL. Returns
          // null on taint/empty so the node just shows the ring over a blank tile.
          snapshot(el) {
            if (!el) return null
            try {
              // An <img> exposes naturalWidth/Height; a loaded <video> exposes
              // videoWidth/Height (#117). drawImage paints either's current frame.
              let w = el.naturalWidth || el.videoWidth || el.width
              let h = el.naturalHeight || el.videoHeight || el.height
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
              c.getContext("2d").drawImage(el, 0, 0, w, h)
              return c.toDataURL("image/jpeg", 0.7)
            } catch (_e) {
              return null
            }
          },
          // Capture a local object URL for each staged video at SELECTION time (#117)
          // — the most reliable point, since the upload entry never exposes its File
          // to a hook. Keyed "name:size:lastModified" (deduped, so the input/change
          // pair and the compress re-dispatch don't double-create); .VideoPreview
          // reads it back.
          captureVideoUrls(e) {
            const input = e.target
            if (!(input instanceof HTMLInputElement) || input.type !== "file") return
            for (const f of input.files || []) {
              // name+size alone collide for two different files of equal weight; lastModified
              // adds the distinguishing entropy (it matches entry.client_last_modified).
              const key = f.name + ":" + f.size + ":" + f.lastModified
              // Stash EVERY picked File so a failed upload can be re-sent (the entry's File is
              // gone once cancelled). Keyed the same way as the previews below.
              if (!this.el.edenFiles.has(key)) this.el.edenFiles.set(key, f)
              // video AND image: .VideoPreview + .ImgPreview both read these back. Images use
              // it so the compose preview is OUR crash-safe <img>, not LiveView's
              // <.live_img_preview> (whose mounted() threw createObjectURL(undefined) on a
              // consumed entry mid-send, aborting the patch → empty modal).
              if (!/^(video|image)\//.test(f.type || "")) continue
              if (!this.el.edenVideoUrls.has(key)) {
                this.el.edenVideoUrls.set(key, URL.createObjectURL(f))
              }
            }
          },
          // Re-feed an input with an exact File set so LiveView stages it (set files +
          // dispatch input/change — the proven PasteUpload path). Used to flush a queued
          // batch (#119) into the freed config.
          feedInput(input, files) {
            const dt = new DataTransfer()
            files.forEach((f) => dt.items.add(f))
            input.files = dt.files
            input.dispatchEvent(new Event("input", { bubbles: true }))
            input.dispatchEvent(new Event("change", { bubbles: true }))
          },
          // Route a thread album/file send through the sequential feeder (phase F trim). Called by
          // .ThreadSendQueue with the raw File objects it captured (threads have no client-side
          // compose overlay + no optimistic nodes — flat replies stream in from the server as each
          // item lands, so this builds NO optimistic UI, just the queue). Media splits into albums
          // of maxAlbum; files each become their own reply; ≥2 files share a group_id (server-minted
          // in queue_start). The reply body is the caption — inline on the first album, or a trailing
          // reply when it's files-only. Each item carries its File directly (item.file) so pumpSeq
          // feeds it without needing the main composer's edenFiles stash.
          enqueueThreadSeq({ files, caption, rootId }) {
            // The root id must reach the server as a NUMBER (sanitize_root_id requires an integer;
            // a string "123" would decode as a binary and be dropped → the send would leak to the
            // main stream). dataset values are strings, so coerce + guard here.
            const root_id = Number(rootId)
            if (!Number.isInteger(root_id) || root_id <= 0) return
            const isMedia = (f) => /^(image|video)\//.test(f.type || "")
            const media = files.filter(isMedia)
            const docs = files.filter((f) => !isMedia(f))
            const albumSpecs = []
            const seqItems = []
            for (let i = 0; i < media.length; i += this.maxAlbum()) {
              const batch = media.slice(i, i + this.maxAlbum())
              const cid = this.uuid()
              albumSpecs.push({ cid, count: batch.length })
              batch.forEach((f) =>
                seqItems.push({ kind: "media", albumCid: cid, clientId: this.uuid(), file: f }),
              )
            }
            const fileCids = []
            docs.forEach((f) => {
              const cid = this.uuid()
              fileCids.push(cid)
              seqItems.push({ kind: "file", clientId: cid, file: f })
            })
            if (!seqItems.length) return
            // A files-only caption rides its own trailing reply (like the main composer's #149
            // trailing text); a caption WITH media rides the first album inline (server-side).
            const captionId = !media.length && caption && fileCids.length ? this.uuid() : null
            const queueId = this.uuid()
            this.pushEvent(
              "queue_start",
              {
                queue_id: queueId,
                caption,
                caption_id: captionId,
                as_file: false,
                albums: albumSpecs,
                file_cids: fileCids,
                root_id: root_id,
              },
              () => {
                ;(this.seqQueues = this.seqQueues || []).push({ queueId, items: seqItems })
                this.pumpSeq()
              },
            )
          },
          // ── Sequential send feeder (TG-attachments) ──────────────────────────────────────────
          // Feed ONE queued item's clone into :attachment_seq, wait for the server's seq_done, then
          // pump the next. `seqFeeding` guards the single-in-flight invariant (one entry at a time).
          pumpSeq() {
            if (this.seqFeeding) return
            const queue = (this.seqQueues || []).find((q) => q.items.length)
            if (!queue) return
            const item = queue.items[0]
            this.seqFeeding = item
            // Announce the item first (reply-gated, like retry_prepare) so the server's metadata is
            // set before the entry's first progress tick; only feed on ok (it busy-refuses a second
            // item while one is in flight).
            this.pushEvent(
              "seq_item",
              {
                queue_id: queue.queueId,
                client_id: item.clientId,
                kind: item.kind,
                album_cid: item.albumCid || null,
              },
              (reply) => {
                if (!(reply && reply.ok)) {
                  this.seqFeeding = null
                  // Busy = another item in flight → retry shortly. Any other refusal (e.g. a stale
                  // queue) → drop this item instead of looping forever on it.
                  if (reply && reply.busy) setTimeout(() => this.pumpSeq(), 80)
                  else this.onSeqDone(item.clientId)
                  return
                }
                // A resumed item (phase E) carries its durable blob directly; a fresh send looks the
                // File up in edenFiles by key.
                const f = item.file || this.el.edenFiles?.get(item.key)
                const input = this.el.querySelector('input[type="file"][name="attachment_seq"]')
                if (f && input) {
                  // Clone with a nudged lastModified so LiveView's identity-dedup stages it fresh;
                  // clear the input first so a just-consumed entry's identity can't block the feed.
                  const clone = new File([f], f.name, {
                    type: f.type,
                    lastModified: (f.lastModified || 0) + 1,
                  })
                  input.value = ""
                  this.feedInput(input, [clone])
                  // Arm the stall watchdog for THIS item now that it's actually uploading (queued
                  // items stay unarmed until their turn); seq_progress re-arms on each tick. A media
                  // photo arms its own TILE (data-item-cid); a file its card row.
                  const node = this.pending?.querySelector(
                    item.kind === "media"
                      ? `[data-item-cid="${item.clientId}"]`
                      : `[data-client-id="${item.clientId}"]`,
                  )
                  this.armSeqStall(node)
                } else {
                  // The File is gone (edenFiles cleared / never stashed) — the server already set
                  // seq_pending from the reply, so tell it to release the slot + drop this item's
                  // count (seq_reset), else the queue can't finalize and later items are refused.
                  this.pushEvent("seq_reset", {})
                  this.seqFeeding = null
                  this.onSeqDone(item.clientId)
                }
              },
            )
          },
          // A queued item finished on the server (its real row/album streamed in and swapped its
          // optimistic node) — drop it from its queue and pump the next.
          onSeqDone(id) {
            this.seqFeeding = null
            // Clear the nodeless (thread) watchdog so a just-finished item can't seq_reset the next.
            if (this._seqStall) {
              clearTimeout(this._seqStall)
              this._seqStall = null
            }
            // A finished album photo: retire its tile's ring + cancel-X (its source is now
            // accumulated server-side, so cancelling it here would only fade the tile while the
            // album still sends it — phase D review). A done photo simply shows clean.
            const tile = this.pending?.querySelector(`[data-item-cid="${id}"]`)
            if (tile) {
              tile.classList.remove("ed-tile--sending")
              tile.querySelector(".ed-sending-cancel")?.remove()
              tile.querySelector(".ed-media-sending__ring")?.remove()
            }
            for (const q of this.seqQueues || []) {
              const idx = q.items.findIndex((it) => it.clientId === id)
              if (idx >= 0) {
                this.forgetStored(q.items[idx])
                q.items.splice(idx, 1)
                break
              }
            }
            this.seqQueues = (this.seqQueues || []).filter((q) => q.items.length)
            this.pumpSeq()
          },
          // Drop an item's durable record (phase E) once it's resolved (sent/cancelled/failed), so a
          // later reload doesn't re-upload it. No-op without a store / storeId.
          forgetStored(item) {
            if (item && item.storeId && window.__edenSendStore) window.__edenSendStore.remove(item.storeId)
          },
          // Resume interrupted sends after a reload (phase E): scan the durable store for this user's
          // unfinished items IN THE CURRENT conversation, rebuild their optimistic rows, and re-open
          // + re-feed each queue. Other-conversation queues wait for a load into that chat (they GC
          // after 24h). Idempotent across tabs: the server dedups by client_id, so a redundant resume
          // can't double-send.
          async resumeSends() {
            const store = window.__edenSendStore
            const userId = this.el.dataset.senderId
            if (!store || !userId || !this.pending) return
            let records
            try {
              records = await store.listUnfinished(userId)
            } catch (_e) {
              return
            }
            records = (records || []).filter((r) => String(r.convId) === String(this.convId))
            if (!records.length) return
            const byQueue = new Map()
            for (const r of records) {
              if (!byQueue.has(r.queueId)) byQueue.set(r.queueId, [])
              byQueue.get(r.queueId).push(r)
            }
            for (const [queueId, recs] of byQueue) this.resumeQueue(queueId, recs)
          },
          resumeQueue(queueId, recs) {
            recs.sort((a, b) => a.order - b.order)
            const first = recs[0]
            const items = recs.map((r) => ({
              kind: r.kind,
              albumCid: r.albumCid,
              clientId: r.clientId,
              storeId: r.id,
              file: r.file,
            }))
            // Rebuild the optimistic FILE cards so the resume is visible (a media album re-uploads
            // silently and its real row streams in on completion).
            recs.forEach((r) => {
              if (r.kind !== "file") return
              const node = this.addOptimisticFile(r.clientId, "", r.name || "", r.sizeLabel || "", null)
              if (node && r.groupId) node.dataset.groupId = r.groupId
            })
            const fileCids = recs.filter((r) => r.kind === "file").map((r) => r.clientId)
            const albumMap = new Map()
            recs
              .filter((r) => r.kind === "media")
              .forEach((r) => albumMap.set(r.albumCid, (albumMap.get(r.albumCid) || 0) + 1))
            const albums = [...albumMap.entries()].map(([cid, count]) => ({ cid, count }))
            this.pushEvent(
              "queue_resume",
              {
                queue_id: queueId,
                group_id: first.groupId || null,
                conv_id: first.convId,
                caption: first.caption || "",
                caption_id: first.captionId || null,
                as_file: !!first.asFile,
                albums,
                file_cids: fileCids,
                client_ids: items.map((it) => it.clientId),
              },
              (reply) => {
                if (!(reply && reply.ok)) {
                  // Not resumable (conversation gone / left) — drop the durable queue + rebuilt cards.
                  window.__edenSendStore?.removeQueue(queueId)
                  items.forEach((it) =>
                    this.pending?.querySelector(`[data-client-id="${it.clientId}"]`)?.remove(),
                  )
                  return
                }
                const gid = reply.group_id
                const sent = new Set(reply.already_sent || [])
                const doneAlbums = new Set(reply.done_albums || [])
                const remaining = []
                for (const it of items) {
                  const done =
                    sent.has(it.clientId) || (it.kind === "media" && doneAlbums.has(it.albumCid))
                  if (done) {
                    // Delivered before the reload — its real row is already loaded; drop record + card.
                    this.forgetStored(it)
                    this.pending?.querySelector(`[data-client-id="${it.clientId}"]`)?.remove()
                  } else {
                    if (gid) {
                      const n = this.pending?.querySelector(`[data-client-id="${it.clientId}"]`)
                      if (n) n.dataset.groupId = gid
                    }
                    remaining.push(it)
                  }
                }
                // Fuse the rebuilt optimistic file rows into the merged bubble (as at Send).
                if (gid) this.reGroupOptimistic(gid)
                if (remaining.length) {
                  ;(this.seqQueues = this.seqQueues || []).push({ queueId, items: remaining })
                  this.pumpSeq()
                }
              },
            )
          },
          // Cancel-X on a still-sending file card: drop its queued item so it never sends; if it was
          // the in-flight one, abort the upload (seq_reset frees the slot) and pump the rest.
          cancelSeqItem(clientId) {
            const feeding = this.seqFeeding && this.seqFeeding.clientId === clientId
            let queueId = null
            for (const q of this.seqQueues || []) {
              const idx = q.items.findIndex((it) => it.clientId === clientId)
              if (idx >= 0) { queueId = q.queueId; this.forgetStored(q.items[idx]); q.items.splice(idx, 1) }
            }
            this.seqQueues = (this.seqQueues || []).filter((q) => q.items.length)
            if (feeding) {
              // In flight: seq_reset aborts it AND drops its server-side count.
              this.pushEvent("seq_reset", {})
              this.seqFeeding = null
              this.pumpSeq()
            } else if (queueId) {
              // Queued (never fed): the server still counts it — tell it to drop the count so the
              // queue can finalize (else sending_media stays stuck).
              this.pushEvent("seq_drop", { queue_id: queueId, kind: "file", album_cid: null })
            }
          },
          // Attach a photo's OWN progress ring + cancel-X (phase D) to a tile/thumb, keyed by its
          // client_id. Each photo fills its own arc; the X drops just that photo (the album sends
          // with the rest).
          addTileControls(el, cid) {
            if (!el || !cid) return
            el.dataset.itemCid = cid
            el.classList.add("ed-tile--sending")
            el.appendChild(this.buildRing("ed-media-sending__ring"))
            el.appendChild(this.buildCancel(() => this.cancelSeqPhoto(cid)))
          },
          // Cancel-X on ONE album photo: fade its tile out, drop it from the queue (the server
          // decrements the album's expected — it sends with the rest); abort the upload if this
          // photo is the in-flight one.
          cancelSeqPhoto(cid) {
            const tile = this.pending?.querySelector(`[data-item-cid="${cid}"]`)
            const feeding = this.seqFeeding && this.seqFeeding.clientId === cid
            let queueId = null
            let albumCid = null
            for (const q of this.seqQueues || []) {
              const idx = q.items.findIndex((it) => it.clientId === cid)
              if (idx >= 0) {
                queueId = q.queueId
                albumCid = q.items[idx].albumCid
                this.forgetStored(q.items[idx])
                q.items.splice(idx, 1)
              }
            }
            this.seqQueues = (this.seqQueues || []).filter((q) => q.items.length)
            this.fadeTile(tile)
            if (feeding) {
              this.pushEvent("seq_reset", {})
              this.seqFeeding = null
              this.pumpSeq()
            } else if (queueId) {
              this.pushEvent("seq_drop", { queue_id: queueId, kind: "media", album_cid: albumCid })
            }
          },
          // Smoothly remove one tile from the mosaic (the flex row reflows to fill the gap).
          fadeTile(tile) {
            if (!tile) return
            tile.classList.add("ed-tile--out")
            setTimeout(() => tile.remove(), 160)
          },
          // Stall watchdog for the CURRENT sequential item (one at a time, so no batch/sibling fail
          // like the concurrent armStall). If it goes 90s with no progress: fade a stalled album
          // photo (tile) / mark a stalled file failed, tell the server to abort + drop it, remove it
          // from the client queue, and pump the next — the batch keeps going. Re-armed by seq_progress.
          armSeqStall(node) {
            // A thread send (phase F trim) has no optimistic node — arm a hook-level watchdog so a
            // stalled item still frees the slot + pumps the next (there's no tile/card to fade). The
            // node path fades the tile / marks the card failed on the right element. onSeqDone clears
            // the hook-level timer so a finished item's watchdog can't fire spuriously.
            if (!node) {
              const feeding = this.seqFeeding
              if (this._seqStall) clearTimeout(this._seqStall)
              this._seqStall = setTimeout(() => {
                this._seqStall = null
                this.pushEvent("seq_reset", {})
                if (feeding) this.dropSeqFeedingFromQueue(feeding)
                this.seqFeeding = null
                this.pumpSeq()
              }, 90000)
              return
            }
            if (node._stall) clearTimeout(node._stall)
            node._stall = setTimeout(() => {
              if (!node.isConnected) return
              const feeding = this.seqFeeding
              if (node.dataset.itemCid) this.fadeTile(node)
              else this.markUploadFailed(node)
              this.pushEvent("seq_reset", {})
              if (feeding) this.dropSeqFeedingFromQueue(feeding)
              this.seqFeeding = null
              this.pumpSeq()
            }, 90000)
          },
          // Remove the in-flight item from the client queue on stall/abort — just that item (a file,
          // or one album photo; the album continues with the rest).
          dropSeqFeedingFromQueue(feeding) {
            for (const q of this.seqQueues || []) {
              const idx = q.items.findIndex((it) => it.clientId === feeding.clientId)
              if (idx >= 0) {
                this.forgetStored(q.items[idx])
                q.items.splice(idx, 1)
              }
            }
            this.seqQueues = (this.seqQueues || []).filter((q) => q.items.length)
          },
          // Stamp the send's server-minted group_id onto its optimistic file rows, then fuse them
          // into the merged bubble so the upload happens INSIDE the formed fixed-width bubble (not
          // separate cards that glue together at the end).
          stampGroup(fileCids, groupId) {
            ;(fileCids || []).forEach((cid) => {
              const row = this.pending?.querySelector(`[data-client-id="${cid}"]`)
              if (row) row.dataset.groupId = groupId
            })
            this.reGroupOptimistic(groupId)
          },
          // Optimistic mirror of the server's merged-bubble render (mark_group_pos): apply the
          // fixed-width + fused-seam classes to a group's optimistic rows still in #pending, so an
          // in-flight send already looks like one bubble. Re-run whenever the set changes (a twin
          // swaps out on completion, via the riser's ed:regroup event).
          reGroupOptimistic(groupId) {
            if (!groupId || !this.pending) return
            const rows = [...this.pending.querySelectorAll(`.ed-msg[data-group-id="${groupId}"]`)]
            const n = rows.length
            // If real rows of this group already landed in #messages, they've OPENED the merged
            // bubble (:first / :middle, kept off :last while in-flight) — so the optimistic tail just
            // CONTINUES it (all :middle, the very last :last). Only when no real row exists yet does
            // the optimistic set own the whole bubble (first…last).
            const stream = document.getElementById("messages")
            const hasReal = !!(stream && stream.querySelector(`.ed-msg[data-group-id="${groupId}"]`))
            rows.forEach((row, i) => {
              // forEach only runs for n ≥ 1. With real rows present the tail just continues them
              // (:mid, the very last :last); otherwise the optimistic set owns the bubble (first…last,
              // or nil for a lone row).
              const pos = hasReal
                ? i === n - 1 ? "last" : "mid"
                : n === 1 ? null : i === 0 ? "first" : i === n - 1 ? "last" : "mid"
              const bubble = row.querySelector(".ed-bubble")
              row.classList.toggle("ed-msg--grp-cont", pos === "mid" || pos === "last")
              if (!bubble) return
              bubble.classList.toggle("ed-bubble--grp", pos != null)
              bubble.classList.toggle("ed-bubble--grp-first", pos === "first")
              bubble.classList.toggle("ed-bubble--grp-mid", pos === "mid")
              bubble.classList.toggle("ed-bubble--grp-last", pos === "last")
              // Time+ticks show once, on the last/solo row — hide the meta on first/middle (mirrors
              // the server render's `meta on :last only`).
              const cap = bubble.querySelector(".ed-bubble__cap")
              if (cap) cap.style.display = pos === "first" || pos === "mid" ? "none" : ""
            })
          },
          // Feed the next queued batch (#119) into the now-free :attachment config. Only ever
          // called by updated() on the config-FREE edge, so the config is already clear (no
          // lingering entry to pile onto). feedInput stages the batch and the server re-opens
          // the compose overlay — the user captions + Sends normally, exactly like a first
          // batch. _dequeuing guards against a re-entrant call (belt-and-suspenders; the edge
          // trigger already won't re-fire).
          dequeueNext() {
            if (this._dequeuing) return
            if (this.el.dataset.sendingMedia === "true") return
            if (this.el.querySelector("[data-upload-preview]")) return
            if (!this.mediaQueue.length) return
            // Exclude the dedicated Resend input (#310 review P0): it's the FIRST file input in
            // #composer now, so a bare positional selector would feed the #119 queue into the
            // auto-upload retry config (silent loss + cross-retry leak) instead of :attachment.
            const input = this.el.querySelector('input[type="file"]:not([name="attachment_retry"]):not([name="attachment_seq"])')
            // No input to feed (composer gone) — leave the batch queued, don't lose it.
            if (!input) return
            this._dequeuing = true
            try {
              const batch = this.mediaQueue.shift()
              this.updateQueueHint()
              if (batch.length && input.isConnected) this.feedInput(input, batch)
            } finally {
              this._dequeuing = false
            }
          },
          // Foot-of-list pill (#119) showing how many batches wait behind the in-flight
          // send, so a pick made while uploading isn't invisible (it matters most on a slow
          // link, where the wait is real). Lives in #pending (phx-update="ignore", stable);
          // untagged, so a conversation switch's cleanup drops it along with the queue.
          updateQueueHint() {
            const n = this.mediaQueue.length
            if (!n) {
              this.queuePill?.remove()
              this.queuePill = null
              return
            }
            if (!this.queuePill || !this.queuePill.isConnected) {
              this.queuePill = document.createElement("div")
              this.queuePill.className = "ed-queued"
              this.queuePill.innerHTML =
                '<span class="hero-clock-micro size-3.5"></span><span></span>'
            }
            const label = this.el.dataset.queuedLabel || "In queue"
            this.queuePill.lastElementChild.textContent = label + ": " + n
            // Re-append so it stays at the foot, below any optimistic nodes.
            this.pending?.appendChild(this.queuePill)
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
          markFailed(clientId, body) {
            let node = this.pending.querySelector(`[data-client-id="${clientId}"]`)
            // Rooms/groups draw no optimistic node on the happy path (#130/#142), so a
            // rejected send has nothing to mark — materialize it now (faded), then flag
            // it failed. Media nacks drop their node (push_media_failed), so this only
            // fires for text nacks.
            if (!node && body != null) {
              this.addOptimistic(clientId, body)
              node = this.pending.querySelector(`[data-client-id="${clientId}"]`)
            }
            if (!node) return
            node.style.opacity = "1"
            node.classList.add("ed-msg-failed")
            if (body != null) node.dataset.body = body
            // Swap the status slot (clock, if any) for a tappable red ●! that opens a
            // resend/delete menu (#142). Bubble: in .ed-bubble__meta; flat row: a
            // trailing affordance on the row itself.
            const meta = node.querySelector(".ed-bubble__meta")
            const host = meta || node
            host.querySelectorAll(".ed-msg-failed__bang").forEach((b) => b.remove())
            if (meta) {
              // Drop the "sending" clock span (the inline-flex after <time>).
              meta.querySelectorAll(":scope > .inline-flex").forEach((s) => s.remove())
            }
            const bang = document.createElement("button")
            bang.type = "button"
            bang.className = "ed-msg-failed__bang"
            bang.setAttribute("aria-label", this.el.dataset.failed || "Not delivered")
            bang.innerHTML = '<span class="hero-exclamation-circle-micro size-3.5"></span>'
            bang.addEventListener("click", (e) => {
              e.preventDefault()
              e.stopPropagation()
              this.openFailMenu(node)
            })
            host.appendChild(bang)
          },
          failedNodes() {
            return [...this.pending.querySelectorAll(".ed-msg-failed")]
          },
          // Re-send one failed node (same client_id → idempotent): drop it, redraw the
          // optimistic node, re-queue, flush.
          resendNode(node) {
            const clientId = node.dataset.clientId
            const body = node.dataset.body || ""
            node.remove()
            if (!body) return
            this.addOptimistic(clientId, body)
            this.queue.push({ clientId, body, sent: false })
          },
          openFailMenu(node) {
            this.closeFailMenu()
            const d = this.el.dataset
            const failed = this.failedNodes()
            const menu = document.createElement("div")
            menu.className = "ed-menu ed-fail-menu"
            menu.setAttribute("role", "menu")
            const item = (label, onClick, danger) => {
              const b = document.createElement("button")
              b.type = "button"
              b.className = "ed-menu__item" + (danger ? " ed-menu__item--danger" : "")
              b.setAttribute("role", "menuitem")
              b.textContent = label
              b.addEventListener("click", () => { this.closeFailMenu(); onClick() })
              menu.appendChild(b)
            }
            item(d.resend || "Resend", () => { this.resendNode(node); this.flush() })
            // Batch: offer to re-send every failed message at once.
            if (failed.length > 1) {
              const label = (d.resendMany || "Resend {count} messages")
                .replace("{count}", failed.length)
              item(label, () => { failed.forEach((n) => this.resendNode(n)); this.flush() })
            }
            item(d.delete || "Delete", () => node.remove(), true)
            document.body.appendChild(menu)
            // Anchor to the ●!: the marker sits at the message's trailing (right) edge,
            // so right-align the menu under it and grow from that corner; flip above the
            // ! when there isn't room below. Clamped to the viewport.
            const r = (node.querySelector(".ed-msg-failed__bang") || node).getBoundingClientRect()
            const mw = menu.offsetWidth, mh = menu.offsetHeight
            const left = Math.max(8, Math.min(r.right - mw, window.innerWidth - mw - 8))
            const fitsBelow = r.bottom + 4 + mh <= window.innerHeight - 8
            const top = fitsBelow ? r.bottom + 4 : Math.max(8, r.top - mh - 4)
            menu.style.left = left + "px"
            menu.style.top = top + "px"
            menu.style.transformOrigin = fitsBelow ? "top right" : "bottom right"
            this.failMenu = menu
            this.onFailDoc = (e) => { if (!menu.contains(e.target)) this.closeFailMenu() }
            this.onFailKey = (e) => { if (e.key === "Escape") this.closeFailMenu() }
            // Land focus on the first action (keyboard a11y), like .ContextMenu.
            menu.querySelector("[role=menuitem]")?.focus({ preventScroll: true })
            setTimeout(() => {
              document.addEventListener("click", this.onFailDoc)
              document.addEventListener("keydown", this.onFailKey)
              document.addEventListener("scroll", this.onFailDoc, { capture: true, passive: true })
            }, 0)
          },
          closeFailMenu() {
            if (!this.failMenu) return
            this.failMenu.remove()
            this.failMenu = null
            document.removeEventListener("click", this.onFailDoc)
            document.removeEventListener("keydown", this.onFailKey)
            document.removeEventListener("scroll", this.onFailDoc, { capture: true })
          },
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ThreadSendQueue">
        // Failed-send (●!) for thread replies (#142 PR-2). Threads are flat and stream in
        // via {:thread_reply}, so — like rooms — there's NO happy-path optimistic node and
        // NO clock/✓/✓✓; only a "not delivered" ●! on failure. A focused, self-contained
        // hook (colocated hooks can't share .SendQueue's helpers): mint a client_id, send
        // over the socket, and on a nack / timeout / offline-grace materialize a faded
        // failed row in #thread-pending with the same Resend/Delete(/Resend N) menu. The
        // .ScrollBottom riser (data-pending-id="thread-pending") removes the failed node
        // when its real reply streams in (e.g. an offline send that lands on reconnect).
        export default {
          mounted() {
            this.threadRoot = this.el.dataset.threadRoot
            this.queue = []
            this.connected = true
            this.sendTimers = new Map()
            this.input = this.el.querySelector('input[name="reply[body]"]')
            // Edit (#164): the server pre-fills (start) / clears (cancel|save) the reply input
            // directly — a targeted event (NOT the main composer's set_composer_body) so the two
            // composers never cross-fill.
            this.handleEvent("set_thread_composer_body", ({ body }) => {
              if (!this.input) return
              this.input.value = body
              this.input.dispatchEvent(new Event("input", { bubbles: true }))
              if (body) {
                this.input.focus()
                try { this.input.setSelectionRange(body.length, body.length) } catch (_e) {}
              }
            })
            this.pending = document.getElementById("thread-pending")
            this.onOffline = () => { for (const i of this.queue) this.armWatchdog(i.clientId, i.body) }
            window.addEventListener("offline", this.onOffline)
            this.el.addEventListener("submit", (e) => this.onSubmit(e))
            // Capture picked File objects (phase F trim): the thread album/file send is fed one at a
            // time through the main composer's sequential feeder, which needs the real Files. Keyed
            // "name:size:lastModified" to match the tray items' data-key, so a per-item removal (the
            // ✕) and a multi-pick tray both resolve correctly at submit. Delegated + capture so it
            // survives the input's re-renders.
            this.pickedFiles = new Map()
            this.onPick = (e) => {
              const input = e.target
              if (!(input instanceof HTMLInputElement) || input.type !== "file") return
              for (const f of input.files || []) {
                this.pickedFiles.set(`${f.name}:${f.size}:${f.lastModified}`, f)
              }
            }
            // Both events, capture: file inputs fire `change`, but LiveView's own capture listener
            // consumes + clears the input during staging, so grab the Files on the `input` tick too
            // (mirrors the main composer's edenFiles capture).
            this.el.addEventListener("input", this.onPick, true)
            this.el.addEventListener("change", this.onPick, true)
          },
          disconnected() { this.connected = false },
          reconnected() {
            this.connected = true
            for (const i of this.queue) i.sent = false
            this.flush()
          },
          updated() {
            // A different thread opened in the same room (open_thread on another root):
            // the room id is unchanged, so key the reset on the thread ROOT — otherwise
            // thread A's failed ●! nodes linger in thread B's panel (#thread-pending is
            // phx-update="ignore", so the server never clears it).
            if (this.el.dataset.threadRoot !== this.threadRoot) {
              this.threadRoot = this.el.dataset.threadRoot
              this.queue = []
              this.pickedFiles.clear()
              this.sendTimers.forEach((t) => clearTimeout(t))
              this.sendTimers.clear()
              this.closeMenu()
              if (this.pending) this.pending.replaceChildren()
            }
          },
          destroyed() {
            window.removeEventListener("offline", this.onOffline)
            this.el.removeEventListener("input", this.onPick, true)
            this.el.removeEventListener("change", this.onPick, true)
            this.sendTimers.forEach((t) => clearTimeout(t))
            this.sendTimers.clear()
            this.closeMenu()
          },
          onSubmit(e) {
            // A quote-reply / edit / forward bar (.ed-reply-bar) rides the server path (it needs the
            // reply_to_id / edit target / forward drop) — leave it. A staged album/file tray WITHOUT
            // a bar routes through the main composer's sequential feeder (phase F trim): one item at
            // a time (no batch stall), each landing as a thread reply progressively.
            if (this.el.querySelector(".ed-reply-bar")) return
            const tray = this.el.querySelector(".ed-thread-tray")
            if (tray) {
              // Map the tray's staged entries (server truth, so a per-item ✕ is honoured) to the
              // Files we captured, IN ORDER. Only take over when we can fully serve it (feeder up +
              // every staged file captured); otherwise fall through to the server album path
              // (send_thread_album) so a send is never dropped.
              const keys = [...tray.querySelectorAll(".ed-thread-tray__item")].map((n) => n.dataset.key)
              const files = keys.map((k) => this.pickedFiles.get(k)).filter(Boolean)
              const owner = window.__edSendQueue
              const root = Number(this.threadRoot)
              // Only take over — and only THEN clear the input/captured Files — when we can fully
              // serve it: feeder up, a valid root, and every staged file captured. Otherwise fall
              // through to the server album path so a caption/files are never silently dropped.
              if (owner && Number.isInteger(root) && root > 0 && keys.length && files.length === keys.length) {
                e.preventDefault()
                e.stopPropagation()
                const caption = (this.input.value || "").trim()
                this.input.value = ""
                this.pickedFiles.clear()
                owner.enqueueThreadSeq({ files, caption, rootId: root })
              }
              // Tray present → never the plain-text path (whether we took over or deferred).
              return
            }
            e.preventDefault()
            e.stopPropagation()
            const body = (this.input.value || "").trim()
            if (!body) return
            this.input.value = ""
            const clientId = this.uuid()
            this.queue.push({ clientId, body, sent: false })
            this.flush()
          },
          uuid() {
            if (crypto.randomUUID) return crypto.randomUUID()
            const b = crypto.getRandomValues(new Uint8Array(16))
            b[6] = (b[6] & 0x0f) | 0x40
            b[8] = (b[8] & 0x3f) | 0x80
            const h = [...b].map((x) => x.toString(16).padStart(2, "0")).join("")
            return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`
          },
          flush() {
            for (const item of this.queue) {
              if (item.sent) continue
              this.armWatchdog(item.clientId, item.body)
              if (!this.connected) continue
              item.sent = true
              this.pushEvent("send_reply", { reply: { body: item.body, client_id: item.clientId } }, (reply) => {
                this.clearWatchdog(item.clientId)
                this.queue = this.queue.filter((q) => q.clientId !== item.clientId)
                if (reply && reply.nack) this.markFailed(item.clientId, item.body)
              })
            }
          },
          armWatchdog(clientId, body) {
            this.clearWatchdog(clientId)
            const ms = navigator.onLine ? 20000 : 3000
            const timer = setTimeout(() => {
              this.sendTimers.delete(clientId)
              if (this.queue.some((q) => q.clientId === clientId)) this.markFailed(clientId, body)
            }, ms)
            this.sendTimers.set(clientId, timer)
          },
          clearWatchdog(clientId) {
            const t = this.sendTimers.get(clientId)
            if (t) { clearTimeout(t); this.sendTimers.delete(clientId) }
          },
          markFailed(clientId, body) {
            if (!this.pending) return
            let node = this.pending.querySelector(`[data-client-id="${clientId}"]`)
            if (!node) {
              node = document.createElement("div")
              node.className = "ed-flat ed-msg-failed"
              node.dataset.clientId = clientId
              node.innerHTML =
                '<div class="ed-flat__gutter"></div>' +
                '<div class="ed-flat__main"><div class="break-words ed-flat__body"></div></div>'
              node.querySelector(".ed-flat__body").textContent = body
              this.pending.appendChild(node)
            }
            node.dataset.body = body
            node.querySelectorAll(".ed-msg-failed__bang").forEach((b) => b.remove())
            const bang = document.createElement("button")
            bang.type = "button"
            bang.className = "ed-msg-failed__bang"
            bang.setAttribute("aria-label", this.el.dataset.failed || "Not delivered")
            bang.innerHTML = '<span class="hero-exclamation-circle-micro size-3.5"></span>'
            bang.addEventListener("click", (e) => {
              e.preventDefault()
              e.stopPropagation()
              this.openMenu(node)
            })
            node.appendChild(bang)
          },
          failedNodes() {
            return [...this.pending.querySelectorAll(".ed-msg-failed")]
          },
          resendNode(node) {
            const clientId = node.dataset.clientId
            const body = node.dataset.body || ""
            node.remove()
            if (!body) return
            this.queue.push({ clientId, body, sent: false })
          },
          openMenu(node) {
            this.closeMenu()
            const d = this.el.dataset
            const failed = this.failedNodes()
            const menu = document.createElement("div")
            menu.className = "ed-menu ed-fail-menu"
            menu.setAttribute("role", "menu")
            const item = (label, onClick, danger) => {
              const b = document.createElement("button")
              b.type = "button"
              b.className = "ed-menu__item" + (danger ? " ed-menu__item--danger" : "")
              b.setAttribute("role", "menuitem")
              b.textContent = label
              b.addEventListener("click", () => { this.closeMenu(); onClick() })
              menu.appendChild(b)
            }
            item(d.resend || "Resend", () => { this.resendNode(node); this.flush() })
            if (failed.length > 1) {
              const label = (d.resendMany || "Resend {count} messages").replace("{count}", failed.length)
              item(label, () => { failed.forEach((n) => this.resendNode(n)); this.flush() })
            }
            item(d.delete || "Delete", () => node.remove(), true)
            document.body.appendChild(menu)
            const r = (node.querySelector(".ed-msg-failed__bang") || node).getBoundingClientRect()
            const mw = menu.offsetWidth, mh = menu.offsetHeight
            const left = Math.max(8, Math.min(r.right - mw, window.innerWidth - mw - 8))
            const fitsBelow = r.bottom + 4 + mh <= window.innerHeight - 8
            menu.style.left = left + "px"
            menu.style.top = (fitsBelow ? r.bottom + 4 : Math.max(8, r.top - mh - 4)) + "px"
            menu.style.transformOrigin = fitsBelow ? "top right" : "bottom right"
            this.failMenu = menu
            this.onMenuDoc = (e) => { if (!menu.contains(e.target)) this.closeMenu() }
            this.onMenuKey = (e) => { if (e.key === "Escape") this.closeMenu() }
            menu.querySelector("[role=menuitem]")?.focus({ preventScroll: true })
            setTimeout(() => {
              document.addEventListener("click", this.onMenuDoc)
              document.addEventListener("keydown", this.onMenuKey)
              document.addEventListener("scroll", this.onMenuDoc, { capture: true, passive: true })
            }, 0)
          },
          closeMenu() {
            if (!this.failMenu) return
            this.failMenu.remove()
            this.failMenu = null
            document.removeEventListener("click", this.onMenuDoc)
            document.removeEventListener("keydown", this.onMenuKey)
            document.removeEventListener("scroll", this.onMenuDoc, { capture: true })
          },
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".VideoPreview">
        // Play a staged clip locally before it uploads (#117). The File is only
        // reachable at selection (an upload entry never hands a hook its File), so
        // the SendQueue hook stashes URL.createObjectURL(file) on #composer in a
        // Map keyed "name:size:lastModified". We look ours up by those data-* attrs,
        // point the <video> at it, and revoke on teardown so a clip can't leak.
        export default {
          key() {
            return this.el.dataset.name + ":" + this.el.dataset.size + ":" + this.el.dataset.modified
          },
          mounted() {
            // Cache the store now: in destroyed() the node is already detached, so
            // closest("#composer") would return null.
            this.store = this.el.closest("#composer")?.edenVideoUrls
            const url = this.store && this.store.get(this.key())
            if (url) {
              this.el.src = url
              this.el.load()
              // Reflect the clip's real aspect once known (#117) so a single portrait
              // preview shows full-frame, not a centre-cropped square. No-op in the
              // album grid: there the square tile fixes width+height, which overrides
              // aspect-ratio.
              this.onMeta = () => {
                const w = this.el.videoWidth
                const h = this.el.videoHeight
                if (!w || !h) return
                if (this.el.closest(".ed-compose__grid--single")) {
                  // Lone clip: size the box to the decoded dimensions, then grow + fade it in
                  // (matches .ImgPreview) so the preview settles instead of snapping open when
                  // metadata lands.
                  const body = this.el.closest(".ed-compose__body")
                  const maxW = (body ? body.clientWidth : 320) - 28 // body padding (0.875rem*2)
                  const maxH = Math.round(window.innerHeight * 0.6)
                  const s = Math.min(maxW / w, maxH / h, 1)
                  this.el.style.width = Math.round(w * s) + "px"
                  this.el.style.height = Math.round(h * s) + "px"
                  requestAnimationFrame(() => this.el.classList.add("is-ready"))
                } else {
                  // Album grid: the square tile fixes width+height, so this is a no-op there.
                  this.el.style.aspectRatio = w + " / " + h
                }
              }
              this.el.addEventListener("loadedmetadata", this.onMeta)
            } else {
              // No local frame (rare) — hide the empty player so the film icon shows.
              this.el.style.display = "none"
            }
          },
          destroyed() {
            if (this.onMeta) this.el.removeEventListener("loadedmetadata", this.onMeta)
            const url = this.store && this.store.get(this.key())
            if (url) {
              URL.revokeObjectURL(url)
              this.store.delete(this.key())
            }
          },
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ImgPreview">
        // Crash-safe staged-photo preview — replaces LiveView's <.live_img_preview>, whose
        // mounted() calls URL.createObjectURL(entry.file) and threw "Argument 1 could not be
        // converted to Blob" when the entry's File was already gone mid-send (consumed). That
        // uncaught throw aborted the DOM patch and left the compose modal blank — the "empty
        // lightbox". Same model as .VideoPreview: read the object URL the SendQueue stashed at
        // selection (keyed name:size:lastModified); no URL → leave blank, never throw.
        export default {
          key() {
            return this.el.dataset.name + ":" + this.el.dataset.size + ":" + this.el.dataset.modified
          },
          mounted() {
            this.store = this.el.closest("#composer")?.edenVideoUrls
            const url = this.store && this.store.get(this.key())
            if (!url) return
            // A grid tile is an already-reserved square — just show it. A LONE photo's box
            // has no reserved size, so decode the file off-DOM FIRST to learn its dimensions,
            // size the box, then grow + fade it in — the preview settles smoothly instead of
            // snapping the modal open as the blob decodes (anti layout-shift).
            if (!this.el.closest(".ed-compose__grid--single")) {
              this.el.src = url
              return
            }
            const probe = new Image()
            probe.onload = () => {
              const w = probe.naturalWidth
              const h = probe.naturalHeight
              if (w && h) {
                const body = this.el.closest(".ed-compose__body")
                const maxW = (body ? body.clientWidth : 320) - 28 // body padding (0.875rem*2)
                const maxH = Math.round(window.innerHeight * 0.6)
                const s = Math.min(maxW / w, maxH / h, 1)
                this.el.style.width = Math.round(w * s) + "px"
                this.el.style.height = Math.round(h * s) + "px"
              }
              this.el.src = url
              requestAnimationFrame(() => this.el.classList.add("is-ready"))
            }
            probe.onerror = () => {
              this.el.style.width = "auto"
              this.el.style.height = "auto"
              this.el.src = url
              this.el.classList.add("is-ready")
            }
            probe.src = url
          },
          destroyed() {
            const url = this.store && this.store.get(this.key())
            if (url) {
              URL.revokeObjectURL(url)
              this.store.delete(this.key())
            }
          },
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".StreamVideo">
        // Zero-flash stream video (#130). A just-sent clip's FIRST load can transiently
        // error (the blob was only just stored; the metadata/Range fetch right after the
        // optimistic→real swap races) and then play fine — Firefox would paint its
        // "unsupported format" icon for a beat before recovering. We mask the player
        // with a poster COVER (its own frame, mirrored from the <video>'s poster — the
        // client snapshot via the riser, or the server thumbnail) and reveal the real
        // player only once it can actually show a frame (loadeddata/canplay). So no
        // load/error state is ever visible. A transient error also retries load() once,
        // which then reaches canplay and fades the cover.
        export default {
          mounted() {
            // The cover lives in the HEEx (phx-update="ignore" so morphdom leaves it
            // alone); we just fill its src + fade it out.
            this.cover = this.el.closest(".ed-video-box")?.querySelector(".ed-video-cover")
            if (!this.cover) return
            // Mirror the <video>'s poster (the riser's client snapshot, or the server
            // thumbnail) — it can arrive after mount, so observe it.
            this.syncCover = () => {
              const p = this.el.getAttribute("poster")
              if (p && this.cover.getAttribute("src") !== p) this.cover.setAttribute("src", p)
            }
            this.syncCover()
            this.posterObs = new MutationObserver(this.syncCover)
            this.posterObs.observe(this.el, { attributes: true, attributeFilter: ["poster"] })

            this.reveal = () => this.cover.classList.add("ed-video-cover--gone")
            this.el.addEventListener("loadeddata", this.reveal)
            this.el.addEventListener("canplay", this.reveal)
            // Already decodable (e.g. cached) — reveal immediately.
            if (this.el.readyState >= 2) this.reveal()

            this.onError = () => {
              if (this._retried) return
              this._retried = true
              this.el.load()
            }
            this.el.addEventListener("error", this.onError)
          },
          destroyed() {
            this.posterObs && this.posterObs.disconnect()
            if (this.reveal) {
              this.el.removeEventListener("loadeddata", this.reveal)
              this.el.removeEventListener("canplay", this.reveal)
            }
            this.onError && this.el.removeEventListener("error", this.onError)
          },
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".Lightbox">
        // In-app image viewer: click a photo to open it full-screen in a single
        // shared overlay (close on backdrop click or Esc). When the tile belongs
        // to an album (data-gallery), the overlay pages through that album's
        // photos with on-screen arrows and ←/→. Cmd/Ctrl/Shift/middle click fall
        // through to the normal "open original in a new tab".
        // #106: inside a message, a double-click reacts — so a photo there must give the
        // second click a chance to arrive before opening. We defer the open by DBL_MS and
        // cancel it when a 2nd click lands (the .ContextMenu row handler then reacts). Photos
        // OUTSIDE a message row (the profile gallery) keep opening instantly — nothing reacts
        // there, so there's nothing to disambiguate.
        const DBL_MS = 250
        export default {
          mounted() {
            const inMsg = !!this.el.closest(".ed-msg, .ed-flat")
            this.el.addEventListener("click", (e) => {
              if (e.metaKey || e.ctrlKey || e.shiftKey || e.button === 1) return
              e.preventDefault()
              if (!inMsg) return this.openLightbox()
              if (e.detail > 1) return clearTimeout(this._openT) // part of a dbl-click → react
              clearTimeout(this._openT)
              this._openT = setTimeout(() => this.openLightbox(), DBL_MS)
            })
          },
          destroyed() {
            clearTimeout(this._openT)
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

      <script :type={Phoenix.LiveView.ColocatedHook} name=".VideoExpand">
        // Telegram-style video: the in-stream clip is a poster + centered play button with
        // NO inline controls. Clicking opens the clip full-screen (wide) in a shared overlay
        // with real controls, and plays immediately — the click is a user gesture, so
        // autoplay with sound is allowed. Cmd/Ctrl/Shift/middle click fall through to the
        // <a>'s "open original in a new tab" (the box has no href, so they just no-op there).
        export default {
          mounted() {
            this._open = (e) => {
              if (e.metaKey || e.ctrlKey || e.shiftKey || e.button === 1) return
              e.preventDefault()
              this.open()
            }
            this.el.addEventListener("click", this._open)
            this._key = (e) => {
              if (e.key === "Enter" || e.key === " ") {
                e.preventDefault()
                this.open()
              }
            }
            this.el.addEventListener("keydown", this._key)
          },
          open() {
            const src = this.el.dataset.src
            if (!src) return
            const type = this.el.dataset.type || ""
            const box = this.modal()
            const video = box.querySelector(".ed-video-modal__player")
            video.innerHTML = `<source src="${src}"${type ? ` type="${type}"` : ""}>`
            video.load()
            box.classList.add("ed-video-modal--open")
            document.body.style.overflow = "hidden"
            document.addEventListener("keydown", box.__onKey)
            // The opening tap is a user gesture, so play-with-sound is permitted.
            video.play && video.play().catch(() => {})
          },
          modal() {
            let box = document.getElementById("ed-video-modal")
            if (box) return box

            box = document.createElement("div")
            box.id = "ed-video-modal"
            box.className = "ed-video-modal"
            const lbl = document.getElementById("message-scroll")?.dataset || {}
            const xmark =
              "M6.28 5.22a.75.75 0 0 0-1.06 1.06L8.94 10l-3.72 3.72a.75.75 0 1 0 1.06 1.06L10 11.06l3.72 3.72a.75.75 0 1 0 1.06-1.06L11.06 10l3.72-3.72a.75.75 0 0 0-1.06-1.06L10 8.94 6.28 5.22Z"
            box.innerHTML =
              `<button class="ed-video-modal__close" aria-label="${lbl.lbClose || "Close"}"><svg viewBox="0 0 20 20" fill="currentColor" aria-hidden="true"><path fill-rule="evenodd" d="${xmark}" clip-rule="evenodd"/></svg></button>` +
              '<video class="ed-video-modal__player" controls playsinline></video>'

            const close = () => {
              box.classList.remove("ed-video-modal--open")
              document.body.style.overflow = ""
              document.removeEventListener("keydown", box.__onKey)
              const v = box.querySelector(".ed-video-modal__player")
              // Stop playback + release the source so the clip can't keep playing audio
              // behind the closed overlay.
              v.pause()
              v.innerHTML = ""
              v.removeAttribute("src")
              v.load()
            }
            box.__onKey = (e) => {
              if (e.key === "Escape") close()
            }
            box.addEventListener("click", (e) => {
              if (e.target.closest(".ed-video-modal__close")) return close()
              // Click on the scrim (anything but the player) closes.
              if (!e.target.closest(".ed-video-modal__player")) close()
            })
            document.body.appendChild(box)
            return box
          },
          destroyed() {
            this.el.removeEventListener("click", this._open)
            this.el.removeEventListener("keydown", this._key)
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
              // A paste while a send is uploading is fine now (#119): it sets the input +
              // dispatches `input`, which the SendQueue hook's pick interceptor catches and
              // routes into the upload queue instead of merging into the in-flight config. Exclude
              // the dedicated Resend input (#310 review P0) — it's the first file input in the
              // composer form, and a paste must reach :attachment (or the thread's), not the retry.
              const input = this.el
                .closest("form")
                ?.querySelector('input[type="file"]:not([name="attachment_retry"]):not([name="attachment_seq"])')
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

      <script :type={Phoenix.LiveView.ColocatedHook} name=".DropZone">
        // Drag-and-drop file upload (#207): drop files from Finder/Explorer anywhere in the
        // chat (or thread) pane → staged into the composer. Mirrors .PasteUpload — it sets the
        // pane's own file input + dispatches `input`, which the SendQueue pick-interceptor
        // catches (queue #119 / cap / preview reused, no new server path). ONLY reacts to OS
        // FILE drags (dataTransfer has "Files"), so message swipe-reply and the room-list
        // sortable (element drags) are untouched. stopPropagation makes the innermost zone win,
        // so the thread pane and the main pane never both fire.
        export default {
          input() {
            // The pane's own file input (main → :attachment, thread → :thread_attachment); the
            // dedicated Resend input is excluded (#310 review P0) so a drop never lands in the
            // auto-upload retry config. Absent only during the brief inert window mid-send (#207
            // P3) → the drop no-ops then. Drag-drop is a mouse-only enhancement; picker + paste
            // stay the accessible paths.
            return this.el.querySelector('input[type="file"]:not([name="attachment_retry"]):not([name="attachment_seq"])')
          },
          hasFiles(e) {
            return e.dataTransfer && Array.from(e.dataTransfer.types).includes("Files")
          },
          show(on) {
            this.el.classList.toggle("ed-dropzone--over", on)
          },
          mounted() {
            // The overlay is SERVER-rendered in the template (#207 P1): appending it from JS got
            // wiped by morphdom on the next re-render, so the hook only toggles --over.
            this.depth = 0
            this.reset = () => {
              this.depth = 0
              this.show(false)
            }
            this.onEnter = (e) => {
              if (!this.hasFiles(e) || !this.input()) return
              e.preventDefault()
              e.stopPropagation()
              this.depth++
              this.show(true)
            }
            this.onOver = (e) => {
              if (!this.hasFiles(e) || !this.input()) return
              e.preventDefault() // required to allow the drop
              e.stopPropagation()
              e.dataTransfer.dropEffect = "copy"
            }
            this.onLeave = (e) => {
              if (!this.hasFiles(e)) return
              this.depth = Math.max(0, this.depth - 1)
              if (this.depth === 0) this.show(false)
            }
            this.onDrop = (e) => {
              if (!this.hasFiles(e) || !this.input()) return
              e.preventDefault()
              e.stopPropagation()
              this.reset()
              const files = Array.from(e.dataTransfer.files)
              if (!files.length) return
              const input = this.input()
              const dt = new DataTransfer()
              files.forEach((f) => dt.items.add(f))
              input.files = dt.files
              input.dispatchEvent(new Event("input", { bubbles: true }))
            }
            this.el.addEventListener("dragenter", this.onEnter)
            this.el.addEventListener("dragover", this.onOver)
            this.el.addEventListener("dragleave", this.onLeave)
            this.el.addEventListener("drop", this.onDrop)
            // P2: a drag that ends ANYWHERE (dropped outside a zone, or cancelled) must clear a
            // stuck overlay — those don't always fire dragleave on us.
            window.addEventListener("drop", this.reset)
            window.addEventListener("dragend", this.reset)
          },
          destroyed() {
            this.el.removeEventListener("dragenter", this.onEnter)
            this.el.removeEventListener("dragover", this.onOver)
            this.el.removeEventListener("dragleave", this.onLeave)
            this.el.removeEventListener("drop", this.onDrop)
            window.removeEventListener("drop", this.reset)
            window.removeEventListener("dragend", this.reset)
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
  attr :status, :string, default: nil, values: [nil, "online", "away", "dnd"]
  attr :size, :atom, default: nil, values: [nil, :sm, :lg]
  # When set (a user id), the dot is "managed": always rendered (hidden when
  # offline) and tagged with `data-presence-uid` so the .RoomPresence hook can
  # live-update it inside the streamed message list, where a server re-render
  # never reaches existing rows (#102).
  attr :dot_uid, :any, default: nil
  # Set false where a visible status label already sits beside the avatar (the
  # profile popover) so the screen-reader status isn't announced twice (#102).
  attr :dot_label, :boolean, default: true

  # Circular avatar: shows the user's image when present, initials otherwise. A
  # presence dot is shown when `status` is set, colored by it (#102).
  defp avatar(assigns) do
    ~H"""
    <span class={["ed-avatar", @size == :sm && "ed-avatar--sm", @size == :lg && "ed-avatar--lg"]}>
      <img :if={@src} src={@src} alt="" />
      <span :if={!@src}>{initials(@name)}</span>
      <span
        :if={@status || @dot_uid}
        class={[
          "ed-avatar__dot",
          @status == "away" && "ed-avatar__dot--away",
          @status == "dnd" && "ed-avatar__dot--dnd",
          @dot_uid && !@status && "ed-avatar__dot--hidden"
        ]}
        data-presence-uid={@dot_uid}
      >
        <%!-- SR-only status only on non-managed dots (sidebar / member lists, which
              carry no visible status text and re-render server-side, so the text
              stays accurate). Managed room dots update live via JS that can't
              localize, so their status reaches AT via the profile popover (#102). --%>
        <span :if={@status && !@dot_uid && @dot_label} class="sr-only">{status_label(@status)}</span>
      </span>
    </span>
    """
  end

  attr :id, :string, required: true
  attr :conversation, :map, required: true
  attr :user, :map, required: true
  attr :statuses, :any, required: true
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
          src={conversation_avatar_src(@conversation, @user)}
          status={peer_status(@conversation, @user, @statuses)}
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
  attr :statuses, :any, required: true

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
            src={conversation_avatar_src(conversation, @user)}
            status={peer_status(conversation, @user, @statuses)}
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
            src={conversation_avatar_src(message.conversation, @user)}
            status={peer_status(message.conversation, @user, @statuses)}
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
          <span :if={@room.favorite} class="ed-convo__muted ed-convo__fav" title={gettext("Favorite")}>
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

  attr :edit_media, :map, required: true
  attr :upload, :any, required: true

  # Edit-media modal (#164 PR-2): replace a media message's album (keep some existing photos,
  # add new ones) + its caption. The kept photos are toggled off in place; new photos ride the
  # :edit_media upload. Save hands kept ids + new sources to edit_message_media. Matches the
  # app's other modals (scrim + centered dialog + FocusTrap + Escape).
  defp edit_media_modal(assigns) do
    assigns = assign(assigns, :kept, kept_atts(assigns.edit_media))

    ~H"""
    <div class="fixed inset-0 z-30" id="edit-media">
      <button
        class="absolute inset-0 w-full h-full"
        style="background: var(--ed-scrim);"
        phx-click="close_edit_media"
        aria-label={gettext("Close")}
        tabindex="-1"
      >
      </button>
      <div class="absolute inset-0 grid place-items-center p-4 pointer-events-none">
        <form
          class="w-full max-w-md rounded-[var(--ed-radius-lg)] border p-5 space-y-4 pointer-events-auto"
          style="background: var(--ed-surface); border-color: var(--ed-border);"
          phx-window-keydown="close_edit_media"
          phx-key="Escape"
          role="dialog"
          aria-modal="true"
          aria-label={gettext("Edit media")}
          id="dlg-edit-media"
          phx-hook=".FocusTrap"
          tabindex="-1"
          phx-submit="save_edit_media"
          phx-change="validate_edit_media"
        >
          <div class="flex items-center justify-between">
            <h2 style="font-weight:600;">{gettext("Edit media")}</h2>
            <button
              type="button"
              class="ed-btn--icon"
              phx-click="close_edit_media"
              aria-label={gettext("Close")}
            >
              <.icon name="hero-x-mark-mini" class="size-5" />
            </button>
          </div>

          <%!-- The album: kept existing photos + newly-staged photos, each removable. --%>
          <div class="ed-editmedia__grid">
            <div :for={{att, i} <- Enum.with_index(@kept, 1)} class="ed-editmedia__tile">
              <img
                :if={att.kind == "image"}
                src={thumb_src(att)}
                class="ed-editmedia__img"
                alt={gettext("Photo %{n}", n: i)}
              />
              <span :if={att.kind != "image"} class="ed-editmedia__ph" aria-hidden="true">
                <.icon name={kind_icon(att.kind)} class="size-7" />
              </span>
              <button
                type="button"
                class="ed-editmedia__x"
                phx-click="edit_media_remove"
                phx-value-att={att.id}
                aria-label={gettext("Remove photo %{n}", n: i)}
              >
                <.icon name="hero-x-mark-micro" class="size-3.5" />
              </button>
            </div>

            <div :for={entry <- @upload.entries} class="ed-editmedia__tile">
              <.live_img_preview
                :if={image_entry?(entry)}
                entry={entry}
                class="ed-editmedia__img"
              />
              <span :if={not image_entry?(entry)} class="ed-editmedia__ph" aria-hidden="true">
                <.icon name="hero-film" class="size-7" />
              </span>
              <button
                type="button"
                class="ed-editmedia__x"
                phx-click="edit_media_cancel_upload"
                phx-value-ref={entry.ref}
                aria-label={gettext("Remove %{name}", name: entry.client_name)}
              >
                <.icon name="hero-x-mark-micro" class="size-3.5" />
              </button>
            </div>

            <label class="ed-editmedia__add" aria-label={gettext("Add photos")}>
              <.icon name="hero-plus" class="size-6" />
              <.live_file_input upload={@upload} class="sr-only" />
            </label>
          </div>

          <p :for={err <- upload_errors(@upload)} class="ed-attach-err">
            {upload_error_text(err)}
          </p>
          <%= for entry <- @upload.entries, err <- upload_errors(@upload, entry) do %>
            <p class="ed-attach-err">{entry.client_name}: {upload_error_text(err)}</p>
          <% end %>

          <input
            type="text"
            name="message[body]"
            value={@edit_media.caption}
            maxlength={Eden.Chat.Message.max_body()}
            class="ed-input w-full"
            placeholder={gettext("Add a caption…")}
            aria-label={gettext("Caption")}
            autocomplete="off"
          />

          <div class="flex items-center justify-end gap-2 pt-1">
            <%!-- Why Save is disabled: an album can't be emptied (delete the message instead). --%>
            <p
              :if={@kept == [] and @upload.entries == []}
              class="mr-auto"
              style="font-size:0.8125rem; color: var(--ed-muted);"
            >
              {gettext("Keep or add at least one photo.")}
            </p>
            <button type="button" class="ed-btn ed-btn--ghost" phx-click="close_edit_media">
              {gettext("Cancel")}
            </button>
            <button
              type="submit"
              class="ed-btn ed-btn--primary"
              disabled={@kept == [] and @upload.entries == []}
              phx-disable-with={gettext("Saving…")}
            >
              {gettext("Save")}
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  defp kept_atts(%{message: %{attachments: atts}, kept: kept}),
    do: Enum.filter(atts, &MapSet.member?(kept, &1.id))

  defp kind_icon("video"), do: "hero-film"
  defp kind_icon("audio"), do: "hero-musical-note"
  defp kind_icon(_), do: "hero-document"

  attr :members, :list, required: true
  attr :channel, :map, required: true
  attr :me, :map, required: true
  attr :statuses, :any, required: true

  # Channel members: roles, online dots, and the owner/admin action matrix
  # (the context re-checks every action).
  defp channel_members_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-30">
      <button
        class="absolute inset-0 w-full h-full"
        style="background: var(--ed-scrim);"
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
          aria-label={gettext("Members")}
          id="dlg-channel-members"
          phx-hook=".FocusTrap"
          tabindex="-1"
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
              class="flex items-center gap-3 p-2 rounded-[var(--ed-radius)] transition-colors hover:bg-[var(--ed-surface-2)]"
            >
              <button
                type="button"
                class="flex items-center gap-3 flex-1 min-w-0 text-left"
                data-profile-trigger
                phx-click="show_profile"
                phx-value-id={user.id}
                aria-label={gettext("View profile")}
              >
                <.avatar
                  name={user.display_name}
                  src={avatar_src(user)}
                  status={status_of(user.id, @statuses)}
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

  # The scoped user's role within a group (for the #136 panel's action matrix); defaults
  # to "member" so a missing/odd membership never grants actions.
  defp my_group_role(%{memberships: ms}, user) when is_list(ms),
    do:
      Enum.find_value(ms, "member", fn m ->
        is_nil(m.left_at) && m.user_id == user.id && m.role
      end)

  defp my_group_role(_conversation, _user), do: "member"

  # Centered group system-notice text (#165), from the message's meta.
  defp system_notice(%{"action" => "member_added", "name" => name}),
    do: gettext("%{name} was added to the group", name: name)

  defp system_notice(%{"action" => "member_removed", "name" => name}),
    do: gettext("%{name} was removed from the group", name: name)

  defp system_notice(_meta), do: ""

  attr :m, :map, required: true
  attr :me, :any, required: true
  attr :statuses, :map, default: %{}

  # The clickable profile area of a group member row (#165): avatar + name (+ a role chip
  # for owner/admin) + @handle. Shared by the plain row and the action-menu row.
  defp member_main(assigns) do
    ~H"""
    <button
      type="button"
      class="ed-member-row__main"
      data-profile-trigger
      phx-click="show_profile"
      phx-value-id={@m.user.id}
      aria-label={gettext("View profile")}
    >
      <.avatar
        name={@m.user.display_name}
        src={avatar_src(@m.user)}
        status={status_of(@m.user.id, @statuses)}
        size={:sm}
      />
      <span class="flex-1 min-w-0">
        <span class="ed-member-row__name">
          <span class="ed-member-row__nametext">
            {@m.user.display_name}{if @m.user.id == @me, do: " " <> gettext("(you)")}
          </span>
          <span :if={@m.role != "member"} class="ed-role-chip">{role_label(@m.role)}</span>
        </span>
        <span class="ed-member-row__handle">@{@m.user.username}</span>
      </span>
    </button>
    """
  end

  attr :room, :map, required: true
  attr :addable, :list, required: true
  attr :selected, :any, required: true
  attr :invite_url, :any, required: true
  attr :statuses, :any, required: true

  # Add members to a ROOM (#42): a platform-wide picker (non-channel users get
  # general + the room per the #41 matrix); private rooms also offer a
  # one-shot invite link.
  defp room_add_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-30">
      <button
        class="absolute inset-0 w-full h-full"
        style="background: var(--ed-scrim);"
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
          aria-label={gettext("Add to %{room}", room: @room.name)}
          id="dlg-room-add"
          phx-hook=".FocusTrap"
          tabindex="-1"
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
              class="flex w-full items-center gap-3 p-2 rounded-[var(--ed-radius)] text-left transition-colors hover:bg-[var(--ed-surface-2)]"
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
                status={status_of(user.id, @statuses)}
                size={:sm}
              />
              <span class="flex-1 min-w-0">
                <span class="block truncate" style="font-weight:550; font-size:0.875rem;">
                  {user.display_name}
                </span>
                <span class="block truncate" style="color: var(--ed-muted); font-size:0.75rem;">
                  @{user.username}
                </span>
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
  attr :statuses, :any, required: true

  defp add_members_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-30">
      <button
        class="absolute inset-0 w-full h-full"
        style="background: var(--ed-scrim);"
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
          aria-label={gettext("Add members")}
          id="dlg-add-members"
          phx-hook=".FocusTrap"
          tabindex="-1"
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
              class="flex w-full items-center gap-3 p-2 rounded-[var(--ed-radius)] text-left transition-colors hover:bg-[var(--ed-surface-2)]"
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
                status={status_of(user.id, @statuses)}
                size={:sm}
              />
              <span class="flex-1 min-w-0">
                <span class="block truncate" style="font-weight:550; font-size:0.875rem;">
                  {user.display_name}
                </span>
                <span class="block truncate" style="color: var(--ed-muted); font-size:0.75rem;">
                  @{user.username}
                </span>
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
        style="background: var(--ed-scrim);"
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
          aria-label={gettext("Invite links")}
          id="dlg-invites"
          phx-hook=".FocusTrap"
          tabindex="-1"
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
        style="background: var(--ed-scrim);"
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
          aria-label={@title}
          id="dlg-room-form"
          phx-hook=".FocusTrap"
          tabindex="-1"
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

  attr :id, :any, required: true
  attr :preview, :string, default: nil

  # Multi-select click-catcher (Telegram-style): a full-row overlay that toggles this message's
  # selection — suppressing the normal click (lightbox, reactions, profile) — with a leading
  # checkbox. Rendered ALWAYS but hidden (`display:none`) until the #messages container carries
  # `.selecting` (server-driven), which flips it to `display:block`; the row's `--selected` wash
  # + the check glyph + the button's aria-pressed are reflected onto the row by the .SelectSync
  # hook, because phx-update="stream" rows don't re-render on a plain @selection change.
  defp select_overlay(assigns) do
    ~H"""
    <button
      type="button"
      class="ed-select-hit"
      phx-click="toggle_select"
      phx-value-id={@id}
      data-select-id={@id}
      aria-pressed="false"
      aria-label={
        (@preview && gettext("Select: %{preview}", preview: @preview)) ||
          gettext("Select message")
      }
    >
      <span class="ed-select-check" aria-hidden="true">
        <.icon name="hero-check-micro" class="size-3" />
      </span>
    </button>
    """
  end

  # A short body preview for the select overlay's accessible label (media/empty → generic).
  defp select_preview(%{body: body}) when is_binary(body) and body != "",
    do: String.slice(body, 0, 40)

  defp select_preview(_), do: nil

  attr :selection, :any, required: true
  attr :confirming, :boolean, default: false
  attr :container, :string, default: "#messages"
  # compact = always icon-only (the thread panel is a narrow column even on desktop, where a
  # viewport-based `sm:` label reveal would overflow it). The main composer bar stays responsive.
  attr :compact, :boolean, default: false

  # The bottom action bar shown in place of the composer while selecting (Telegram-style):
  # a count + the actions on the selected messages (forward / copy / delete).
  defp selection_bar(assigns) do
    assigns = assign(assigns, :count, MapSet.size(assigns.selection))

    ~H"""
    <div
      class="ed-selbar"
      id="selbar"
      phx-hook=".SelectSync"
      data-container={@container}
      data-selected={Jason.encode!(MapSet.to_list(@selection))}
      phx-window-keydown={not @confirming && "exit_select"}
      phx-key="Escape"
      role="toolbar"
      aria-label={gettext("Selection")}
    >
      <%!-- Reflect the server's selected set onto the stream rows: phx-update="stream" rows
            don't re-render on a plain @selection change, so this hook toggles the row wash +
            check + aria-pressed to match data-selected on every change, and clears them when it
            unmounts. It also handles shift-click range selection (capture phase) while it lives
            (= only while selecting). --%>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".SelectSync">
        export default {
          mounted() {
            // The stream container this bar drives (#messages OR #thread-replies).
            this.c = this.el.dataset.container || "#messages"
            this.anchor = null
            // Shift-click a row → select the whole range from the last-clicked row to this one.
            // Capture phase so we can pre-empt the overlay's normal toggle for a shift-click.
            this.onClick = (e) => {
              const hit = e.target.closest(this.c + " .ed-select-hit")
              if (!hit) return
              const id = hit.dataset.selectId
              if (e.shiftKey && this.anchor && this.anchor !== id) {
                e.preventDefault()
                e.stopImmediatePropagation()
                this.pushEvent("select_range", { ids: this.range(this.anchor, id) })
              }
              this.anchor = id
            }
            document.addEventListener("click", this.onClick, true)
            this.sync()
          },
          updated() { this.sync() },
          destroyed() {
            document.removeEventListener("click", this.onClick, true)
            this.clear()
          },
          range(a, b) {
            const hits = [...document.querySelectorAll(this.c + " .ed-select-hit")]
            const ids = hits.map((h) => h.dataset.selectId)
            let i = ids.indexOf(a), j = ids.indexOf(b)
            if (i < 0 || j < 0) return [b]
            if (i > j) [i, j] = [j, i]
            return ids.slice(i, j + 1)
          },
          sync() {
            let ids = []
            try { ids = JSON.parse(this.el.dataset.selected || "[]") } catch (_e) {}
            // Seed the shift-range anchor from the message that entered select mode.
            if (!this.anchor && ids.length) this.anchor = String(ids[ids.length - 1])
            const set = new Set(ids.map(String))
            const mark = (sel, cls) =>
              document.querySelectorAll(this.c + " " + sel).forEach((r) => {
                const hit = r.querySelector(".ed-select-hit")
                const on = !!hit && set.has(String(hit.dataset.selectId))
                r.classList.toggle(cls, on)
                if (hit) hit.setAttribute("aria-pressed", on ? "true" : "false")
              })
            mark(".ed-msg", "ed-msg--selected")
            mark(".ed-flat", "ed-flat--selected")
          },
          clear() {
            document.querySelectorAll(this.c + " .ed-select-hit[aria-pressed=true]")
              .forEach((h) => h.setAttribute("aria-pressed", "false"))
            document
              .querySelectorAll(this.c + " .ed-msg--selected, " + this.c + " .ed-flat--selected")
              .forEach((r) => r.classList.remove("ed-msg--selected", "ed-flat--selected"))
          },
        }
      </script>
      <button
        type="button"
        class="ed-btn--icon shrink-0"
        phx-click="exit_select"
        aria-label={gettext("Cancel selection")}
      >
        <.icon name="hero-x-mark-mini" class="size-5" />
      </button>
      <span class="ed-selbar__count" aria-live="polite">
        {ngettext("%{count} selected", "%{count} selected", @count)}
      </span>
      <button
        type="button"
        class="ed-btn ed-btn--ghost ed-btn--sm shrink-0"
        phx-click="forward_selection"
        disabled={@count == 0}
      >
        <.icon name="hero-arrow-uturn-right-micro" class="size-4" />
        <span class={["hidden", not @compact && "sm:inline"]}>{gettext("Forward")}</span>
      </button>
      <%!-- Copy assembles the selected rows' text CLIENT-SIDE within the click gesture
            (Firefox blocks navigator.clipboard.writeText after a server round-trip), then
            pings the server to flash + exit. Disabled with nothing selected. --%>
      <button
        type="button"
        class="ed-btn ed-btn--ghost ed-btn--sm shrink-0"
        phx-hook=".CopySelection"
        id="selbar-copy"
        disabled={@count == 0}
      >
        <.icon name="hero-clipboard-document-micro" class="size-4" />
        <span class={["hidden", not @compact && "sm:inline"]}>{gettext("Copy")}</span>
      </button>
      <button
        type="button"
        class="ed-btn ed-btn--ghost ed-btn--sm ed-selbar__danger shrink-0"
        phx-click="delete_prompt"
        disabled={@count == 0}
      >
        <.icon name="hero-trash-micro" class="size-4" />
        <span class={["hidden", not @compact && "sm:inline"]}>{gettext("Delete")}</span>
      </button>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".CopySelection">
        export default {
          mounted() {
            this.el.addEventListener("click", () => {
              // The bar's stream container (#messages OR #thread-replies).
              const c = this.el.closest(".ed-selbar")?.dataset.container || "#messages"
              // Selected rows in chronological (document) order, both layouts.
              const rows = document.querySelectorAll(
                c + " .ed-flat--selected, " + c + " .ed-msg--selected",
              )
              const parts = []
              rows.forEach((r) => {
                const el = r.querySelector(".ed-flat__body, .ed-bubble__cap .break-words")
                const t = (el?.textContent || "").trim()
                if (t) parts.push(t)
              })
              const text = parts.join("\n\n")
              const done = () => this.pushEvent("selection_copied", {})
              if (!text) return done()
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
          },
        }
      </script>
    </div>
    """
  end

  attr :sel_delete, :map, required: true

  # Confirm sheet for deleting the selection. "Delete for everyone" is offered only when every
  # selected message is the user's own (all_mine); otherwise just "Delete for me". The context
  # re-checks authorship per message regardless of what the UI offers.
  defp delete_confirm(assigns) do
    ~H"""
    <div class="fixed inset-0 z-30" id="delete-confirm">
      <button
        class="absolute inset-0 w-full h-full"
        style="background: var(--ed-scrim);"
        phx-click="cancel_delete"
        aria-label={gettext("Close")}
        tabindex="-1"
      >
      </button>
      <div class="absolute inset-0 grid place-items-center p-4 pointer-events-none">
        <div
          class="w-full max-w-sm rounded-[var(--ed-radius-lg)] border p-5 space-y-4 pointer-events-auto"
          style="background: var(--ed-surface); border-color: var(--ed-border);"
          phx-window-keydown="cancel_delete"
          phx-key="Escape"
          role="dialog"
          aria-modal="true"
          aria-label={gettext("Delete messages")}
          id="dlg-delete"
          phx-hook=".FocusTrap"
          tabindex="-1"
        >
          <h2 style="font-weight:600;">
            {ngettext(
              "Delete %{count} message?",
              "Delete %{count} messages?",
              @sel_delete.count
            )}
          </h2>
          <div class="flex flex-col gap-2">
            <button
              :if={@sel_delete.for_all}
              type="button"
              class="ed-btn ed-btn--danger w-full"
              phx-click="delete_selection"
              phx-value-scope="both"
            >
              {gettext("Delete for everyone")}
            </button>
            <button
              type="button"
              class={["ed-btn w-full", (@sel_delete.for_all && "ed-btn--ghost") || "ed-btn--danger"]}
              style={@sel_delete.for_all && "color: var(--ed-danger-strong);"}
              phx-click="delete_selection"
              phx-value-scope="me"
            >
              {gettext("Delete for me")}
            </button>
            <button type="button" class="ed-btn ed-btn--ghost w-full" phx-click="cancel_delete">
              {gettext("Cancel")}
            </button>
          </div>
        </div>
      </div>
    </div>
    """
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
  attr :statuses, :map, default: %{}

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
      <.select_overlay id={@message.id} preview={select_preview(@message)} />
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
          <.avatar
            name={@message.sender.display_name}
            src={avatar_src(@message.sender)}
            status={status_of(@message.sender_id, @statuses)}
            dot_uid={@message.sender_id}
            size={:sm}
          />
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
          <span :if={@message.edited_at} class="ed-edited">{gettext("edited")}</span>
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

  # A group system notice (member added/removed) — a centered plashka, no sender (#165).
  defp message_bubble(%{message: %{kind: "system"}} = assigns) do
    ~H"""
    <div id={@id} class="ed-sysmsg"><span>{system_notice(@message.meta)}</span></div>
    """
  end

  defp message_bubble(assigns) do
    # A photo/video message renders Telegram-style: no frame, the media fills the
    # bubble, the time overlays it. Files keep the normal padded bubble.
    assigns =
      assigns
      |> assign(
        :media?,
        Enum.any?(
          assigns.message.attachments,
          &(&1.kind in ~w(image video) and not &1.as_file and not AlbumLayout.strip_photo?(&1))
        )
      )
      # Position in a merged file-group run (TG-attachments): nil for a solo/ungrouped bubble,
      # else :first | :middle | :last. Drives the fused corners, fixed width, and meta-once.
      |> assign(:grp, assigns.message.group_pos)

    ~H"""
    <%!-- data-client-id on MY own rows lets the rise-in observer skip them: the
          optimistic node already animated, so the real replacement swaps in
          silently (no double-animation / jerk). Others' messages still rise in. --%>
    <div
      id={@id}
      class={["ed-msg flex", @mine && "justify-end", @grp in [:middle, :last] && "ed-msg--grp-cont"]}
      data-client-id={@mine && @message.client_id}
      data-group-id={@message.group_id}
      data-ts={@message.inserted_at && DateTime.to_unix(@message.inserted_at)}
    >
      <.select_overlay id={@message.id} preview={select_preview(@message)} />
      <%!-- Bubble + reactions stack in a column so reactions hang UNDER the bubble
            (aligned to its side), not inside it (#107). Inside the bubble their chip
            outline + count blended into the bubble fill and read as a bare emoji. --%>
      <div class={["flex flex-col min-w-0", (@mine && "items-end") || "items-start"]}>
        <div
          class={[
            "ed-bubble",
            (@mine && "ed-bubble--me") || "ed-bubble--them",
            @media? && "ed-bubble--media",
            @grp && "ed-bubble--grp",
            @grp == :first && "ed-bubble--grp-first",
            @grp == :middle && "ed-bubble--grp-mid",
            @grp == :last && "ed-bubble--grp-last"
          ]}
          id={"bubble-#{@message.id}"}
          data-message-id={@message.id}
          phx-hook=".ContextMenu"
          aria-haspopup="menu"
        >
          <%= if @media? do %>
            <%!-- Telegram-style media (#messenger only): header (sender/reply/forward)
                  padded above, the photo/video edge-to-edge with the time as a
                  translucent overlay pill bottom-right, the caption padded below. --%>
            <div
              :if={
                (@group && not @mine && @message.sender) || @message.reply_to_id ||
                  @message.forwarded_from
              }
              class="ed-bubble__head"
            >
              <span
                :if={@group and not @mine and @message.sender}
                class="block"
                style="font-size:0.75rem; font-weight:600; color: var(--ed-primary-strong);"
              >
                {@message.sender.display_name}
              </span>
              <.quoted_reply message={@message} />
              <span :if={@message.forwarded_from} class="ed-forwarded">
                <.icon name="hero-arrow-uturn-right-micro" class="size-3" />
                {forwarded_label(@message.forwarded_from)}
              </span>
            </div>
            <div class="ed-media">
              <.album_view attachments={@message.attachments} message_id={@message.id} />
              <%!-- Time overlays the photo only when there's NO caption; with a caption it
                    rides in the caption line below (Telegram-style). --%>
              <span :if={@message.body == ""} class="ed-media-time">
                <.msg_meta
                  at={@message.inserted_at}
                  ticks={@mine and not @group}
                  read={@read}
                  edited={not is_nil(@message.edited_at)}
                />
              </span>
            </div>
            <div :if={@message.body != ""} class="ed-bubble__cap ed-bubble__cap--media">
              <span class="break-words">{Markup.to_iodata(@message.body)}</span>
              <span class="ed-bubble__meta">
                <.msg_meta
                  at={@message.inserted_at}
                  ticks={@mine and not @group}
                  read={@read}
                  edited={not is_nil(@message.edited_at)}
                />
              </span>
            </div>
          <% else %>
            <%!-- In a merged file group the sender name rides only the FIRST row (a solo/ungrouped
                  bubble is nil → shown as before). --%>
            <span
              :if={@group and not @mine and not is_nil(@message.sender) and @grp in [nil, :first]}
              class="block"
              style="font-size:0.75rem; font-weight:600; color: var(--ed-primary-strong);"
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
            <%!-- Caption + meta share a flow-root block so a long caption can't stretch
                  a media bubble wider than the photo (#135-twin): the wrap is constrained
                  to the media width (CSS width:0/min-width:100%) and the caption wraps to
                  it, while the meta floats bottom-right with text wrapping before it (#108).
                  In a merged file group the time+tick shows ONCE, on the LAST row (the middle
                  rows drop the cap entirely so the cards stack flush). --%>
            <div :if={@message.body != "" or @grp in [nil, :last]} class="ed-bubble__cap">
              <span :if={@message.body != ""} class="break-words">
                {Markup.to_iodata(@message.body)}
              </span>
              <span :if={@grp in [nil, :last]} class="ed-bubble__meta">
                <.msg_meta
                  at={@message.inserted_at}
                  ticks={@mine and not @group}
                  read={@read}
                  edited={not is_nil(@message.edited_at)}
                />
              </span>
            </div>
          <% end %>
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

  attr :at, :any, required: true
  # 1:1 "me" rows show delivery ticks; group rows don't (#142).
  attr :ticks, :boolean, default: false
  attr :read, :boolean, default: false
  # Edited marker (#164).
  attr :edited, :boolean, default: false

  # The time + (1:1) delivery ticks line, shared by the text-bubble meta and the
  # overlay pill on media bubbles.
  defp msg_meta(assigns) do
    ~H"""
    <span :if={@edited} class="ed-edited">{gettext("edited")}</span>
    <.local_time at={@at} />
    <span :if={@ticks} class="inline-flex items-center" style="margin-left:2px;">
      <.icon :if={not @read} name="hero-check-micro" class="size-3.5" />
      <span :if={@read} class="inline-flex items-center">
        <.icon name="hero-check-micro" class="size-3.5 -mr-2" />
        <.icon name="hero-check-micro" class="size-3.5" />
      </span>
    </span>
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
      <%!-- Edit (#164): your own, non-system, non-deleted messages. `start_edit` fetches the
            message and routes text → composer banner, media → the edit-media modal (PR-2).
            The server re-checks authorship. --%>
      <button
        :if={@mine and @message.kind != "system" and is_nil(@message.deleted_at)}
        type="button"
        class="ed-menu__item"
        role="menuitem"
        phx-click="start_edit"
        phx-value-id={@message.id}
      >
        <.icon name="hero-pencil-square-micro" class="size-4" /> {gettext("Edit")}
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
        phx-value-surface={(@in_thread && "thread") || "main"}
      >
        <.icon name="hero-arrow-uturn-right-micro" class="size-4" /> {gettext("Forward")}
      </button>
      <button
        type="button"
        class="ed-menu__item"
        role="menuitem"
        phx-click="enter_select"
        phx-value-id={@message.id}
        phx-value-surface={(@in_thread && "thread") || "main"}
      >
        <.icon name="hero-check-circle-micro" class="size-4" /> {gettext("Select")}
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
  attr :editing, :boolean, default: false

  # Attachment compose modal (#58): a Telegram-style centered overlay (media grid +
  # caption + send) opened when files are staged. The composer bar stays rendered
  # behind the scrim (#130) so it never vanishes — the modal floats on top and the
  # bar goes `inert`. Its caption (#compose-caption) is a SEPARATE field
  # (name="message[caption]") from the bar's chat input (#composer-body,
  # name="message[body]"), so typing a caption never mirrors into the chat input;
  # send_attachment reads message[caption] as the media's body.
  defp compose_overlay(assigns) do
    entries = live_entries(assigns.upload)
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

        <%!-- #164 text→media: signal this send EDITS the message (photos become it), so the
              overlay isn't mistaken for a brand-new message (the edit banner is behind us). --%>
        <p :if={@editing} class="ed-compose__edit-hint">
          <.icon name="hero-pencil-square-micro" class="size-3.5" />
          {gettext("Editing this message")}
        </p>

        <div class="ed-compose__body">
          <div
            :if={@media != []}
            class={[
              "ed-compose__grid",
              "ed-album--#{album_cols(length(@media))}",
              length(@media) == 1 && "ed-compose__grid--single"
            ]}
          >
            <%!-- data-name/size let the "Send as file" optimistic node (#122) render a
                  document card that mirrors the real one (name + size), not an album. --%>
            <div
              :for={entry <- @media}
              class="ed-compose__tile"
              data-name={entry.client_name}
              data-size={human_size(entry.client_size)}
            >
              <%!-- our own crash-safe preview (NOT <.live_img_preview>, see .ImgPreview) --%>
              <img
                :if={image_entry?(entry)}
                id={"imgp-#{entry.ref}"}
                phx-hook=".ImgPreview"
                phx-update="ignore"
                data-name={entry.client_name}
                data-size={entry.client_size}
                data-modified={entry.client_last_modified}
                class="ed-compose__img"
                alt=""
              />
              <div :if={video_entry?(entry)} class="ed-compose__video-wrap">
                <span class="ed-compose__video-fb" aria-hidden="true">
                  <.icon name="hero-film" class="size-7" />
                </span>
                <%!-- Playable local preview (#117): the file is only reachable at
                      selection, so the SendQueue hook stashes an object URL on
                      #composer keyed name:size:lastModified and .VideoPreview wires it up.
                      phx-update="ignore" so a caption keystroke's re-render can't
                      clobber the JS-set src and reload the clip. --%>
                <video
                  id={"vp-#{entry.ref}"}
                  phx-hook=".VideoPreview"
                  phx-update="ignore"
                  data-name={entry.client_name}
                  data-size={entry.client_size}
                  data-modified={entry.client_last_modified}
                  aria-label={entry.client_name || gettext("Video")}
                  class="ed-compose__video"
                  controls
                  playsinline
                  preload="metadata"
                >
                </video>
              </div>
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
            <div
              :for={entry <- @files}
              class="ed-attach-file"
              data-ref={entry.ref}
              data-name={entry.client_name}
              data-size={human_size(entry.client_size)}
              data-size-raw={entry.client_size}
              data-modified={entry.client_last_modified}
            >
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
          <%!-- The caption is its OWN field (message[caption]), NOT message[body]:
                the chat input behind the overlay keeps its own value, so typing here
                never mirrors into the chat input. send_attachment reads message[caption]
                as the media's body. --%>
          <input
            type="text"
            id="compose-caption"
            name="message[caption]"
            value={@form[:caption].value}
            class="ed-input"
            placeholder={gettext("Add a caption…")}
            autocomplete="off"
            phx-hook=".PasteUpload"
            phx-mounted={JS.focus()}
          />
          <%!-- "Send as file" (#122): type="button" (NOT submit) so it's never the form's
                implicit submitter — Enter in the caption must do a normal send, not this. The
                SendQueue hook's click handler sets a flag and requestSubmit()s, so the photo is
                stored uncompressed and shown as a document. Only offered when a photo is staged
                (video/file are never compressed). --%>
          <button
            :if={Enum.any?(@media, &image_entry?/1)}
            class="ed-btn--icon shrink-0"
            type="button"
            data-send-as-file
            aria-label={gettext("Send as file")}
            title={gettext("Send as an uncompressed file")}
          >
            <.icon name="hero-document-arrow-up-micro" class="size-5" />
          </button>
          <button
            class="ed-btn ed-btn--primary ed-btn--send shrink-0"
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

  # Preview title: counts the media (the album) when present, else the files. A
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

  # Upload errors flattened to {entry_name, error} pairs for the modal footer.
  defp compose_errors(upload) do
    Enum.flat_map(upload.entries, fn entry ->
      Enum.map(upload_errors(upload, entry), &{entry.client_name, &1})
    end)
  end

  attr :attachments, :list, required: true
  attr :message_id, :any, required: true

  # A message's attachments (#58). One renders exactly as before; several render
  # as a media grid (images as lightbox tiles, sharing a gallery so the lightbox
  # can page through them) followed by any videos/files stacked as full items.
  defp album_view(%{attachments: [single]} = assigns) do
    assigns = assign(assigns, :attachment, as_file_if_strip(single))

    ~H"""
    <.attachment_view attachment={@attachment} />
    """
  end

  defp album_view(assigns) do
    # The mosaic holds inline media: images + videos, minus "send as file" photos (#122) AND
    # strip photos (too wide/tall to fit the dialog — they fall to file cards below, like TG).
    media =
      Enum.filter(
        assigns.attachments,
        &(&1.kind in ~w(image video) and not &1.as_file and not AlbumLayout.strip_photo?(&1))
      )

    rest = (assigns.attachments -- media) |> Enum.map(&as_file_if_strip/1)

    assigns =
      assigns
      |> assign(:rows, AlbumLayout.rows(media))
      |> assign(:rest, rest)
      |> assign(:gallery, "album-#{assigns.message_id}")

    ~H"""
    <%!-- Telegram-style justified mosaic (#…): the media split into rows, each row a flex
          strip whose tiles take width proportional to their aspect ratio so the row fills the
          album width at one height with no cropping (a tile's box matches its photo's aspect).
          Uniform photos fall out as clean 2x2 / 3x3 grids; mixed aspects size proportionally.
          The row's aspect-ratio (= sum of its tiles' aspects) sets its height. Shared by DMs,
          rooms and threads (one album_view); image tiles page the lightbox together. --%>
    <div :if={@rows != []} class="ed-album mb-1">
      <div
        :for={{{row, sum}, ri} <- Enum.with_index(@rows)}
        class="ed-album__row"
        style={"aspect-ratio:#{sum}"}
      >
        <.media_tile
          :for={{{item, aspect}, ti} <- Enum.with_index(row)}
          item={item}
          dom_id={"att-#{item.id}"}
          class="ed-album__tile"
          gallery={@gallery}
          style={"flex:#{aspect} 1 0;#{tile_radius(ri, length(@rows), ti, length(row))}"}
        />
      </div>
    </div>
    <.attachment_view :for={attachment <- @rest} attachment={attachment} />
    """
  end

  # Flip a strip photo to as_file at RENDER time (no DB change) so the file-card path draws it;
  # the strip/layout math itself lives in AlbumLayout (and is unit-tested there).
  defp as_file_if_strip(att),
    do: if(AlbumLayout.strip_photo?(att), do: %{att | as_file: true}, else: att)

  # The drag-and-drop affordance (#207) — server-rendered (not appended by the hook) so it
  # survives morphdom re-renders; the .DropZone hook only toggles `.ed-dropzone--over` to fade
  # it in over the pane you're dragging files into.
  attr :label, :string, required: true

  defp drop_overlay(assigns) do
    ~H"""
    <div class="ed-dropzone__overlay" aria-hidden="true">
      <div class="ed-dropzone__inner">
        <.icon name="hero-arrow-up-tray" class="size-7" />
        <span>{@label}</span>
      </div>
    </div>
    """
  end

  # Per-tile corner radii for the album mosaic (Telegram-style rounded tiles). Every corner
  # gets a small radius EXCEPT the album's four OUTERMOST corners, which stay square so the
  # bubble's overflow-clip (and the head/caption edge rules) round the album as one piece —
  # a rounded tile corner there would leave a theme-bg notch inside the bubble's bigger curve.
  # Keyed off grid position (first/last row, first/last tile in its row), so it holds for any
  # photo count and any justified-row layout without per-count special-casing.
  defp tile_radius(ri, rows, ti, tiles) do
    sm = "var(--ed-album-inner)"
    tl = if(ri == 0 and ti == 0, do: "0", else: sm)
    tr = if(ri == 0 and ti == tiles - 1, do: "0", else: sm)
    br = if(ri == rows - 1 and ti == tiles - 1, do: "0", else: sm)
    bl = if(ri == rows - 1 and ti == 0, do: "0", else: sm)
    "border-radius:#{tl} #{tr} #{br} #{bl}"
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
  # "Send as file" image (#122): a downloadable document card, but the leading glyph is a
  # mini photo preview (the thumbnail) instead of the generic document icon. Matches before
  # the inline-image clause so an as_file photo never renders in the grid/lightbox.
  defp attachment_view(%{attachment: %{as_file: true}} = assigns) do
    ~H"""
    <a
      href={~p"/files/#{@attachment.id}"}
      download
      class="ed-file ed-file--photo mb-1"
      aria-label={gettext("Download %{name}", name: @attachment.filename || gettext("photo"))}
    >
      <span :if={as_file_previewable?(@attachment)} class="ed-file__thumb" aria-hidden="true">
        <img src={thumb_src(@attachment)} loading="lazy" alt="" />
      </span>
      <%!-- A not-yet-rendered original (HEIC before the worker's thumbnail lands) shows the
            document icon rather than a broken <img>; the {:thumbnail_ready} re-render swaps in
            the preview once libvips has made it. --%>
      <span :if={not as_file_previewable?(@attachment)} class="ed-file__icon" aria-hidden="true">
        <.icon name="hero-document-arrow-down-micro" class="size-5" />
      </span>
      <span class="ed-file__meta">
        <span class="ed-file__name">{@attachment.filename || gettext("Photo")}</span>
        <span class="ed-file__size">{human_size(@attachment.byte_size)}</span>
      </span>
    </a>
    """
  end

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
      aria-label={gettext("Photo")}
      class="ed-photo block mb-1 cursor-zoom-in"
    >
      <%!-- alt="" (decorative): Firefox paints alt text over a not-yet-loaded <img>, so a
            just-sent photo (no thumbnail yet → src is the slow full original) flashed
            "Photo" on the cobalt bubble. The a11y label rides the <a> instead. --%>
      <img
        src={thumb_src(@attachment)}
        width={@attachment.width}
        height={@attachment.height}
        class="rounded-[var(--ed-radius)] block"
        style={img_box(@attachment)}
        loading="lazy"
        alt=""
      />
    </a>
    """
  end

  defp attachment_view(%{attachment: %{kind: "video"}} = assigns) do
    assigns = assign(assigns, :portrait?, portrait_video?(assigns.attachment))

    ~H"""
    <%!-- Telegram-style: the in-stream clip is a poster + centered play button with NO inline
          controls (they crowded the time pill and read as clutter); .VideoExpand opens it
          full-screen WITH controls on click. The inline <video> (no controls) only paints the
          poster frame; the box is the positioning context for .StreamVideo's poster cover
          (#130), which masks a just-uploaded clip's transient first-load error.
          A portrait clip gets a wider 4:5 box (--portrait) with an ambient blurred-poster glow
          filling the sides, so its caption isn't squeezed into a narrow column. --%>
    <div
      id={"vbox-#{@attachment.id}"}
      phx-hook=".VideoExpand"
      data-src={~p"/files/#{@attachment.id}"}
      data-type={@attachment.content_type}
      role="button"
      tabindex="0"
      aria-label={gettext("Play %{name}", name: @attachment.filename || gettext("video"))}
      class={["ed-video-box ed-video-box--play mb-1", @portrait? && "ed-video-box--portrait"]}
      style={@portrait? && portrait_box_style(@attachment)}
    >
      <video
        id={"av-#{@attachment.id}"}
        phx-hook=".StreamVideo"
        preload="metadata"
        tabindex="-1"
        poster={@attachment.thumbnail_key && ~p"/files/#{@attachment.id}/thumb"}
        aria-hidden="true"
        class="ed-video"
        style={not @portrait? && video_ratio(@attachment)}
      >
        <source src={~p"/files/#{@attachment.id}"} type={@attachment.content_type} />
      </video>
      <%!-- Poster cover (#130): masks the player until it can actually play, so a
            just-uploaded clip's transient first-load error never flashes its icon.
            id + phx-update="ignore" so morphdom (this is a stream item, re-inserted on
            {:thumbnail_ready}) never drops it or resets .StreamVideo's src/fade state
            mid-load. The hook fills its src from the <video>'s poster and fades it on
            canplay. --%>
      <img
        id={"avc-#{@attachment.id}"}
        phx-update="ignore"
        class="ed-video-cover"
        aria-hidden="true"
        alt=""
      />
      <span class="ed-video-play" aria-hidden="true">
        <.icon name="hero-play-solid" class="size-7" />
      </span>
    </div>
    """
  end

  defp attachment_view(assigns) do
    ~H"""
    <a
      href={~p"/files/#{@attachment.id}"}
      download
      data-ts={DateTime.to_unix(@attachment.inserted_at)}
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

  # Whether an as_file photo (#122) can be shown inline in its document card: a generated
  # thumbnail always works; otherwise only a browser-renderable original (a raw HEIC, say,
  # would be a broken <img> until the worker's thumbnail lands → show the document icon).
  defp as_file_previewable?(%{thumbnail_key: key}) when is_binary(key), do: true

  defp as_file_previewable?(%{content_type: type}),
    do: type in ~w(image/jpeg image/png image/gif image/webp image/avif)

  attr :people, :list, required: true

  defp new_conversation_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-30">
      <button
        class="absolute inset-0 w-full h-full"
        style="background: var(--ed-scrim);"
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
          aria-label={gettext("New conversation")}
          id="dlg-new-conv"
          phx-hook=".FocusTrap"
          tabindex="-1"
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
                  class="flex items-center gap-3 p-2 rounded-[var(--ed-radius)] cursor-pointer transition-colors hover:bg-[var(--ed-surface-2)]"
                >
                  <input
                    type="checkbox"
                    name="member_ids[]"
                    value={u.id}
                    class="size-5 accent-[var(--ed-primary)]"
                  />
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
        style="background: var(--ed-scrim);"
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
          aria-label={gettext("Move to folder")}
          id="dlg-folder"
          phx-hook=".FocusTrap"
          tabindex="-1"
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
              class="flex w-full items-center gap-3 p-2 rounded-[var(--ed-radius)] text-left transition-colors hover:bg-[var(--ed-surface-2)]"
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
  attr :status, :string, default: nil
  attr :self, :boolean, default: false

  # A light profile popover anchored at the clicked avatar/name (a bottom sheet
  # on mobile). Opened from message rows, the chat header peer, and member
  # lists. Own card shows an "Edit profile" link instead of "Message".
  defp profile_popover(assigns) do
    ~H"""
    <%!-- display:contents so this grouping wrapper is NOT a flex item of .ed-root — otherwise
          opening the popover adds one more `gap` (0.625rem) to the row and shifts the whole
          layout ~10px sideways (#195). The scrim + card are position:fixed, so they render the
          same with the box removed. --%>
    <div class="contents">
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
          <.avatar
            name={@user.display_name}
            src={avatar_src(@user)}
            status={@status}
            dot_label={false}
            size={:lg}
          />
          <h2 class="mt-3 font-semibold" style="font-size:1.0625rem;">{@user.display_name}</h2>
          <p style="color: var(--ed-muted); font-size:0.8125rem;">@{@user.username}</p>
          <p
            class="mt-0.5"
            style={"font-size:0.75rem; color: var(#{status_color_var(@status)});"}
          >
            {status_label(@status)}
          </p>

          <p
            :if={@user.bio}
            class="mt-4 whitespace-pre-line break-words text-left w-full"
            style="font-size:0.875rem; color: var(--ed-ink);"
          >
            {@user.bio}
          </p>

          <.managed_identity user={@user} compact />
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

  # Admin-managed identity rows (#173) — shared by the full profile panel and the
  # popover so both stay consistent. Read-only; renders only when a field is set
  # (filled by the admin panel #174 / a future sync). `compact` (the popover) shows
  # only the headline field (position) to stay light; the full panel shows all.
  #
  # Spacing logic: the value is pinned tight under its label (small margin + tight
  # leading — the default 1.5 line-height was what made the pairs look loose), and
  # the gap BETWEEN rows is clearly larger, so it reads as grouped pairs.
  attr :user, :map, required: true
  attr :compact, :boolean, default: false

  defp managed_identity(assigns) do
    all = [
      {gettext("Position"), assigns.user.position},
      {gettext("Structure"), assigns.user.structure},
      {gettext("Corporate email"), assigns.user.corp_email}
    ]

    fields =
      if(assigns.compact, do: Enum.take(all, 1), else: all)
      |> Enum.filter(fn {_label, value} -> value end)

    assigns = assign(assigns, :fields, fields)

    ~H"""
    <dl
      :if={@fields != []}
      class="mt-4 w-full text-left border-t pt-3 flex flex-col gap-3"
      style="border-color: var(--ed-border);"
    >
      <div :for={{label, value} <- @fields}>
        <dt class="leading-tight" style="color: var(--ed-muted); font-size:0.75rem;">{label}</dt>
        <dd
          class="mt-0.5 leading-snug break-words"
          style="font-size:0.875rem; color: var(--ed-ink); overflow-wrap: anywhere;"
        >
          {value}
        </dd>
      </div>
    </dl>
    """
  end

  attr :conversation, :map, required: true
  attr :peer, :map, default: nil
  attr :user, :map, required: true
  attr :group_renaming, :boolean, default: false
  attr :upload, :any, default: nil, doc: "the :group_avatar upload config (#178)"
  attr :statuses, :any, required: true
  attr :tab, :string, required: true
  attr :media, :list, required: true
  attr :more, :boolean, default: false

  # Conversation profile panel (#136): the DM peer's card OR the group's card + member list,
  # plus a tabbed per-dialog media gallery. Mirrors the thread panel's aside (RHS on desktop,
  # full-screen overlay on mobile). `peer` is the loaded peer User for a DM, nil for a group.
  defp conv_profile_panel(assigns) do
    assigns =
      assigns
      |> assign(:peer_status, assigns.peer && status_of(assigns.peer.id, assigns.statuses))
      |> assign(:my_role, my_group_role(assigns.conversation, assigns.user))

    ~H"""
    <aside class="ed-thread ed-profile" aria-label={gettext("Profile")}>
      <header
        class="flex items-center gap-2 px-4 h-14 border-b shrink-0"
        style="border-color: var(--ed-border);"
      >
        <button
          type="button"
          class="ed-btn--icon md:hidden"
          phx-click="close_profile_panel"
          aria-label={gettext("Back")}
        >
          <.icon name="hero-arrow-left-mini" class="size-5" />
        </button>
        <div class="min-w-0 flex-1 font-semibold" style="font-size:0.9375rem;">
          {gettext("Profile")}
        </div>
        <button
          type="button"
          class="ed-btn--icon hidden md:inline-flex"
          phx-click="close_profile_panel"
          aria-label={gettext("Close")}
        >
          <.icon name="hero-x-mark-mini" class="size-5" />
        </button>
      </header>

      <div class="ed-profile__scroll">
        <%!-- DM: the peer's card. --%>
        <div :if={@peer} class="flex flex-col items-center text-center px-4 pt-5 pb-5">
          <.avatar
            name={@peer.display_name}
            src={avatar_src(@peer)}
            status={@peer_status}
            dot_label={false}
            size={:lg}
          />
          <h2 class="mt-3 font-semibold" style="font-size:1.125rem;">{@peer.display_name}</h2>
          <p style="color: var(--ed-muted); font-size:0.8125rem;">@{@peer.username}</p>
          <p
            :if={@peer_status}
            class="mt-0.5"
            style={"font-size:0.75rem; color: var(#{status_color_var(@peer_status)});"}
          >
            {status_label(@peer_status)}
          </p>
          <p
            :if={@peer.bio}
            class="mt-3 whitespace-pre-line break-words text-left w-full"
            style="font-size:0.875rem; color: var(--ed-ink);"
          >
            {@peer.bio}
          </p>
          <.managed_identity user={@peer} />
        </div>

        <%!-- Group: the group's card + the member list (tap a member for their profile). --%>
        <div :if={is_nil(@peer)} class="flex flex-col items-center text-center px-4 pt-4 pb-3.5">
          <%!-- #178: owner/admin set the group photo by clicking the big avatar (auto-uploads);
                everyone else sees it plain. Initials fall back when unset. --%>
          <.avatar
            :if={@my_role not in ~w(owner admin)}
            name={title(@conversation, @user)}
            src={group_avatar_src(@conversation)}
            size={:lg}
          />
          <div :if={@my_role in ~w(owner admin)} class="flex flex-col items-center">
            <% entry = @upload && List.first(@upload.entries) %>
            <form phx-change="validate_group_avatar" phx-submit="validate_group_avatar">
              <label
                class="ed-avatar-edit"
                tabindex="-1"
                title={gettext("Change group photo")}
                aria-label={gettext("Change group photo")}
              >
                <span class="ed-avatar ed-avatar--lg" aria-hidden="true">
                  <.live_img_preview :if={entry} entry={entry} />
                  <img
                    :if={!entry && @conversation.avatar_key}
                    src={group_avatar_src(@conversation)}
                    alt=""
                  />
                  <span :if={!entry && !@conversation.avatar_key}>
                    {initials(title(@conversation, @user))}
                  </span>
                </span>
                <span class="ed-avatar-edit__overlay" aria-hidden="true">
                  <.icon name="hero-camera-micro" class="size-5" />
                </span>
                <.live_file_input :if={@upload} upload={@upload} class="sr-only" />
              </label>
            </form>
            <button
              :if={@conversation.avatar_key && @upload && Enum.empty?(@upload.entries)}
              type="button"
              phx-click="remove_group_avatar"
              class="mt-1.5"
              style="color: var(--ed-danger); font-size:0.75rem;"
            >
              {gettext("Remove photo")}
            </button>
            <p
              :for={err <- (@upload && upload_errors(@upload)) || []}
              class="mt-1.5"
              style="color: var(--ed-danger); font-size:0.75rem;"
            >
              {group_avatar_error(err)}
            </p>
          </div>
          <%!-- Owner/admin can rename the group inline (#165); a blank name reverts to
                the auto name from members. --%>
          <%!-- Title stays optically centred; the rename pencil floats in the right gutter
                (absolute, so it never nudges the name off-centre) and stays visible on touch. --%>
          <div
            :if={!@group_renaming}
            class="relative mt-3 flex w-full items-center justify-center px-7"
          >
            <h2 class="truncate font-semibold" style="font-size:1.125rem;">
              {title(@conversation, @user)}
            </h2>
            <button
              :if={@my_role in ~w(owner admin)}
              type="button"
              class="ed-btn--icon absolute right-0 top-1/2 -translate-y-1/2"
              phx-click="start_group_rename"
              title={gettext("Rename group")}
              aria-label={gettext("Rename group")}
            >
              <.icon name="hero-pencil-square-micro" class="size-4" />
            </button>
          </div>
          <form
            :if={@group_renaming}
            phx-submit="rename_group"
            class="mt-3 flex w-full max-w-xs items-center gap-2"
          >
            <input
              type="text"
              name="title"
              value={@conversation.title}
              maxlength="100"
              autocomplete="off"
              aria-label={gettext("Group name")}
              placeholder={gettext("Group name")}
              phx-mounted={JS.focus()}
              class="ed-input flex-1"
            />
            <button type="submit" class="ed-btn ed-btn--primary ed-btn--sm">
              {gettext("Save")}
            </button>
            <button
              type="button"
              class="ed-btn ed-btn--ghost ed-btn--sm"
              phx-click="cancel_group_rename"
            >
              {gettext("Cancel")}
            </button>
          </form>
        </div>
        <%!-- Members section (#136): the "N members" count anchors the list as a left-aligned
              section header (no separate eyebrow — impeccable), with the add action on the right.
              A top divider bridges the centred identity card above. Capped + scrollable so a
              large roster doesn't bury the gallery below. --%>
        <div :if={is_nil(@peer)} class="ed-members">
          <div class="ed-members__head">
            <span class="ed-members__count">
              {ngettext("%{count} member", "%{count} members", member_count(@conversation))}
            </span>
            <button
              :if={@my_role in ~w(owner admin)}
              type="button"
              class="ed-member-add"
              phx-click="open_group_add_members"
              aria-label={gettext("Add members")}
            >
              <.icon name="hero-user-plus-mini" class="size-4" />
              <span>{gettext("Add")}</span>
            </button>
          </div>
          <div class="ed-members__list" aria-label={gettext("Members")} role="group">
            <%= for m <- active_members(@conversation) do %>
              <%!-- #165: owner/admin get a labeled actions menu (⋯ or right-click/long-press),
                    reusing the .ContextMenu hook so it positions fixed (the list scrolls).
                    Non-actionable rows are a plain row. --%>
              <%= if member_actions?(@my_role, m.role, m.user.id, @user.id) do %>
                <div class="ed-member-row" id={"member-#{m.user.id}"} phx-hook=".ContextMenu">
                  <.member_main m={m} me={@user.id} statuses={@statuses} />
                  <button
                    type="button"
                    class="ed-btn--icon"
                    data-menu-trigger
                    title={gettext("Member actions")}
                    aria-label={gettext("Member actions")}
                  >
                    <.icon name="hero-ellipsis-horizontal-mini" class="size-4" />
                  </button>
                  <div class="ed-menu" id={"member-menu-#{m.user.id}"} data-menu role="menu" hidden>
                    <button
                      :if={@my_role == "owner" and m.role == "member"}
                      type="button"
                      class="ed-menu__item"
                      role="menuitem"
                      phx-click="group_set_role"
                      phx-value-id={m.user.id}
                      phx-value-role="admin"
                    >
                      <.icon name="hero-shield-check-micro" class="size-4" /> {gettext("Make admin")}
                    </button>
                    <button
                      :if={@my_role == "owner" and m.role == "admin"}
                      type="button"
                      class="ed-menu__item"
                      role="menuitem"
                      phx-click="group_set_role"
                      phx-value-id={m.user.id}
                      phx-value-role="member"
                    >
                      <.icon name="hero-shield-exclamation-micro" class="size-4" /> {gettext(
                        "Remove admin"
                      )}
                    </button>
                    <button
                      :if={@my_role == "owner"}
                      type="button"
                      class="ed-menu__item"
                      role="menuitem"
                      phx-click="group_transfer_ownership"
                      phx-value-id={m.user.id}
                      data-confirm={gettext("Hand this group over? You will become an admin.")}
                    >
                      <.icon name="hero-key-micro" class="size-4" /> {gettext("Transfer ownership")}
                    </button>
                    <%!-- Only owners see items above the divider; for an admin (just
                          "Remove") the divider would dangle, so gate it on the owner items. --%>
                    <div :if={@my_role == "owner"} class="ed-menu__sep"></div>
                    <button
                      type="button"
                      class="ed-menu__item ed-menu__item--danger"
                      role="menuitem"
                      phx-click="group_remove_member"
                      phx-value-id={m.user.id}
                      data-confirm={gettext("Remove this member from the group?")}
                    >
                      <.icon name="hero-user-minus-micro" class="size-4" /> {gettext(
                        "Remove from group"
                      )}
                    </button>
                  </div>
                </div>
              <% else %>
                <div class="ed-member-row">
                  <.member_main m={m} me={@user.id} statuses={@statuses} />
                </div>
              <% end %>
            <% end %>
          </div>
        </div>

        <div
          id="gallery-tabs"
          class="ed-gallery-tabs"
          role="tablist"
          aria-label={gettext("Shared media")}
          phx-hook=".GalleryTabs"
        >
          <%!-- The .GalleryTabs hook slides this cobalt underline under the active tab and
                wires ←/→ keyboard navigation (APG tabs). --%>
          <span
            id="gallery-indicator"
            class="ed-gallery-indicator"
            phx-update="ignore"
            data-gallery-indicator
            aria-hidden="true"
          >
          </span>
          <button
            :for={{kind, label} <- gallery_tabs()}
            id={"gtab-#{kind}"}
            type="button"
            role="tab"
            aria-controls="gallery-panel"
            tabindex={if @tab == kind, do: "0", else: "-1"}
            class={["ed-gallery-tab", @tab == kind && "ed-gallery-tab--on"]}
            aria-selected={to_string(@tab == kind)}
            phx-click="gallery_tab"
            phx-value-tab={kind}
          >
            {label}
          </button>
        </div>

        <div id="gallery-panel" role="tabpanel" aria-labelledby={"gtab-#{@tab}"}>
          <.gallery_content tab={@tab} media={@media} />
          <button
            :if={@more}
            type="button"
            class="ed-gallery-more"
            phx-click="gallery_more"
          >
            {gettext("Load more")}
          </button>
        </div>
      </div>
    </aside>
    """
  end

  attr :tab, :string, required: true
  attr :media, :list, required: true

  defp gallery_content(%{media: []} = assigns) do
    ~H"""
    <div class="ed-gallery-empty">
      <.icon name={gallery_empty_icon(@tab)} class="size-8" />
      <p>{gallery_empty_text(@tab)}</p>
    </div>
    """
  end

  # Photos + videos render as a square thumbnail grid (shared media_tile); photos open the
  # lightbox, paging the conversation gallery together.
  defp gallery_content(%{tab: tab} = assigns) when tab in ~w(image video) do
    ~H"""
    <%!-- The .GalleryMonths hook inserts month dividers between tiles, grouped in the
          viewer's LOCAL timezone from each tile's data-ts (like the message DateRail #83) —
          so a busy gallery stays scannable by month. --%>
    <div
      id="gallery-grid"
      class="ed-gallery-grid"
      phx-hook=".GalleryMonths"
      data-locale={Gettext.get_locale()}
    >
      <.media_tile
        :for={item <- @media}
        item={item}
        dom_id={"g-#{item.id}"}
        class="ed-gallery-tile"
        gallery="conv-gallery"
      />
    </div>
    """
  end

  # Files + audio render as a stacked list of download cards (reusing attachment_view),
  # month-grouped by the same .GalleryMonths hook as the grids.
  defp gallery_content(assigns) do
    ~H"""
    <div
      id="gallery-list"
      class="ed-gallery-list"
      phx-hook=".GalleryMonths"
      data-locale={Gettext.get_locale()}
    >
      <.attachment_view :for={att <- @media} attachment={att} />
    </div>
    """
  end

  attr :item, :map, required: true
  attr :dom_id, :string, required: true
  attr :class, :string, required: true
  attr :gallery, :string, required: true
  # Optional inline style — the album mosaic passes `flex:<aspect> 1 0` so the tile takes
  # width proportional to its aspect ratio; the square profile gallery leaves it nil.
  attr :style, :string, default: nil

  # Shared media grid tile (#136): an image opens the lightbox (paging its `gallery`); a video
  # is a poster with a play badge. Used by the message album (album_view) AND the profile
  # gallery, so the lightbox/poster behaviour lives in ONE place. The phx-hook must be a
  # LITERAL string — a dynamic value skips the compile-time colocated-hook rewrite.
  defp media_tile(%{item: %{kind: "image"}} = assigns) do
    ~H"""
    <a
      id={@dom_id}
      phx-hook=".Lightbox"
      data-full={~p"/files/#{@item.id}"}
      data-gallery={@gallery}
      data-ts={DateTime.to_unix(@item.inserted_at)}
      href={~p"/files/#{@item.id}"}
      target="_blank"
      rel="noopener"
      aria-label={@item.filename || gettext("Photo")}
      class={[@class, "ed-photo cursor-zoom-in"]}
      style={@style}
    >
      <%!-- alt="" (decorative) — the a11y label rides the <a>; see attachment_view. --%>
      <img
        src={thumb_src(@item)}
        loading="lazy"
        decoding="async"
        alt=""
      />
    </a>
    """
  end

  defp media_tile(%{item: %{kind: "video"}} = assigns) do
    ~H"""
    <a
      id={@dom_id}
      phx-hook=".VideoExpand"
      data-src={~p"/files/#{@item.id}"}
      data-type={@item.content_type}
      href={~p"/files/#{@item.id}"}
      data-ts={DateTime.to_unix(@item.inserted_at)}
      target="_blank"
      rel="noopener"
      class={@class}
      aria-label={@item.filename || gettext("Video")}
      style={@style}
    >
      <img :if={@item.thumbnail_key} src={thumb_src(@item)} loading="lazy" decoding="async" alt="" />
      <span :if={is_nil(@item.thumbnail_key)} class="ed-album__tile-fill" />
      <span class="ed-album__play" aria-hidden="true">
        <.icon name="hero-play-solid" class="size-6" />
      </span>
    </a>
    """
  end

  # Belt-and-suspenders: callers only pass image/video, but an unexpected kind renders
  # nothing rather than crashing the whole stream/gallery render.
  defp media_tile(assigns), do: ~H""

  defp gallery_tabs do
    [
      {"image", gettext("Photo")},
      {"video", gettext("Video")},
      {"file", gettext("Files")},
      {"audio", gettext("Audio")}
    ]
  end

  defp gallery_empty_text("image"), do: gettext("No photos in this chat yet")
  defp gallery_empty_text("video"), do: gettext("No videos in this chat yet")
  defp gallery_empty_text("file"), do: gettext("No files in this chat yet")
  defp gallery_empty_text("audio"), do: gettext("No audio in this chat yet")

  defp gallery_empty_icon("image"), do: "hero-photo"
  defp gallery_empty_icon("video"), do: "hero-film"
  defp gallery_empty_icon("file"), do: "hero-document"
  defp gallery_empty_icon("audio"), do: "hero-musical-note"

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

  attr :peer, :map, default: nil

  # The offline-header line for a 1:1 peer (#102): "last seen <time>" when we know
  # when they were last active, else plain "offline" (group/unknown).
  defp last_seen(%{peer: %{last_active_at: %DateTime{}}} = assigns) do
    ~H"""
    <span>
      {gettext("last seen")}
      <time
        phx-hook=".LastSeen"
        id={"ls-#{System.unique_integer([:positive])}"}
        datetime={DateTime.to_iso8601(@peer.last_active_at)}
      >
        {Calendar.strftime(@peer.last_active_at, "%H:%M")}
      </time>
    </span>
    """
  end

  defp last_seen(assigns) do
    ~H"""
    {gettext("offline")}
    """
  end

  ## Helpers

  # Re-selecting the conversation that's already open (clicking it again in the sidebar /
  # room list — a push_patch to the same id) is a no-op. Re-running the full selection
  # re-streamed every message with reset: true, which made the DateRail pills churn and the
  # scroll jump to a "random" spot (#166). Live updates keep the open thread fresh, and a
  # permalink to a message in the open chat still jumps via focus_message_target, which runs
  # after this and loads its own window. The same-id match relies on the repeated `id`
  # binding; on the connected mount `selected` is still nil, so the first load falls through.
  defp select_conversation(%{assigns: %{selected: %{id: id}}} = socket, %{id: id}), do: socket

  defp select_conversation(socket, conversation) do
    scope = socket.assigns.current_scope
    socket = unsubscribe(socket)
    Chat.subscribe(conversation.id)
    Chat.mark_read(scope, conversation.id)

    {:ok, messages} = Chat.list_messages(scope, conversation.id, limit: @page)
    # Room flat layout: collapse consecutive same-author runs + facepiles.
    {messages, last_flat} = mark_compact(messages, conversation)
    # Merged file bubbles (TG-attachments): mark each row's position in its group run.
    {messages, last_group} = mark_group_pos(messages)

    socket
    # Drop chat A's STAGED attachments before opening B — they belong to the
    # conversation they were composed in; otherwise they ride into the new composer
    # and a send would attach them to the wrong chat (#89, with the text-draft reset
    # below). An in-flight send (sending_media) is NOT dropped: it finishes in the
    # background and lands in its pinned conversation, so leaving mid-upload doesn't
    # lose the media.
    |> drop_staged_on_switch()
    |> assign(
      selected: conversation,
      # An edit is bound to a specific message — drop it when the chat changes (#164).
      editing: nil,
      edit_media: nil,
      # Multi-select is per-conversation — exit it on a chat switch.
      selection: nil,
      sel_delete: nil,
      select_surface: nil,
      subscribed_id: conversation.id,
      other_read_at: other_read_at(conversation, scope.user),
      has_more: length(messages) == @page,
      oldest_id: messages |> List.first() |> then(&(&1 && &1.id)),
      oldest_msg: List.first(messages),
      # Clear any prior jump target — it belonged to the chat we're leaving (the nonce
      # gates re-firing, but don't render a stale id for the new conversation).
      focus_id: nil,
      thread_root: nil,
      # Close the conversation-profile panel (#136) when switching chats — it belongs to the
      # conversation you were viewing, not the new one.
      profile_open: false,
      profile_peer: nil,
      group_renaming: false,
      # Drop a half-open add-members modal so it can't act on the new conversation (#165).
      add_open: false,
      gallery_media: [],
      gallery_more: false,
      # The composer is per-conversation: reset it so a draft/last-sent body from
      # the previous chat doesn't reappear in this one's input (#89). The input
      # binds to @composer[:body].value, which otherwise keeps the stale text.
      composer: empty_composer(),
      # Drop any staged quote-reply (#71) — its target is the old conversation's.
      reply_to: nil,
      thread_reply_to: nil,
      thread_editing: nil,
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
      last_group: last_group,
      thread_last_flat: nil,
      compacts: Map.new(messages, &{&1.id, &1.compact}),
      group_pos: Map.new(messages, &{&1.id, &1.group_pos}),
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

  # Reload the message stream to a window that INCLUDES `anchor_id` (a permalink / jump
  # target), mirroring select_conversation's per-stream assigns. Without this, a jump to
  # a message older than the loaded page can't scroll/highlight — the row was never
  # rendered. The newest-anchored window keeps the stream bottom at the real latest, so
  # the .ScrollBottom follow/live-update behavior is unchanged.
  defp load_messages_around(socket, conversation, anchor_id) do
    scope = socket.assigns.current_scope

    case Chat.list_messages_around(scope, conversation.id, anchor_id) do
      {:ok, messages, has_more} ->
        {messages, last_flat} = mark_compact(messages, conversation)
        {messages, last_group} = mark_group_pos(messages)

        socket
        |> assign(
          has_more: has_more,
          oldest_id: messages |> List.first() |> then(&(&1 && &1.id)),
          oldest_msg: List.first(messages),
          last_flat: last_flat,
          last_group: last_group,
          compacts: Map.new(messages, &{&1.id, &1.compact}),
          group_pos: Map.new(messages, &{&1.id, &1.group_pos}),
          thread_participants: facepiles(scope, conversation, messages)
        )
        |> stream(:messages, messages, reset: true)

      # Anchor vanished between the guard and here (a concurrent delete), or a bad id:
      # leave the current window untouched; the client reports the message unavailable.
      _ ->
        socket
    end
  end

  # Load a window around `message_id` only when it's a live, visible main-stream message
  # of the open conversation — so a jump to an older message actually renders the row.
  # A deleted / foreign / unknown id falls through unchanged to the "message unavailable"
  # path (the client finds no row and reports back).
  defp maybe_load_around(socket, message_id) do
    conv = socket.assigns.selected
    scope = socket.assigns.current_scope

    if conv && Chat.main_stream_message?(scope, conv.id, message_id) do
      load_messages_around(socket, conv, message_id)
    else
      socket
    end
  end

  # Flag a main-stream jump target for the .ScrollBottom hook (data-focus-* on
  # #message-scroll). The bumped nonce makes re-jumping the same message re-fire.
  defp assign_focus(socket, message_id) do
    assign(socket, focus_id: to_string(message_id), focus_nonce: socket.assigns.focus_nonce + 1)
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
      |> assign(sidebar_peer_ids: peers, sidebar_top: top_conv_id(convos))
      |> stream(:conversations, convos, opts)
    end
  end

  # The conversation currently on top of the sidebar (#194) — so a bump can tell "already
  # there" (in-place update, no animation) from a real move (delete + re-insert + animate).
  defp top_conv_id([%{id: id} | _]), do: id
  defp top_conv_id(_), do: nil

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
        put_dm_sidebar(socket, summary, conversation_id, insert_opts)

      {:ok, _room} ->
        # Badge refresh if we're looking at this room's channel; cross-channel
        # rail badges arrive with #32.
        refresh_rooms_if_current(socket, conversation_id)

      {:error, _} ->
        socket
    end
  end

  # A DM's sidebar row: drop it when it's filtered out of the active folder; bump it to the
  # top on new activity (#194); otherwise update it in place.
  defp put_dm_sidebar(socket, summary, conversation_id, insert_opts) do
    scope = socket.assigns.current_scope
    fid = socket.assigns.folder_id
    dom_id = "conversations-#{conversation_id}"

    cond do
      not (is_nil(fid) or fid in Chat.conversation_folder_ids(scope, conversation_id)) ->
        stream_delete_by_dom_id(socket, :conversations, dom_id)

      # Reorder-to-top (activity bump, #194): stream_insert(at: 0) updates an existing row in
      # place but does NOT lift it to the front, so delete first to actually reposition it — BUT
      # only when the chat isn't already on top. Re-sending into the chat that's already at the
      # top would otherwise delete+re-insert it for no net move, re-running the bump animation on
      # every message. When it's already top, a plain in-place update keeps it there (no recreate,
      # no animation).
      Keyword.has_key?(insert_opts, :at) and socket.assigns.sidebar_top != conversation_id ->
        socket
        |> stream_delete_by_dom_id(:conversations, dom_id)
        |> stream_insert(:conversations, summary, insert_opts)
        |> assign(sidebar_top: conversation_id)

      true ->
        stream_insert(socket, :conversations, summary, insert_opts)
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

  # In-thread search (#189): same nil-vs-[] convention as run_room_search.
  defp run_thread_search(socket, root_id, q) do
    if String.trim(q) == "" do
      nil
    else
      Chat.search_thread(socket.assigns.current_scope, root_id, q)
    end
  end

  # Reset the in-thread search panel — on close, on opening a different thread, and
  # after jumping to a result (so the panel doesn't linger over the focused reply).
  defp reset_thread_search(socket) do
    assign(socket, thread_search_open: false, thread_search: "", thread_results: nil)
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
    scope = socket.assigns.current_scope

    assign(socket,
      channels: Channels.list_channels(scope),
      messenger_unread: Chat.messenger_unread_total(scope)
    )
  end

  # #216: total unread for the browser-tab badge — messenger (DMs/groups, already
  # mute-filtered) plus unmuted channels. Muted channels are excluded, same as the
  # rail/folder "no badge past mute" invariant.
  defp tab_unread_total(messenger_unread, channels) do
    messenger_unread + Enum.sum(for c <- channels, not c.muted, do: c.unread_count)
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

  # Grouped-file bubble runs (TG-attachments): mark each message's `group_pos` from runs of
  # CONSECUTIVE same-sender messages sharing a non-nil group_id — `:first | :middle | :last`,
  # or nil for a solo/ungrouped row (a run of one, e.g. after deletes, renders as a normal
  # bubble). Returns the run tracker {sender_id, group_id, id, pos} for live appends. Pure.
  defp mark_group_pos(messages) do
    marked =
      messages
      |> Enum.chunk_by(&group_run_key/1)
      |> Enum.flat_map(&group_positions/1)

    {marked, group_tail(marked)}
  end

  # A solo/ungrouped message keys uniquely (by id) so it never merges with a neighbour; a grouped
  # message keys by {sender, group_id} so consecutive members of the same send chunk together.
  defp group_run_key(%{group_id: nil, id: id}), do: {:solo, id}
  defp group_run_key(%{group_id: group_id, sender_id: sender_id}), do: {sender_id, group_id}

  defp group_positions([message]), do: [%{message | group_pos: nil}]

  defp group_positions([first | _] = run) do
    last = List.last(run)

    Enum.map(run, fn message ->
      pos =
        cond do
          message.id == first.id -> :first
          message.id == last.id -> :last
          true -> :middle
        end

      %{message | group_pos: pos}
    end)
  end

  defp group_tail([]), do: nil

  # Carry the last message STRUCT (not just its id) so a live continuation can re-stream it with
  # an updated position without re-fetching it.
  defp group_tail(messages) do
    m = List.last(messages)
    {m.sender_id, m.group_id, m, m.group_pos}
  end

  # Live insert (DMs): continue or break the grouped-file run. While the group is STILL uploading on
  # THIS (sender's) session — its send queue has more items coming — a landed row renders as :first
  # / :middle (never :last), so it fuses with the in-flight optimistic bubble below instead of
  # detaching as its own tailed bubble. The FINAL file (queue drained) lands as :last, closing the
  # bubble. A recipient (no send queue) sees the ordinary progressive merge. Mirrors the flat
  # compact seam. Returns {message_with_pos, socket} and records the new tail + group_pos map.
  defp mark_group_new(socket, message) do
    in_flight? = not is_nil(message.group_id) and group_in_flight?(socket, message.group_id)

    case socket.assigns.last_group do
      {sid, gid, prev, prev_pos}
      when sid == message.sender_id and not is_nil(message.group_id) and gid == message.group_id ->
        # Continuation: this row is :middle while more are coming, else :last (the tail).
        message = %{message | group_pos: if(in_flight?, do: :middle, else: :last)}
        {message, socket |> demote_prev(prev, prev_pos) |> track_group(message)}

      _ ->
        # First row of a group. In-flight → :first (opens the bubble the #pending tail continues);
        # else a solo/ungrouped row (nil).
        message = %{message | group_pos: if(in_flight?, do: :first, else: nil)}
        {message, track_group(socket, message)}
    end
  end

  # Is this file group still uploading on this session — does a live send queue for it have more
  # items to come? (Only the sender has a send queue; a recipient always sees false → normal merge.)
  defp group_in_flight?(socket, group_id) do
    Enum.any?(socket.assigns.send_queues, fn q ->
      q.group_id == group_id and (q.files_left > 0 or q.albums != %{})
    end)
  end

  # The previous tail is no longer the tail once a row continues the run: nil→:first (it becomes the
  # head), :last→:middle (demoted); :first / :middle keep their place. Re-stream only if it changed.
  defp demote_prev(socket, prev, prev_pos) do
    new_pos =
      case prev_pos do
        nil -> :first
        :last -> :middle
        other -> other
      end

    if new_pos != prev_pos, do: restream_prev_group(socket, prev, new_pos), else: socket
  end

  defp track_group(socket, message) do
    assign(socket,
      last_group: {message.sender_id, message.group_id, message, message.group_pos},
      group_pos: Map.put(socket.assigns.group_pos, message.id, message.group_pos)
    )
  end

  defp restream_prev_group(socket, prev, new_pos) do
    prev = %{prev | group_pos: new_pos}

    socket
    |> stream_insert(:messages, prev)
    |> assign(group_pos: Map.put(socket.assigns.group_pos, prev.id, new_pos))
  end

  # Restore group_pos on a re-streamed row (a reaction/thumbnail broadcast carries none), from
  # what we recorded when the row was first streamed — so the merged bubble keeps its shape.
  defp restore_group_pos(socket, message),
    do: %{message | group_pos: Map.get(socket.assigns.group_pos, message.id, message.group_pos)}

  # Re-fuse a merged file group after a member was deleted/hidden: refetch the group's still-visible
  # rows, recompute positions, and re-stream only those whose position changed — so a surviving
  # `:last` regains its time, a lone survivor drops to a normal bubble, a promoted `:first` regains
  # the sender name. A foreign row interleaving the group is the accepted edge (halves re-fuse on
  # reload). No-op for an ungrouped delete.
  defp reshape_group(socket, _conversation_id, nil), do: socket

  defp reshape_group(socket, conversation_id, group_id) do
    rows = Chat.list_group_messages(socket.assigns.current_scope, conversation_id, group_id)
    {marked, tail} = mark_group_pos(rows)

    socket =
      Enum.reduce(marked, socket, fn m, s ->
        cond do
          # Not in the loaded window (a group straddling the top pagination boundary): a
          # stream_insert would APPEND it out of order, so leave it — it renders right when
          # scrolled into view. group_pos tracks exactly the loaded rows, like `compacts`.
          not Map.has_key?(s.assigns.group_pos, m.id) ->
            s

          Map.get(s.assigns.group_pos, m.id) == m.group_pos ->
            s

          true ->
            s
            |> stream_insert(:messages, m)
            |> assign(group_pos: Map.put(s.assigns.group_pos, m.id, m.group_pos))
        end
      end)

    # Keep the tail tracker pointing at the group's new last member when this group WAS the tail,
    # so a later insert continues/breaks the run correctly (tail is nil if the group emptied out).
    case socket.assigns.last_group do
      {_sid, ^group_id, _prev, _pos} -> assign(socket, last_group: tail)
      _ -> socket
    end
  end

  # Drop a removed message's per-row render state so the maps don't accumulate stale ids over a
  # long-lived session (a small unbounded growth). Both maps only ever track loaded rows.
  defp forget_row(socket, message_id) do
    assign(socket,
      group_pos: Map.delete(socket.assigns.group_pos, message_id),
      compacts: Map.delete(socket.assigns.compacts, message_id)
    )
  end

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
  # Re-stream a single message wherever it lives: a top-level message into the main
  # stream, a thread reply into the open thread panel (and NEVER into the main stream
  # — that was the #104 bug where a reply's ready thumbnail leaked into the room).
  # Shared by reaction + thumbnail re-renders.
  #
  # Stream a genuinely-new message into the open conversation (gated by `open?/2` in the
  # {:new_message} handler, #260). Marks read only in a foreground tab (#206) and keeps a
  # room's compact run continuous.
  defp stream_new_message(socket, message) do
    if message.sender_id != socket.assigns.current_scope.user.id and socket.assigns.tab_visible do
      Chat.mark_read(socket.assigns.current_scope, message.conversation_id)
    end

    # Room flat layout: continue/break the compact run live. DM: continue/break the grouped-file
    # merged-bubble run (rooms don't merge file bubbles — that's the threads phase).
    {message, socket} =
      case socket.assigns.selected do
        %{channel_id: cid} when not is_nil(cid) ->
          marked = %{message | compact: compact?(message, socket.assigns.last_flat)}
          {marked, assign(socket, last_flat: {message.sender_id, message.inserted_at})}

        _ ->
          mark_group_new(socket, message)
      end

    {:noreply,
     socket
     # The sender just sent — they're no longer typing, so clear them now rather
     # than waiting out the TTL (#11).
     |> drop_typing(:typing_users, message.sender_id)
     |> assign(compacts: Map.put(socket.assigns.compacts, message.id, message.compact))
     |> stream_insert(:messages, message)
     # #136: keep an open profile gallery live — surface the message's matching-kind media.
     |> maybe_prepend_gallery(message)}
  end

  # A tombstone reaching here (a re-render racing a delete-for-both) must not be
  # re-inserted — {:message_deleted} already removed the row.
  defp restream_message_in_place(socket, %{deleted_at: deleted} = _message, _root)
       when not is_nil(deleted),
       do: socket

  defp restream_message_in_place(socket, %{root_id: nil} = message, root) do
    # Only stream_insert a main-stream message that's actually in the loaded window (#260):
    # a reaction / thumbnail on a message scrolled out of view would otherwise insert a NEW
    # dom id at the bottom, duplicating it out of order. It renders right when scrolled back
    # in. ({:message_edited} already gates this way.)
    socket =
      if Map.has_key?(socket.assigns.compacts, message.id) do
        stream_insert(
          socket,
          :messages,
          restore_group_pos(socket, restore_compact(socket, message))
        )
      else
        socket
      end

    # The open thread panel's root card updates regardless of the main-stream window.
    if root && root.id == message.id, do: assign(socket, thread_root: message), else: socket
  end

  defp restream_message_in_place(socket, %{root_id: root_id} = message, %{id: root_id}),
    do: stream_insert(socket, :thread, message)

  # A reply whose thread isn't open (or a message for another conversation): nothing
  # on screen to update — crucially, do NOT fall back to the main stream.
  defp restream_message_in_place(socket, _message, _root), do: socket

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
    # Jumping to a message (a search result, a permalink) means "found it" — close any
    # open search so its panel/results don't linger. select_conversation already clears
    # the in-room search on a real switch, but a jump to a message in the ALREADY-open
    # room/DM short-circuits that guard, so clear all three search states here.
    socket =
      assign(socket,
        search: "",
        search_results: nil,
        channel_search: "",
        channel_results: nil,
        room_search_open: false,
        room_search: "",
        room_results: nil
      )

    case Chat.thread_root_for(socket.assigns.current_scope, message_id) do
      {:ok, root_id} ->
        socket
        |> open_thread(root_id)
        |> push_event("focus_message", %{domId: "thread-#{message_id}"})

      _ ->
        # Main-stream target: load a window around it first so an OLDER message (past the
        # loaded page) is actually rendered, then mark it for the hook to scroll to (the
        # data-focus-* path keeps the hook from re-pinning to the bottom over the jump).
        socket
        |> maybe_load_around(message_id)
        |> assign_focus(message_id)
    end
  end

  # A thread selection is bound to the open thread — drop it when the thread opens/closes/switches
  # (a main-stream selection is left alone).
  defp reset_thread_select(%{assigns: %{select_surface: :thread}} = socket),
    do: assign(socket, selection: nil, sel_delete: nil, select_surface: nil)

  defp reset_thread_select(socket), do: socket

  # Tear down the open thread panel (composer, staged attachments, typing, search). Does NOT
  # touch a selection — callers decide (close_thread drops it, forward_selection kept the carry).
  defp close_thread_panel(socket) do
    socket
    |> cancel_staged_thread_attachments()
    |> clear_thread_typing()
    |> assign(thread_root: nil, thread_reply_to: nil, thread_editing: nil)
    |> reset_thread_search()
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
        |> cancel_staged_thread_attachments()
        |> assign(
          thread_root: root,
          thread_following: following,
          thread_unreads: Map.put(socket.assigns.thread_unreads, root.id, 0),
          thread_last_flat: thread_last_flat,
          reply_composer: to_form(%{"body" => ""}, as: "reply"),
          # Fresh thread → clear a quote-reply staged in the previously-open one; without
          # this it would silently carry over (same conversation, so it'd validate).
          thread_reply_to: nil,
          # Fresh thread → drop any edit staged against the previously-open thread's reply.
          thread_editing: nil,
          # Fresh thread → no stale typers from a previously-open one (#103).
          thread_typing_users: %{},
          last_thread_typing_at: nil
        )
        |> reset_thread_select()
        |> stream(:thread, replies, reset: true)
        |> restream_root_if_loaded(root)
        # Fresh thread (or a jump to a thread-search result) → search starts closed (#189).
        |> reset_thread_search()

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
  # #164: keep an open thread panel's root header live when the root message itself is edited
  # (it renders from @thread_root, not the :messages stream).
  defp maybe_update_thread_root(socket, %{id: mid} = message) do
    case socket.assigns.thread_root do
      %{id: ^mid} -> assign(socket, thread_root: message)
      _ -> socket
    end
  end

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

  # A group's auto name lists its CURRENT members (a removed/left member must not linger
  # in it — #165). For a 1:1, the peer can carry a transient `left_at` (they "deleted" the
  # chat but re-surface), so the DM title path below uses the unfiltered `others/2`.
  defp title(%{is_group: true} = conversation, user) do
    conversation
    |> active_members()
    |> Enum.reject(&(&1.user_id == user.id))
    |> Enum.map_join(", ", & &1.user.display_name)
  end

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

  # The panel's "peer" (#136): the full User (with bio) for a DM, nil for a group (rendered
  # from @selected's memberships). Derived from the OPEN conversation, so a client-sent id
  # can't make the card describe someone other than this chat (P2-A).
  defp panel_peer(_scope, %{is_group: true}), do: {:ok, nil}

  defp panel_peer(scope, conversation) do
    case peer(conversation, scope.user) do
      %{id: peer_id} -> Chat.get_shared_user(scope, peer_id)
      _ -> {:error, :no_peer}
    end
  end

  # Load the first page of the per-dialog gallery (#136) for one tab kind into the panel; a
  # non-member/foreign conversation yields an empty list → the panel shows its empty state.
  defp load_gallery(%{assigns: %{selected: %{id: conv_id}, current_scope: scope}} = socket, kind) do
    media = fetch_gallery(scope, conv_id, kind, nil)
    assign(socket, gallery_tab: kind, gallery_media: media, gallery_more: full_page?(media))
  end

  defp load_gallery(socket, kind),
    do: assign(socket, gallery_tab: kind, gallery_media: [], gallery_more: false)

  # Append the next page below the oldest loaded item (cursor = its attachment id).
  defp load_more_gallery(
         %{
           assigns: %{
             selected: %{id: conv_id},
             current_scope: scope,
             gallery_tab: kind,
             gallery_media: media
           }
         } =
           socket
       ) do
    case media |> List.last() |> then(&(&1 && &1.id)) do
      nil ->
        socket

      cursor ->
        page = fetch_gallery(scope, conv_id, kind, cursor)
        assign(socket, gallery_media: media ++ page, gallery_more: full_page?(page))
    end
  end

  defp load_more_gallery(socket), do: socket

  defp fetch_gallery(scope, conv_id, kind, before) do
    opts = if before, do: [limit: @gallery_page, before: before], else: [limit: @gallery_page]

    case Chat.list_conversation_media(scope, conv_id, kind, opts) do
      {:ok, list} -> list
      _ -> []
    end
  end

  # A full page means there MAY be more — drives the "Load more" affordance.
  defp full_page?(list), do: length(list) == @gallery_page

  # Live-update the open gallery (#136): prepend a new message's attachments of the active
  # tab kind (newest first, deduped). Only for the conversation the panel is open for.
  defp maybe_prepend_gallery(
         %{
           assigns: %{
             profile_open: true,
             selected: %{id: cid},
             gallery_tab: kind,
             gallery_media: media
           }
         } =
           socket,
         %{conversation_id: cid} = message
       ) do
    atts = if is_list(message.attachments), do: message.attachments, else: []
    seen = MapSet.new(media, & &1.id)

    fresh =
      atts
      |> Enum.filter(&(&1.kind == kind and not MapSet.member?(seen, &1.id)))
      |> Enum.sort_by(& &1.id, :desc)

    if fresh == [], do: socket, else: assign(socket, gallery_media: fresh ++ media)
  end

  defp maybe_prepend_gallery(socket, _message), do: socket

  # Live-update the open gallery (#136): drop a deleted message's attachments.
  defp maybe_drop_gallery(
         %{assigns: %{profile_open: true, gallery_media: media}} = socket,
         message
       ) do
    assign(socket, gallery_media: Enum.reject(media, &(&1.message_id == message.id)))
  end

  defp maybe_drop_gallery(socket, _message), do: socket

  defp member_count(conversation), do: length(active_members(conversation))

  # A group's current members — a removed/left member keeps a row (left_at set) but must
  # drop out of the roster, the count, and the role/action matrix (#165).
  defp active_members(%{memberships: ms}) when is_list(ms),
    do: Enum.filter(ms, &is_nil(&1.left_at))

  defp active_members(_conversation), do: []

  # Avatar image URL for a user, cache-busted by the avatar key (nil → initials).
  defp avatar_src(%{avatar_key: key, id: id}) when is_binary(key),
    do: ~p"/users/#{id}/avatar?v=#{:erlang.phash2(key)}"

  defp avatar_src(_user), do: nil

  # Avatar image URL for a group (#178), cache-busted by the avatar key (nil → initials).
  defp group_avatar_src(%{id: id, avatar_key: key}) when is_binary(key),
    do: ~p"/conversations/#{id}/avatar?v=#{:erlang.phash2(key)}"

  defp group_avatar_src(_conversation), do: nil

  # The avatar a conversation shows: a group's own photo (#178), else the DM peer's.
  defp conversation_avatar_src(%{is_group: true} = conv, _user), do: group_avatar_src(conv)
  defp conversation_avatar_src(conv, user), do: avatar_src(peer(conv, user))

  defp group_avatar_error(:too_large), do: gettext("That image is too large (up to 5 MB).")
  defp group_avatar_error(:not_accepted), do: gettext("Use a JPEG, PNG, GIF or WebP image.")
  defp group_avatar_error(:too_many_files), do: gettext("Pick a single image.")
  defp group_avatar_error(:unprocessable), do: gettext("Couldn't process that image.")
  defp group_avatar_error(_other), do: gettext("Couldn't upload that image.")

  defp initials(name), do: name |> String.first() |> String.upcase()

  # Presence status of a 1:1's other participant (nil for groups / offline), used
  # to color the avatar dot + header label (#102).
  defp peer_status(%{is_group: true}, _user, _statuses), do: nil

  defp peer_status(conversation, user, statuses) do
    case others(conversation, user) do
      [other | _] -> Map.get(statuses, other.id)
      [] -> nil
    end
  end

  # Effective presence status of a specific user id (nil = offline/untracked).
  defp status_of(user_id, statuses), do: Map.get(statuses, user_id)

  # status_label/1 + status_color_var/1 are shared via EdenWeb.PresenceHelpers.

  # Ids of a room's members, to scope the presence map exposed to its clients
  # (#102 review): only the people in this room, never the global online set.
  defp room_member_ids(%{memberships: m}) when is_list(m), do: Enum.map(m, & &1.user_id)
  defp room_member_ids(_conversation), do: []

  # Auto-away (#102): idle changes only affect "auto" users (manual statuses ignore
  # idle), so skip the presence write — and the diff it fans — for the rest.
  defp maybe_apply_idle(socket) do
    if socket.assigns.my_status == "auto", do: apply_presence(socket), else: socket
  end

  # Push this session's effective status (from manual choice + idle) to presence.
  defp apply_presence(%{assigns: %{current_scope: %{user: user}} = a} = socket) do
    EdenWeb.Presence.apply_effective(
      self(),
      user.id,
      EdenWeb.Presence.effective(a.my_status, a.idle?)
    )

    socket
  end

  # The rail self-dot status: keep "invisible" (a hollow dot you always see), else
  # the effective status incl. auto-away — so your own dot matches how others see
  # you while idle (#102).
  defp rail_dot_status("invisible", _idle?), do: "invisible"
  defp rail_dot_status(manual, idle?), do: EdenWeb.Presence.effective(manual, idle?)

  # Record "last seen" whenever the user is online and not invisible. Idle doesn't
  # matter — an idle-but-connected user is still "в сети", and "last seen" means
  # last ONLINE, not last actively-used (#102 review). Invisible never touches, so
  # it can't leak recent activity the user is hiding.
  defp touch_if_visible(%{assigns: %{my_status: manual, current_scope: %{user: u}}} = socket) do
    if manual != "invisible", do: Accounts.touch_last_active(u.id)
    socket
  end

  # When the open 1:1's peer goes offline while we're watching, stamp their
  # last_active_at to now in-memory so the header reads "last seen <now>" — without
  # racing the DB write handle_metas does on the same leave (#102). Peers already
  # offline at open use their persisted last_active_at instead.
  # Reload the open conversation's memberships (roles + roster) after a group change
  # (#165), so the profile panel re-renders without a full navigation.
  defp reload_selected_members(socket) do
    case Chat.get_conversation(socket.assigns.current_scope, socket.assigns.selected.id) do
      {:ok, conv} ->
        assign(socket, selected: %{socket.assigns.selected | memberships: conv.memberships})

      _ ->
        socket
    end
  end

  defp stamp_peer_offline(socket, changed) do
    selected = socket.assigns.selected
    user = socket.assigns.current_scope.user

    peer =
      selected && not selected.is_group && is_nil(selected.channel_id) && peer(selected, user)

    if peer && peer.id in changed && is_nil(Map.get(socket.assigns.statuses, peer.id)) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      memberships = Enum.map(selected.memberships, &stamp_membership(&1, peer.id, now))
      assign(socket, selected: %{selected | memberships: memberships})
    else
      socket
    end
  end

  defp stamp_membership(%{user_id: id} = m, id, now),
    do: %{m | user: %{m.user | last_active_at: now}}

  defp stamp_membership(m, _peer_id, _now), do: m

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

  # After a media send (success OR failure), clear the overlay caption but KEEP the
  # chat input (message[body]) — they're separate entities (the caption rides
  # message[caption]). Dropping the caption key resets it; preserving body lets text
  # typed before staging media survive for a later send, and stops a consumed-but-failed
  # send from pre-filling the next media's caption.
  defp clear_media_caption(socket) do
    body = socket.assigns.composer[:body].value || ""
    assign(socket, composer: to_form(%{"body" => body}, as: "message"))
  end

  # Conversation switch: drop only STAGED attachments (#89) — they belong to the chat
  # they were composed in. An in-flight send (sending_media) is left running so it
  # finishes in the background and lands in its pinned conversation; leaving mid-upload
  # must not lose the media.
  defp drop_staged_on_switch(%{assigns: %{sending_media: true}} = socket), do: socket
  defp drop_staged_on_switch(socket), do: cancel_staged_attachments(socket)

  # Entries that still count as "staged content" for the composer. A cancelled
  # in-flight upload does NOT leave `entries`: Phoenix marks it `cancelled?: true`
  # and keeps it until the upload channel terminates (which, for a file cancelled
  # mid-batch, can be never). So every "is anything staged?" check must skip
  # cancelled entries — otherwise the lingering ghost keeps the composer bar
  # `inert`, leaving the paperclip dead after a partial-batch cancel (#158).
  defp live_entries(%{entries: entries}), do: Enum.reject(entries, & &1.cancelled?)

  # Auto-upload progress for the dedicated Resend channel (#…). auto_upload uploads each cloned
  # File the instant it stages; once EVERY entry is done, consume them into one message via
  # send_retry. While still uploading, drive the retrying card's ring by its pending client_id —
  # this ALSO re-arms the client stall watchdog on every tick (#310 review P1), so a large file on
  # a slow link isn't killed by the flat 90s cap; a genuinely stuck retry gets no ticks and the
  # watchdog fires retry_reset.
  defp handle_retry_progress(:attachment_retry, _entry, socket) do
    entries = live_entries(socket.assigns.uploads.attachment_retry)
    cid = socket.assigns.pending_retry && socket.assigns.pending_retry.client_id

    cond do
      entries == [] ->
        {:noreply, socket}

      Enum.all?(entries, & &1.done?) ->
        send_retry(socket)

      cid ->
        pct = round(Enum.sum(Enum.map(entries, & &1.progress)) / length(entries))
        {:noreply, push_event(socket, "media_progress", %{percent: pct, id: cid})}

      true ->
        {:noreply, socket}
    end
  end

  # Consume the finished :attachment_retry entries into one message, mirroring send_attachment but
  # for a retry: a single optimistic client_id (the retry re-sends ONE failed message — an album,
  # a lone photo/video, or a file). The caption rides a media album; a file re-sends plain. On
  # success the message streams in and its client_id swaps the retrying card; retry_done tells the
  # client either way. pending_retry is captured at retry_prepare, so the conversation is stable.
  defp send_retry(%{assigns: %{pending_retry: nil}} = socket), do: {:noreply, socket}

  # Same false positive as send_attachment: `path` is the LiveView upload temp, `stable` is
  # tmp_dir + the entry's server-side uuid — neither is user input.
  # sobelow_skip ["Traversal.FileModule"]
  defp send_retry(%{assigns: %{pending_retry: pending}} = socket) do
    %{client_id: cid, caption: caption, as_file: as_file, media: media?, conversation_id: conv_id} =
      pending

    sources =
      socket.assigns.uploads.attachment_retry.entries
      |> Enum.filter(& &1.done?)
      |> Enum.map(fn entry ->
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          stable = Path.join(System.tmp_dir!(), "eden-retry-" <> entry.uuid)
          File.cp!(path, stable)
          # A media album stamps its client_id at the album level (opts); a file at the source.
          {:ok,
           %{path: stable, filename: entry.client_name, client_id: if(media?, do: nil, else: cid)}}
        end)
      end)

    socket = assign(socket, pending_retry: nil)

    case sources do
      [] ->
        {:noreply, push_event(socket, "retry_done", %{id: cid, ok: false})}

      sources ->
        opts = %{
          body: if(media?, do: caption, else: ""),
          as_file: as_file,
          client_id: if(media?, do: [cid], else: nil),
          # Files inherit the send's group_id so the resent row rejoins its merged bubble; a media
          # album carries none (albums don't group). pending.group_id is already nil for albums.
          group_id: if(media?, do: nil, else: pending.group_id)
        }

        result = Chat.create_attachments(socket.assigns.current_scope, conv_id, sources, opts)
        Enum.each(sources, &File.rm(&1.path))

        # No flash on failure (#310 review P3): the card re-marking itself failed (retry_done ok:
        # false → Resend/Delete return) is the single, in-place signal — a flash would double it.
        {:noreply, push_event(socket, "retry_done", %{id: cid, ok: match?({:ok, _}, result)})}
    end
  end

  # Cancel the pristine :attachment_retry entries (#…): clean slate before a retry_prepare and on
  # a stalled-retry retry_reset, so a paste/queue that leaked in or an orphaned prior retry can't
  # ride into send_retry's consume. live_entries only — a cancelled ghost must never be re-cancelled
  # (it would GenServer.call a dead upload channel and crash the view, the #309-review race).
  defp cancel_retry_entries(socket) do
    Enum.reduce(live_entries(socket.assigns.uploads.attachment_retry), socket, fn entry, acc ->
      cancel_upload(acc, :attachment_retry, entry.ref)
    end)
  end

  ## Sequential send engine (TG-attachments) — one item at a time on :attachment_seq.

  # Progress for the item currently feeding. At most one entry is ever in flight (the client
  # feeds the next only after seq_done), so the entry IS `seq_pending`. Not done → drive the
  # optimistic node's ring (a file by its own client_id, an album photo by the album's node,
  # aggregating completed-in-album + this photo); done → consume it and pump the next.
  defp handle_seq_progress(:attachment_seq, entry, socket) do
    pending = socket.assigns.seq_pending
    queue = pending && Enum.find(socket.assigns.send_queues, &(&1.queue_id == pending.queue_id))

    cond do
      is_nil(pending) or is_nil(queue) -> {:noreply, socket}
      not entry.done? -> seq_tick(socket, entry, pending, queue)
      pending.kind == :file -> seq_settle_file(socket, entry, pending, queue)
      true -> seq_settle_media(socket, entry, pending, queue)
    end
  end

  defp seq_tick(socket, entry, pending, queue) do
    {id, pct} = seq_progress_of(entry, pending, queue)

    if pct == Map.get(socket.assigns.last_file_pct, id) do
      {:noreply, socket}
    else
      socket = assign(socket, last_file_pct: Map.put(socket.assigns.last_file_pct, id, pct))
      {:noreply, push_event(socket, "seq_progress", %{percent: pct, id: id})}
    end
  end

  # A file drives its own card by client_id; an album photo drives the album node, blending the
  # photos already done in that album with this one's progress so the single ring climbs smoothly.
  defp seq_progress_of(entry, %{kind: :file, client_id: cid}, _queue),
    do: {cid, ceil(entry.progress)}

  # Per-PHOTO progress (phase D): drive the tile keyed by the photo's own client_id (each album
  # tile has its own ring), not an aggregate on the album node.
  defp seq_progress_of(entry, %{kind: :media, client_id: cid}, _queue),
    do: {cid, ceil(entry.progress)}

  # A file finishes → post it as its own message (stamped with the send's group_id so its row
  # joins the merged bubble), decrement the queue's file counter, and — when it was the LAST file
  # of a files-only send — pull the caption down as a trailing message. Then free the slot and
  # pump the next item.
  defp seq_settle_file(socket, entry, pending, queue) do
    scope = socket.assigns.current_scope
    source = consume_seq_entry(socket, entry, pending.client_id)

    result =
      Chat.create_attachments(scope, queue.conv_id, [source], %{
        client_id: pending.client_id,
        group_id: queue.group_id,
        # A root_id (phase F) routes the file to a thread REPLY under it instead of the main stream.
        root_id: queue.root_id
      })

    File.rm(source.path)

    socket =
      case result do
        {:ok, _} ->
          socket

        {:error, reason} ->
          socket
          |> put_flash(:error, attachment_error(reason))
          |> push_media_failed(pending.client_id)
      end

    queue = %{queue | files_left: queue.files_left - 1}
    {socket, queue} = maybe_trailing_caption(socket, scope, queue)

    socket
    |> put_queue(queue)
    |> assign(
      seq_pending: nil,
      last_file_pct: Map.delete(socket.assigns.last_file_pct, pending.client_id)
    )
    |> finalize_queue_if_done(queue)
    |> push_event("seq_done", %{id: pending.client_id})
    |> then(&{:noreply, &1})
  end

  # An album photo finishes → accumulate it; when the album has all its photos, post the ONE
  # album message (the caption rides the FIRST album of the send). Albums are removed from the
  # queue as they complete, so the queue is "done" once no album and no file remains.
  defp seq_settle_media(socket, entry, pending, queue) do
    acid = pending.album_cid
    spec = Map.get(queue.albums, acid, %{expected: 1, sources: []})
    source = consume_seq_media(socket, entry)
    spec = %{spec | sources: spec.sources ++ [source]}

    {socket, queue} =
      if length(spec.sources) >= spec.expected do
        commit_album(socket, queue, acid, spec)
      else
        {socket, %{queue | albums: Map.put(queue.albums, acid, spec)}}
      end

    socket
    |> put_queue(queue)
    |> assign(
      seq_pending: nil,
      last_file_pct: Map.delete(socket.assigns.last_file_pct, pending.client_id)
    )
    |> finalize_queue_if_done(queue)
    |> push_event("seq_done", %{id: pending.client_id})
    |> then(&{:noreply, &1})
  end

  # Post the ONE album message from its accumulated sources (the caption rides the FIRST album of
  # the send); a failed album marks its optimistic node failed (retriable). Returns {socket, queue}
  # with the album removed from the queue. Shared by the completion path and the per-photo-cancel
  # path (when a cancel makes the remaining photos already-complete).
  # sobelow_skip ["Traversal.FileModule"]
  defp commit_album(socket, queue, acid, spec) do
    {caption, caption_used} =
      if not queue.caption_used and queue.caption != "",
        do: {queue.caption, true},
        else: {"", queue.caption_used}

    opts = %{body: caption, client_id: [acid], as_file: queue.as_file, root_id: queue.root_id}

    result =
      Chat.create_attachments(socket.assigns.current_scope, queue.conv_id, spec.sources, opts)

    Enum.each(spec.sources, &File.rm(&1.path))

    socket =
      case result do
        {:ok, _} ->
          socket

        {:error, reason} ->
          socket |> put_flash(:error, attachment_error(reason)) |> push_media_failed(acid)
      end

    {socket, %{queue | albums: Map.delete(queue.albums, acid), caption_used: caption_used}}
  end

  # Files-only caption: the last file drops it as a trailing message below the pile (the album
  # path carries the caption inline instead, so this only fires when there are no albums).
  defp maybe_trailing_caption(socket, scope, queue) do
    if queue.files_left <= 0 and not is_nil(queue.caption_id) and queue.caption != "" and
         not queue.caption_used and queue.albums == %{} do
      {send_trailing_caption(
         socket,
         scope,
         queue.conv_id,
         queue.caption,
         queue.caption_id,
         queue.root_id
       ), %{queue | caption_used: true}}
    else
      {socket, queue}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp consume_seq_entry(socket, entry, cid) do
    consume_uploaded_entry(socket, entry, fn %{path: path} ->
      stable = Path.join(System.tmp_dir!(), "eden-seq-" <> entry.uuid)
      File.cp!(path, stable)
      {:ok, %{path: stable, filename: entry.client_name, client_id: cid}}
    end)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp consume_seq_media(socket, entry) do
    consume_uploaded_entry(socket, entry, fn %{path: path} ->
      stable = Path.join(System.tmp_dir!(), "eden-seq-" <> entry.uuid)
      File.cp!(path, stable)
      {:ok, %{path: stable, filename: entry.client_name, client_id: nil}}
    end)
  end

  defp put_queue(socket, queue) do
    assign(
      socket,
      send_queues:
        Enum.map(
          socket.assigns.send_queues,
          &if(&1.queue_id == queue.queue_id, do: queue, else: &1)
        )
    )
  end

  # A queue with no pending album and no remaining file is finished — drop it and, if that was
  # the last live queue, clear the in-flight send state (mirrors settle_ready_file's cleanup).
  defp finalize_queue_if_done(socket, queue) do
    if queue.albums == %{} and queue.files_left <= 0 do
      socket
      |> assign(
        send_queues: Enum.reject(socket.assigns.send_queues, &(&1.queue_id == queue.queue_id))
      )
      |> maybe_end_sending()
    else
      socket
    end
  end

  defp maybe_end_sending(socket) do
    if socket.assigns.send_queues == [] and socket.assigns.seq_pending == nil do
      socket
      |> clear_media_caption()
      |> assign(sending_media: false, last_media_pct: nil, reply_to: nil, last_typing_at: nil)
    else
      socket
    end
  end

  defp drop_pending_from_queue(socket, nil), do: socket

  defp drop_pending_from_queue(socket, pending),
    do: drop_queue_item(socket, pending.queue_id, pending.kind, pending.album_cid)

  # Remove one skipped/cancelled item from its queue's accounting so the queue can still finalize:
  # a file decrements files_left; an album photo drops the WHOLE album (its optimistic node is
  # marked failed as a unit in phase C — per-photo album cancel is a later phase), reclaiming any
  # temps it accumulated.
  # sobelow_skip ["Traversal.FileModule"]
  defp drop_queue_item(socket, nil, _kind, _album_cid), do: socket

  defp drop_queue_item(socket, queue_id, kind, album_cid) do
    case Enum.find(socket.assigns.send_queues, &(&1.queue_id == queue_id)) do
      nil ->
        socket

      queue ->
        case kind do
          :file ->
            queue = %{queue | files_left: max(queue.files_left - 1, 0)}
            socket |> put_queue(queue) |> finalize_queue_if_done(queue)

          :media ->
            drop_album_photo(socket, queue, album_cid)
        end
    end
  end

  # One album photo cancelled/stalled (phase D — per-tile cancel): decrement its album's expected.
  # If the album emptied → drop it (reclaim temps). If the remaining photos have ALL already
  # uploaded → commit the (smaller) album now. Else keep waiting for the rest. Then finalize.
  # sobelow_skip ["Traversal.FileModule"]
  defp drop_album_photo(socket, queue, album_cid) do
    case Map.get(queue.albums, album_cid) do
      nil ->
        socket |> put_queue(queue) |> finalize_queue_if_done(queue)

      spec ->
        new_expected = spec.expected - 1

        {socket, queue} =
          cond do
            new_expected <= 0 ->
              Enum.each(spec.sources, &File.rm(&1.path))
              {socket, %{queue | albums: Map.delete(queue.albums, album_cid)}}

            length(spec.sources) >= new_expected ->
              commit_album(socket, queue, album_cid, %{spec | expected: new_expected})

            true ->
              {socket,
               %{
                 queue
                 | albums: Map.put(queue.albums, album_cid, %{spec | expected: new_expected})
               }}
          end

        socket |> put_queue(queue) |> finalize_queue_if_done(queue)
    end
  end

  # Abort the in-flight :attachment_seq entry (stall skip). live_entries only — a cancelled ghost
  # must never be re-cancelled (dead-channel GenServer.call crash, the #309 race).
  defp cancel_seq_entries(socket) do
    Enum.reduce(live_entries(socket.assigns.uploads.attachment_seq), socket, fn entry, acc ->
      cancel_upload(acc, :attachment_seq, entry.ref)
    end)
  end

  # A queue_start supersedes the staged tray (the client re-feeds clones into :attachment_seq),
  # so cancel those staged entries. Staged-only cancel is the safe path. A thread send (phase F,
  # root_id) staged its tray on :thread_attachment; the main composer on :attachment — cancel the
  # one this send superseded so the OTHER composer's tray (if any) is left untouched.
  defp cancel_seq_staged(socket, root_id) do
    upload = if root_id, do: :thread_attachment, else: :attachment

    # Both configs are declared unconditionally in mount, so this is always present — but guard
    # anyway so a future refactor that drops one can't crash the LiveView from a queue_start event.
    case socket.assigns.uploads[upload] do
      nil ->
        socket

      config ->
        Enum.reduce(live_entries(config), socket, fn entry, acc ->
          cancel_upload(acc, upload, entry.ref)
        end)
    end
  end

  # Client-supplied album plan → %{album_cid => %{expected, sources: []}}. Bounded and typed so a
  # crafted payload can't grow the stash or smuggle non-binaries into a client_id.
  defp build_album_specs(albums) when is_list(albums) do
    for spec <- Enum.take(albums, 16),
        is_map(spec),
        cid = spec["cid"],
        is_binary(cid) and byte_size(cid) <= 64,
        count = spec["count"],
        is_integer(count) and count > 0,
        into: %{},
        do: {cid, %{expected: min(count, Chat.max_album_entries()), sources: []}}
  end

  defp build_album_specs(_), do: %{}

  defp sanitize_cid(cid) when is_binary(cid) and byte_size(cid) <= 64, do: cid
  defp sanitize_cid(_), do: nil

  # A thread root id (phase F) is a positive integer message id; anything else → nil (main stream).
  # The reply path (Chat.create_album_reply) re-validates access + threading, so a forged id fails
  # the send rather than posting anywhere unauthorized.
  defp sanitize_root_id(id) when is_integer(id) and id > 0, do: id
  defp sanitize_root_id(_), do: nil

  # A client-supplied group_id is only accepted if it's a well-formed UUID (else nil) — it can't
  # forge cross-user grouping (rendering needs same-sender adjacency), but this keeps a malformed
  # value out of the Ecto.UUID column.
  defp sanitize_group_id(v) when is_binary(v) do
    case Ecto.UUID.cast(v) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp sanitize_group_id(_), do: nil

  # Reuse the send's original group_id on resume (phase E) when the caller owns that group (so a
  # resumed row rejoins its bubble); otherwise mint a fresh one for a multi-file send.
  defp resolve_resume_group_id(scope, conversation_id, raw, file_cids) do
    case sanitize_group_id(raw) do
      nil ->
        mint_group_id(file_cids)

      group_id ->
        if Chat.group_owned_by?(scope, conversation_id, group_id),
          do: group_id,
          else: mint_group_id(file_cids)
    end
  end

  defp mint_group_id(file_cids),
    do: if(length(file_cids) >= 2, do: Ecto.UUID.generate(), else: nil)

  # Cancel every staged attachment upload (the composer tray) + reset the send flags.
  # Used by the explicit "clear tray"/Escape action and, via drop_staged_on_switch,
  # on a conversation switch when nothing is in flight.
  defp cancel_staged_attachments(socket) do
    socket
    |> then(fn s ->
      # live_entries only (#309 review P1): re-cancelling an already-cancelled ghost would
      # GenServer.call its dead upload channel → LiveView crash on the double-fire stall race.
      Enum.reduce(live_entries(s.assigns.uploads.attachment), s, fn entry, acc ->
        cancel_upload(acc, :attachment, entry.ref)
      end)
    end)
    # A cleared tray or a conversation switch abandons the staged send, so drop the
    # sending flag + any queued client_ids + the progress gate (#95) — else a stale
    # `true` hides the overlay next staging, or a stranded id mis-stamps a later
    # send. Runs on cancel_all_uploads + select_conversation.
    |> assign(sending_media: false, media_client_ids: [], last_media_pct: nil, last_file_pct: %{})
  end

  # Cancel ONE attachment entry (#137) — the tray X (before send) and the in-flight X on the
  # optimistic card share this. Abort the entry, drop its ref from the in-flight stash + the
  # progress gate. When that empties the upload, the cleanup depends on which X it was:
  # in-flight (a real send) clears sending_media + caption/reply/typing + the orphaned caption
  # node; a tray cancel keeps the reply (the user may still send a text reply).
  defp cancel_attachment_entry(socket, ref) do
    in_flight? = socket.assigns.sending_media
    # The trailing-caption node id of the files-only send that owns this ref, so cancelling
    # its LAST file can drop the now-orphaned caption node (#137 review P3-3).
    caption_id =
      Enum.find_value(socket.assigns.media_client_ids, fn {_a, _c, _conv, files, cid, _af} ->
        Map.has_key?(files, ref) && cid
      end)

    # `cancel_upload/3` raises on an unknown ref, so only touch entries still live in the
    # config — a stale ref (already cancelled by a stall's media_send_reset, or a late tap
    # after the entry finished) is a safe no-op, not a crash.
    known_ref? = Enum.any?(socket.assigns.uploads.attachment.entries, &(&1.ref == ref))

    socket =
      socket
      |> then(&if(known_ref?, do: cancel_upload(&1, :attachment, ref), else: &1))
      |> assign(
        media_client_ids: drop_ref_from_stash(socket.assigns.media_client_ids, ref),
        last_file_pct: Map.delete(socket.assigns.last_file_pct, ref)
      )

    cond do
      # Other live entries are still uploading — the completion path (settle_ready_file
      # / send_attachment) resets the flags when the last one lands. Cancelled ghosts
      # are excluded so the LAST active cancel still falls through to the reset (#158).
      live_entries(socket.assigns.uploads.attachment) != [] ->
        socket

      in_flight? ->
        # A real send was cancelled: re-enable the composer (sending_media), clear the
        # caption/reply/typing it carried, and drop the orphaned trailing-caption node.
        socket
        |> push_media_failed(caption_id)
        |> clear_media_caption()
        |> assign(sending_media: false, last_media_pct: nil, reply_to: nil, last_typing_at: nil)

      true ->
        # Tray cancel BEFORE send: the overlay closes (no media left) — clear only the
        # caption field; KEEP the reply (the user may still send a text reply) (#137 review P2-1).
        clear_media_caption(socket)
    end
  end

  # Remove an upload ref from whichever in-flight send owns it, dropping a stash entry that's
  # left with no files and no albums (#193: album_ids is a list — empty means no albums).
  defp drop_ref_from_stash(stash, ref) do
    stash
    |> Enum.map(fn {album_ids, caption, conv_id, files, caption_id, as_file} ->
      {album_ids, caption, conv_id, Map.delete(files, ref), caption_id, as_file}
    end)
    |> Enum.reject(fn {album_ids, _caption, _conv, files, _cid, _af} ->
      files == %{} and album_ids == []
    end)
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

  # #164: save an edit. Clears edit mode + the input, then calls edit_message (which
  # re-authorizes and broadcasts {:message_edited} — that updates the row everywhere,
  # incl. this session, so we don't touch the stream here). A blank text-only edit or a
  # forbidden/missing message surfaces a flash.
  defp save_edit(socket, body) do
    %{current_scope: scope, editing: %{id: id}} = socket.assigns

    case Chat.edit_message(scope, id, body) do
      {:ok, _edited} ->
        # Clear edit mode + the input ONLY on success, so a rejected edit (e.g. past the
        # 4000-char cap) keeps the banner + the typed text for the user to fix.
        {:noreply, socket |> assign(editing: nil) |> push_event("set_composer_body", %{body: ""})}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't save the edit."))}
    end
  end

  # Staged uploads are ready to consume: at least one entry, and every one finished. A
  # consume on an in-progress entry raises, so this gates every consume_uploaded_entries path.
  # A thread root that still has replies — delete_message_for_both refuses it, so the delete
  # dialog gates "for everyone" off when any selected message is one (#multiselect).
  defp root_with_replies?(%{root_id: nil, reply_count: n}) when is_integer(n) and n > 0, do: true
  defp root_with_replies?(_), do: false

  defp all_uploads_done?([]), do: false
  defp all_uploads_done?(entries), do: Enum.all?(entries, & &1.done?)

  # #164 text→media: an edit where the author attached media converts the (text) message into
  # a media message — consume the :attachment uploads into sources and hand them to
  # edit_message_media (kept=[]). The overlay caption (seeded with the edit text) becomes the
  # caption. Mirrors save_edit_media's temp cleanup; clears edit mode on success.
  #
  # Same false positive as send_attachment: `path` is the LiveView upload temp, `stable` the
  # tmp_dir + the entry's server-side uuid — neither is user input.
  # sobelow_skip ["Traversal.FileModule"]
  defp save_edit_to_media(socket, msg) do
    %{current_scope: scope, editing: %{id: id}} = socket.assigns
    caption = Map.get(msg, "caption", "")

    sources =
      consume_uploaded_entries(socket, :attachment, fn %{path: path}, entry ->
        stable = Path.join(System.tmp_dir!(), "eden-edit-upload-" <> entry.uuid)
        File.cp!(path, stable)
        {:ok, %{path: stable, filename: entry.client_name}}
      end)

    try do
      case Chat.edit_message_media(scope, id, [], sources, %{body: caption}) do
        {:ok, _edited} ->
          {:noreply,
           socket |> assign(editing: nil) |> push_event("set_composer_body", %{body: ""})}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, edit_media_error(reason))}
      end
    after
      Enum.each(sources, &File.rm(&1.path))
    end
  end

  # #164: same as save_edit, for a thread reply edited in the thread composer. The
  # {:message_edited} broadcast routes the updated reply to the :thread stream.
  defp save_thread_edit(socket, body) do
    %{current_scope: scope, thread_editing: %{id: id}} = socket.assigns

    case Chat.edit_message(scope, id, body) do
      {:ok, _edited} ->
        {:noreply,
         socket
         |> assign(thread_editing: nil)
         |> push_event("set_thread_composer_body", %{body: ""})}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't save the edit."))}
    end
  end

  # #164 text→media in a thread: attaching media while editing a text reply converts it to a
  # media reply — the reply input (its own caption) becomes the caption. Mirrors
  # save_edit_to_media; the {:message_edited} broadcast routes the row to the :thread stream.
  #
  # Same false positive as send_thread_album: `path` is the LiveView upload temp, `stable` the
  # tmp_dir + the entry's server-side uuid — neither is user input.
  # sobelow_skip ["Traversal.FileModule"]
  defp save_thread_edit_to_media(socket, caption) do
    %{current_scope: scope, thread_editing: %{id: id}} = socket.assigns

    sources =
      consume_uploaded_entries(socket, :thread_attachment, fn %{path: path}, entry ->
        stable = Path.join(System.tmp_dir!(), "eden-thread-edit-" <> entry.uuid)
        File.cp!(path, stable)
        {:ok, %{path: stable, filename: entry.client_name}}
      end)

    try do
      case Chat.edit_message_media(scope, id, [], sources, %{body: caption}) do
        {:ok, _edited} ->
          {:noreply,
           socket
           |> assign(thread_editing: nil)
           |> push_event("set_thread_composer_body", %{body: ""})}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, edit_media_error(reason))}
      end
    after
      Enum.each(sources, &File.rm(&1.path))
    end
  end

  # #164 PR-2: save a media edit. Consume the newly-staged photos into sources, gather the
  # still-kept attachment ids, and hand both to edit_message_media (which re-authorizes,
  # reclaims dropped blobs forward-safe, and broadcasts {:message_edited} — updating the row
  # everywhere incl. this session, so we don't touch the stream). Closes the modal on
  # success; a rejected edit keeps it open with a flash.
  #
  # Same false positive as send_attachment: `path` is the LiveView upload temp, `stable` the
  # tmp_dir + the entry's server-side uuid — neither is user input.
  # sobelow_skip ["Traversal.FileModule"]
  defp save_edit_media(socket, message_params) do
    %{current_scope: scope, edit_media: %{message: message, kept: kept}} = socket.assigns
    body = Map.get(message_params, "body", "")

    new_sources =
      consume_uploaded_entries(socket, :edit_media, fn %{path: path}, entry ->
        stable = Path.join(System.tmp_dir!(), "eden-edit-upload-" <> entry.uuid)
        File.cp!(path, stable)
        {:ok, %{path: stable, filename: entry.client_name}}
      end)

    try do
      case Chat.edit_message_media(scope, message.id, MapSet.to_list(kept), new_sources, %{
             body: body
           }) do
        {:ok, _edited} -> {:noreply, assign(socket, edit_media: nil)}
        {:error, reason} -> {:noreply, put_flash(socket, :error, edit_media_error(reason))}
      end
    after
      Enum.each(new_sources, &File.rm(&1.path))
    end
  end

  # kept ids seeded when the modal opens: every attachment, minus whatever the user removes.
  defp initial_kept_ids(%{attachments: attachments}), do: MapSet.new(attachments, & &1.id)

  defp cancel_all_edit_media_uploads(socket) do
    Enum.reduce(socket.assigns.uploads.edit_media.entries, socket, fn entry, acc ->
      cancel_upload(acc, :edit_media, entry.ref)
    end)
  end

  defp safe_int(v) when is_integer(v), do: v

  defp safe_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp edit_media_error(:empty), do: gettext("Keep or add at least one photo.")

  defp edit_media_error(:too_many),
    do: gettext("An album can hold at most %{count} items.", count: Chat.max_album_entries())

  defp edit_media_error(_), do: gettext("Couldn't save the edit.")

  defp send_dispatch(socket, body, msg) do
    %{current_scope: scope, selected: conversation} = socket.assigns
    client_id = msg["client_id"]
    reply_to_id = msg["reply_to_id"]

    # Cancelled-but-lingering ghosts (a file X'd mid-batch) are never "done?", so a
    # naive `Enum.all?(done?)` would wedge the send forever; ignore them (#158).
    entries = live_entries(socket.assigns.uploads.attachment)

    cond do
      # #164 text→media: an edit with staged media (all done) converts the message into a
      # media message — must precede the plain edit branch, else the media is stranded.
      socket.assigns.editing && all_uploads_done?(entries) ->
        save_edit_to_media(socket, msg)

      # #164: an active edit routes "send" to edit_message, not a new send.
      socket.assigns.editing ->
        save_edit(socket, body)

      is_nil(conversation) ->
        {:noreply, socket}

      # Consume ONLY once the upload has finished — the media's native form submit
      # fires "send" after every entry is done. A TEXT send that arrives WHILE the
      # video is still uploading (the SendQueue hook's queued "send") would otherwise
      # hit consume_uploaded_entries here, which RAISES on an in-progress entry and
      # crashes the LiveView — losing the upload + its optimistic node. Such a send
      # falls through to the text path; the upload keeps going and lands on its own
      # later "send" when every entry is done.
      all_uploads_done?(entries) ->
        # The client_id AND caption rode the socket (media_sending), captured by the hook
        # at submit — NOT the form/@composer. media_sending closes the overlay (removing
        # #compose-caption) before the form serializes, and a composer_changed during the
        # (slow) upload could clobber @composer[:caption], so both would be lost; carrying
        # them on the push keeps them intact. Pop the oldest queued pair to stamp this send
        # so its optimistic twin swaps out (#95). The chat input (message[body]) is left
        # untouched for a later text send.
        {{album_ids, caption, conv_id, file_cids, caption_id, as_file}, rest} =
          pop_media_client_id(socket.assigns.media_client_ids)

        socket = assign(socket, media_client_ids: rest)
        # Pinned conversation: the upload may have started in a chat the user has since
        # left (a mid-upload switch). Send it to that ORIGINAL conversation, not the
        # current one, so leaving doesn't lose the media or leak it into the new chat.
        # Falls back to the current conversation when no id was stashed (legacy/edge).
        # The id-triple (per-album client_ids + per-file cids + the files-only caption node)
        # travels as one `ids` tuple — finish_attachment already treats it as a unit — to
        # keep send_attachment within the arity budget once `as_file` (#122) is added.
        send_attachment(
          socket,
          scope,
          conv_id || conversation.id,
          caption,
          reply_to_id,
          {album_ids, file_cids, caption_id},
          as_file
        )

      String.trim(body) == "" ->
        {:noreply, assign(socket, composer: empty_composer())}

      true ->
        send_text(socket, scope, conversation.id, body, client_id, reply_to_id)
    end
  end

  defp send_reply_dispatch(socket, body, reply) do
    root = socket.assigns.thread_root
    reply_to_id = reply["reply_to_id"]
    client_id = reply["client_id"]
    entries = socket.assigns.uploads.thread_attachment.entries

    cond do
      # #164 text→media: editing a thread reply + attached media converts it to media (parity
      # with the main composer) — before the plain edit branch, else the media is stranded.
      socket.assigns.thread_editing && all_uploads_done?(entries) ->
        save_thread_edit_to_media(socket, body)

      # #164: an active thread-reply edit routes send_reply to edit_message, not a new reply.
      socket.assigns.thread_editing ->
        save_thread_edit(socket, body)

      is_nil(root) ->
        {:noreply, socket}

      # An album reply (#104): the attachments are the content, so an empty caption is OK.
      # Mirror the main composer (P0): consume only once every entry is done. The thread
      # composer submits normally (no optimistic typing during upload), so this is
      # always true in normal use — but it stops a crafted "send_reply" sent while an
      # attachment is still uploading from reaching consume_uploaded_entries, which
      # raises on an in-progress entry and crashes the LiveView.
      entries != [] and Enum.all?(entries, & &1.done?) ->
        send_thread_album(socket, root, body, reply_to_id)

      String.trim(body) == "" ->
        {:noreply, socket}

      true ->
        send_thread_reply_text(socket, root, body, reply_to_id, client_id)
    end
  end

  # Carry-and-drop: drop the carried message into `conversation_id` (or into a thread when
  # `root_id` is given). Clears the plaque + the client's sessionStorage on either outcome.
  # The forward plaque body: a single carried message shows its snippet; several show a count.
  defp forward_plaque_label([message]), do: reply_snippet(message)

  defp forward_plaque_label(messages),
    do: ngettext("%{count} message", "%{count} messages", length(messages))

  # Pick up messages to carry: fetch them (scoped, visible, oldest-first) and stash on
  # pending_forward, mirroring the ids to the client so the plaque survives navigation. An empty
  # result clears the plaque. Carrying clears the composer's edit/reply state.
  defp carry(socket, ids) do
    case Chat.get_messages(socket.assigns.current_scope, ids) do
      [] ->
        socket |> assign(pending_forward: nil) |> push_event("carry_clear", %{})

      messages ->
        socket
        |> assign(pending_forward: messages, editing: nil, reply_to: nil, thread_editing: nil)
        |> push_event("carry_set", %{ids: Enum.map(messages, & &1.id)})
    end
  end

  # Drop the carried messages into `conversation_id` (or a thread when `root_id` is given), in
  # order. Clears the plaque + the client's sessionStorage afterwards.
  defp drop_forward(socket, conversation_id, root_id \\ nil) do
    %{current_scope: scope, pending_forward: messages} = socket.assigns

    results =
      Enum.map(messages, fn m -> Chat.forward_message(scope, m.id, conversation_id, root_id) end)

    socket =
      socket
      |> assign(pending_forward: nil)
      |> push_event("carry_clear", %{})

    # No success flash: the copy lands visibly at the bottom of the open stream, so a
    # confirmation toast is just noise. Only a failure warrants interrupting.
    socket =
      if Enum.all?(results, &match?({:ok, _}, &1)),
        do: socket,
        else: put_flash(socket, :error, gettext("Couldn't forward that message."))

    {:noreply, socket}
  end

  defp send_text(socket, scope, conversation_id, body, client_id, reply_to_id) do
    attrs = %{"body" => body, "client_id" => client_id, "reply_to_id" => reply_to_id}

    case Chat.create_message(scope, conversation_id, attrs) do
      {:ok, _message} ->
        # Reset the composer assign on BOTH paths. The hook path (client_id) already cleared
        # the DOM input, but leaving the assign stale meant any form re-render (the forward /
        # reply plaque appearing) patched the unfocused textarea BACK to the last-sent text.
        # Typing during a slow round-trip is safe: LiveView never patches the focused input,
        # and composer_changed re-syncs the assign on every keystroke. A reply always clears
        # the tray.
        socket = assign(socket, composer: empty_composer())
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

  # Drive the in-flight ring(s) as upload chunks arrive (#95/#149). Two kinds of
  # entry fire here:
  #   * a media entry (image/video) feeds the album's SINGLE averaged ring,
  #     addressed by the album's client_id (the oldest queued — media sends are
  #     serialized, so that's the in-flight one);
  #   * a file entry (anything else) feeds its OWN per-file ring, addressed by the
  #     upload ref so each file card fills independently.
  # Each gates on the integer percent CHANGING (the album by its single percent,
  # files by a per-ref map) so a fat album/batch can't flood a slow link with
  # no-op frames. `ceil` lets each arc actually reach 100%.
  defp handle_attachment_progress(:attachment, entry, socket) do
    cond do
      media_entry?(entry) -> media_progress_or_flush(socket)
      # A file is sent the MOMENT its own upload finishes (#149), independent of the rest
      # of the batch — no waiting for the slowest doc before it becomes a real, clickable
      # card. consume_uploaded_entry only requires THIS entry to be done.
      entry.done? -> send_ready_file(socket, entry)
      true -> file_progress(socket, entry)
    end
  end

  # Drive the album ring — and, in a MIXED batch (album + files) where the album's own entries
  # are ALL done but a file is still lagging, SEND the album now instead of waiting for the
  # all-uploads-done form "send" (#…). Otherwise a file that stalls blocks the completed album,
  # and the stall abort then cancels the album's finished entries — silently discarding photos
  # that already uploaded (the reported bug). A pure-media send (no files) keeps the existing
  # all-done path unchanged; this only kicks in when files are the thing lagging.
  defp media_progress_or_flush(socket) do
    entries = live_entries(socket.assigns.uploads.attachment)
    media = Enum.filter(entries, &media_entry?/1)
    files = Enum.reject(entries, &media_entry?/1)

    if media != [] and Enum.all?(media, & &1.done?) and files != [] and
         not Enum.all?(files, & &1.done?),
       do: flush_ready_album(socket),
       else: media_album_progress(socket)
  end

  # Consume the done MEDIA entries into their album(s) and send them, leaving the file entries in
  # the config for their own send_ready_file / stall path. The stash entry keeps its files but
  # drops album_ids + caption (both rode the album), so once every file lands the files-only path
  # takes over. sending_media stays true (files still in flight) until the last file settles.
  # sobelow_skip ["Traversal.FileModule"] — File.rm on the server-side stable temp, not user input.
  defp flush_ready_album(socket) do
    case socket.assigns.media_client_ids do
      [{album_ids, caption, conv_id, files, caption_id, as_file} | rest] when album_ids != [] ->
        conversation_id = conv_id || selected_id(socket)
        sources = consume_done_media(socket)

        opts = %{body: caption, reply_to_id: nil, client_id: album_ids, as_file: as_file}
        _ = Chat.create_attachments(socket.assigns.current_scope, conversation_id, sources, opts)
        Enum.each(sources, &File.rm(&1.path))

        {:noreply,
         assign(socket,
           media_client_ids: [{[], "", conv_id, files, caption_id, as_file} | rest],
           last_media_pct: nil
         )}

      _ ->
        media_album_progress(socket)
    end
  end

  # Consume every done MEDIA (image/video) entry to a stable temp, leaving file entries untouched.
  # Same false positive as send_attachment: `path` is the LiveView upload temp, `stable` is
  # tmp_dir + the entry's server-side uuid — neither is user input.
  # sobelow_skip ["Traversal.FileModule"]
  defp consume_done_media(socket) do
    socket.assigns.uploads.attachment.entries
    |> Enum.filter(&(media_entry?(&1) and &1.done?))
    |> Enum.map(fn entry ->
      consume_uploaded_entry(socket, entry, fn %{path: path} ->
        stable = Path.join(System.tmp_dir!(), "eden-upload-" <> entry.uuid)
        File.cp!(path, stable)
        {:ok, %{path: stable, filename: entry.client_name, client_id: nil}}
      end)
    end)
  end

  defp media_album_progress(socket) do
    pct = overall_progress(socket.assigns.uploads)

    if pct == socket.assigns.last_media_pct do
      {:noreply, socket}
    else
      album_ids =
        case List.first(socket.assigns.media_client_ids) do
          {ids, _caption, _conv_id, _files, _caption_id, _af} -> List.wrap(ids)
          _ -> []
        end

      # Drive EVERY album's ring (#193): a big pick is several albums sharing one upload, so
      # the overall % fills each batch's optimistic node together (not just the first).
      socket = assign(socket, last_media_pct: pct)

      {:noreply,
       Enum.reduce(album_ids, socket, fn id, s ->
         push_event(s, "media_progress", %{percent: pct, id: id})
       end)}
    end
  end

  defp file_progress(socket, entry) do
    pct = ceil(entry.progress)

    if pct == Map.get(socket.assigns.last_file_pct, entry.ref) do
      {:noreply, socket}
    else
      socket =
        assign(socket, last_file_pct: Map.put(socket.assigns.last_file_pct, entry.ref, pct))

      {:noreply, push_event(socket, "media_progress", %{percent: pct, ref: entry.ref})}
    end
  end

  # Send a single file the instant ITS upload completes (#149): find the in-flight send
  # that owns this entry's ref, consume just this entry, and post it as its own message so
  # its optimistic card swaps to a real, clickable one without waiting for the rest of the
  # batch. When the send is files-only and this was its LAST file, the caption follows as a
  # trailing message below the pile (not under the first file). If no stash owns the ref
  # yet (media_sending hasn't landed — an instant upload racing the push), leave the entry
  # for the form-submit path.
  #
  # By design (#149) files land in COMPLETION order, which may differ from staging order
  # (entries upload concurrently) — the explicit ask was "don't wait for the slowest", so a
  # quick doc surfaces before a slow one even if staged after it.
  defp send_ready_file(socket, entry) do
    case Enum.find_index(socket.assigns.media_client_ids, fn {_id, _cap, _conv, files, _cid, _af} ->
           Map.has_key?(files, entry.ref)
         end) do
      nil ->
        {:noreply, socket}

      idx ->
        # Independent per-file completion applies ONLY to a files-only send. When media
        # albums ride the same batch (album_ids non-empty, #193), leave the file for the
        # form-submit batch so the albums stay FIRST — sending the file eagerly here would
        # land it above them, and they're consumed only after every entry is done (#149).
        case Enum.at(socket.assigns.media_client_ids, idx) do
          {[], _cap, _conv, _files, _cid, _af} -> settle_ready_file(socket, entry, idx)
          _albums_present -> {:noreply, socket}
        end
    end
  end

  defp settle_ready_file(socket, entry, idx) do
    stash = socket.assigns.media_client_ids
    {album_id, caption, conv_id, files, caption_id, as_file} = Enum.at(stash, idx)
    scope = socket.assigns.current_scope
    conversation_id = conv_id || selected_id(socket)

    socket = consume_one_file(socket, scope, conversation_id, entry, Map.get(files, entry.ref))
    files = Map.delete(files, entry.ref)
    # A files-only send only reaches here (album_ids == []), so "done" = no files left (#193).
    done? = files == %{} and album_id == []

    # The last file of a files-only send pulls its caption down as a trailing message.
    {socket, caption, caption_id} =
      if done? and caption != "" and caption_id do
        {send_trailing_caption(socket, scope, conversation_id, caption, caption_id, nil), "", nil}
      else
        {socket, caption, caption_id}
      end

    # Drop the stash entry once nothing's left to send; else keep it (a remaining media
    # album still rides the form submit).
    stash =
      if done?,
        do: List.delete_at(stash, idx),
        else:
          List.replace_at(stash, idx, {album_id, caption, conv_id, files, caption_id, as_file})

    socket =
      assign(socket,
        media_client_ids: stash,
        last_file_pct: Map.delete(socket.assigns.last_file_pct, entry.ref)
      )

    # When the LAST file of a files-only send lands, this progress path — not
    # send_attachment — finished it, so clear the in-flight flag (re-enables the attach
    # button; otherwise sending_media stuck true left the paperclip disabled) and the
    # caption/reply/typing, mirroring send_attachment's success cleanup.
    if done? do
      {:noreply,
       socket
       |> clear_media_caption()
       |> assign(sending_media: false, last_media_pct: nil, reply_to: nil, last_typing_at: nil)}
    else
      {:noreply, socket}
    end
  end

  # Same false positive as send_attachment: `path` is the LiveView upload temp, `stable`
  # is tmp_dir + the entry's server-side uuid — neither is user input.
  # sobelow_skip ["Traversal.FileModule"]
  defp consume_one_file(socket, scope, conversation_id, entry, cid) do
    source =
      consume_uploaded_entry(socket, entry, fn %{path: path} ->
        stable = Path.join(System.tmp_dir!(), "eden-upload-" <> entry.uuid)
        File.cp!(path, stable)
        {:ok, %{path: stable, filename: entry.client_name, client_id: cid}}
      end)

    result = Chat.create_attachments(scope, conversation_id, [source], %{client_id: cid})
    File.rm(source.path)

    case result do
      {:ok, _messages} ->
        socket

      {:error, reason} ->
        socket
        |> put_flash(:error, attachment_error(reason))
        |> push_media_failed(cid)
    end
  end

  # The files-only caption below the pile. In a thread (phase F, root_id) it lands as a trailing
  # thread REPLY under the root; in the main stream it's a plain trailing message. Both dedup by
  # client_id and mark the optimistic node failed on error.
  defp send_trailing_caption(socket, scope, conversation_id, caption, caption_id, root_id) do
    attrs = %{"body" => caption, "client_id" => caption_id}

    result =
      if root_id,
        do: Chat.create_reply(scope, root_id, attrs),
        else: Chat.create_message(scope, conversation_id, attrs)

    case result do
      {:ok, _message} -> socket
      {:error, _reason} -> push_media_failed(socket, caption_id)
    end
  end

  # The album ring averages only the MEDIA entries (#149): files now drive their
  # own per-file rings, so a slow doc no longer drags the photo album's percent.
  defp overall_progress(%{attachment: %{entries: entries}}) do
    case Enum.filter(entries, &media_entry?/1) do
      [] -> 0
      media -> ceil(Enum.sum(Enum.map(media, & &1.progress)) / length(media))
    end
  end

  defp selected_id(socket), do: socket.assigns.selected && socket.assigns.selected.id

  # Stash a media send's {album_client_id, caption, conversation_id, file_cids, caption_id}
  # FIFO, bounded so a misbehaving client can't grow it unbounded (sends are serialized,
  # so 1-2 is the real depth) (#95). conversation_id pins the send to the chat it was
  # started in, so an in-flight upload survives a conversation switch and lands in the
  # right chat. file_cids maps each file's upload ref to its own client_id; caption_id is
  # the trailing files-only caption's optimistic node (#149).
  defp stash_cid(socket, album_ids, caption, conv_id, file_cids, caption_id, as_file),
    do:
      Enum.take(
        socket.assigns.media_client_ids ++
          [{album_ids, caption, conv_id, file_cids, caption_id, as_file}],
        16
      )

  defp pop_media_client_id([entry | rest]), do: {entry, rest}
  defp pop_media_client_id([]), do: {{[], "", nil, %{}, nil, false}, []}

  # The album optimistic client_ids — one per album a pick is split into (#193), as a list of
  # binaries (legacy single-id clients send a bare string; wrap it). Capped defensively.
  defp sanitize_album_ids(ids) when is_list(ids),
    do: ids |> Enum.filter(&is_binary/1) |> Enum.take(16)

  defp sanitize_album_ids(id) when is_binary(id), do: [id]
  defp sanitize_album_ids(_), do: []

  # Keep only string→string pairs from the client's {ref => client_id} files map so a
  # crafted payload can't smuggle non-binaries into the source maps / progress events,
  # and cap it at the upload entry limit so a fat map can't grow the stash unbounded.
  defp sanitize_file_cids(files) when is_map(files) do
    for {ref, cid} <- Enum.take(files, Chat.max_album_entries()),
        is_binary(ref),
        is_binary(cid),
        into: %{},
        do: {ref, cid}
  end

  defp sanitize_file_cids(_files), do: %{}

  # Tell the hook to drop the exact optimistic media node for a send that produced
  # no real row (server error or no consumed entry), so it doesn't spin forever and
  # pin its preview data-URLs (#95). A nil id (no twin tracked) is a no-op.
  defp push_media_failed(socket, nil), do: socket
  defp push_media_failed(socket, id), do: push_event(socket, "media_failed", %{id: id})

  # Drop every optimistic node of a failed send (#149/#193): each media album (album_ids,
  # one per batch) AND each per-file card (the file_cids values). Nil/absent ids are no-ops.
  defp push_all_failed(socket, album_ids, file_cids) do
    (List.wrap(album_ids) ++ Map.values(file_cids))
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(socket, &push_media_failed(&2, &1))
  end

  # Both paths are framework/app-generated, never user input: `path` is the
  # LiveView upload temp file, `stable` is tmp_dir + the entry's server-side
  # uuid. So the File.cp!/File.rm traversal warnings are false positives.
  # sobelow_skip ["Traversal.FileModule"]
  defp send_attachment(socket, scope, conversation_id, body, reply_to_id, ids, as_file) do
    # ids bundles the optimistic client_ids that move together: the album ids (one per album
    # the pick was split into, #193), the per-file ref→id map, and a files-only trailing-
    # caption node id (#149). `as_file` (#122) sends photos as uncompressed documents.
    {album_ids, file_cids, caption_id} = ids
    # A caption rides a media album inline, but a files-only send carries it as a TRAILING
    # message below the pile (#149) — decide by the staged entries before they're consumed
    # (client-type is advisory but matches the caption-placement intent). This keeps the
    # form-submit fallback consistent with the per-file progress path: no caption-on-the-
    # first-file and no orphaned optimistic caption node.
    has_media? = Enum.any?(live_entries(socket.assigns.uploads.attachment), &media_entry?/1)

    # Build ONE album from several entries: copy each to a stable temp (the consume
    # callback removes the original as it returns), then persist them together
    # (atomic) and remove the temps. Each source carries the file's own optimistic
    # client_id keyed by upload ref (#149) — read by Chat.create_attachments to stamp
    # each per-file message so its in-stream card swaps; media tiles carry nil here
    # (the album uses `client_id`). Consume the DONE entries INDIVIDUALLY rather than
    # consume_uploaded_entries/3, which raises on ANY not-done entry: a file the user
    # cancelled mid-batch lingers as a `cancelled?` (not-done) ghost, and the album
    # must still send the rest instead of crashing or silently dropping it (#158).
    sources =
      socket.assigns.uploads.attachment.entries
      |> Enum.filter(& &1.done?)
      |> Enum.map(fn entry ->
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          stable = Path.join(System.tmp_dir!(), "eden-upload-" <> entry.uuid)
          File.cp!(path, stable)

          {:ok,
           %{path: stable, filename: entry.client_name, client_id: Map.get(file_cids, entry.ref)}}
        end)
      end)

    # The upload has been consumed (entries are now []), so the normal composer
    # returns regardless; clear the flag (+ progress gates) so the next staging
    # shows the overlay and fresh rings start from 0.
    socket = assign(socket, sending_media: false, last_media_pct: nil, last_file_pct: %{})

    case sources do
      # No entry was consumed (still uploading or failed client-side validation).
      # The media never sends, so drop its optimistic ghost (#95); keep a caption
      # the user typed as a plain text message — reusing caption_id (files-only) so its
      # optimistic node swaps instead of orphaning.
      [] ->
        socket = push_all_failed(socket, album_ids, file_cids)

        if String.trim(body) == "",
          do: {:noreply, socket},
          else: send_text(socket, scope, conversation_id, body, caption_id, reply_to_id)

      sources ->
        # The album carries the caption only when media is present; a files-only send sends
        # the files plain and the caption follows as its own trailing message below.
        album_body = if has_media?, do: body, else: ""

        opts = %{
          body: album_body,
          reply_to_id: reply_to_id,
          # A list of per-album client_ids (#193): attachment_steps chunks the media into
          # albums and stamps each with its own id (Enum.at), so every optimistic node swaps.
          client_id: album_ids,
          as_file: as_file
        }

        result = Chat.create_attachments(scope, conversation_id, sources, opts)
        Enum.each(sources, &File.rm(&1.path))

        finish_attachment(
          socket,
          result,
          {scope, conversation_id, body, has_media?},
          ids
        )
    end
  end

  # On success, a files-only send's caption follows as its own trailing message (optimistic
  # node tagged caption_id) below the pile; clear the caption field but KEEP the chat input
  # (separate entities) and reset the typing throttle (#94/#149).
  defp finish_attachment(
         socket,
         {:ok, _messages},
         {scope, conversation_id, body, has_media?},
         {_client_id, _file_cids, caption_id}
       ) do
    socket =
      if (not has_media? and caption_id) && String.trim(body) != "",
        do: send_trailing_caption(socket, scope, conversation_id, body, caption_id, nil),
        else: socket

    {:noreply, socket |> clear_media_caption() |> assign(reply_to: nil, last_typing_at: nil)}
  end

  # On failure no real row streams in, so the optimistic nodes would spin forever (and pin
  # their preview data-URLs) — drop every twin: the album, each per-file card, AND the
  # trailing-caption node. Clear the caption so a failed send can't pre-fill the next one.
  defp finish_attachment(
         socket,
         {:error, reason},
         {_scope, _conversation_id, _body, _has_media?},
         {album_ids, file_cids, caption_id}
       ) do
    {:noreply,
     socket
     |> clear_media_caption()
     |> put_flash(:error, attachment_error(reason))
     |> push_all_failed(album_ids, file_cids)
     |> push_media_failed(caption_id)}
  end

  # Consume the staged thread-reply album (#104) into ONE reply — mirrors
  # send_attachment: copy each entry to a stable temp, persist them together via
  # create_album_reply (delivered as a thread reply), then remove the temps.
  #
  # Same false positive as send_attachment: `path` is the LiveView upload temp,
  # `stable` is tmp_dir + the entry's server-side uuid — neither is user input.
  # sobelow_skip ["Traversal.FileModule"]
  defp send_thread_album(socket, root, body, reply_to_id) do
    sources =
      consume_uploaded_entries(socket, :thread_attachment, fn %{path: path}, entry ->
        stable = Path.join(System.tmp_dir!(), "eden-thread-upload-" <> entry.uuid)
        File.cp!(path, stable)
        {:ok, %{path: stable, filename: entry.client_name}}
      end)

    case sources do
      # Nothing consumed (still uploading / failed client-side validation): drop any
      # lingering staged entries so the tray clears, then keep a typed caption as a
      # plain text reply (otherwise no-op).
      [] ->
        socket = cancel_staged_thread_attachments(socket)

        if String.trim(body) == "",
          do: {:noreply, socket},
          else: send_thread_reply_text(socket, root, body, reply_to_id)

      sources ->
        # try/after: if create_album_reply raises, the stable temps still get removed
        # (the stored blobs are reclaimed inside persist_album's error path).
        try do
          case Chat.create_album_reply(socket.assigns.current_scope, root.id, sources, %{
                 body: body,
                 reply_to_id: reply_to_id
               }) do
            {:ok, _reply} ->
              {:noreply, reset_reply_composer(socket)}

            {:error, _reason} ->
              {:noreply, put_flash(socket, :error, gettext("That reply can't be sent."))}
          end
        after
          Enum.each(sources, &File.rm(&1.path))
        end
    end
  end

  # A plain text thread reply. The reply itself arrives via the {:thread_reply}
  # broadcast. Shared by send_reply and send_thread_album's "nothing uploaded but a
  # caption was typed" fallback.
  defp send_thread_reply_text(socket, root, body, reply_to_id, client_id \\ nil) do
    case Chat.create_reply(socket.assigns.current_scope, root.id, %{
           "body" => body,
           "client_id" => client_id,
           "reply_to_id" => reply_to_id
         }) do
      {:ok, _reply} ->
        # The hook path (client_id present) cleared its input client-side; the form
        # path resets the composer here. The reply itself arrives via {:thread_reply}.
        socket = if client_id, do: socket, else: reset_reply_composer(socket)
        ack(socket, client_id)

      {:error, %Ecto.Changeset{}} ->
        socket |> put_flash(:error, gettext("That reply can't be sent.")) |> nack(client_id)

      {:error, _} ->
        socket
        |> assign(thread_root: nil)
        |> put_flash(:error, gettext("Thread not found."))
        |> nack(client_id)
    end
  end

  defp reset_reply_composer(socket),
    do:
      assign(socket,
        reply_composer: to_form(%{"body" => ""}, as: "reply"),
        thread_reply_to: nil,
        last_thread_typing_at: nil
      )

  # Drop any staged thread-reply attachments (#104) — on close, or when switching to a
  # different thread, so they don't bleed into the next reply.
  defp cancel_staged_thread_attachments(socket) do
    Enum.reduce(socket.assigns.uploads.thread_attachment.entries, socket, fn entry, acc ->
      cancel_upload(acc, :thread_attachment, entry.ref)
    end)
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

  # #178: auto-upload progress for the group avatar — when the picked image finishes,
  # process + set it, then update the open header/panel locally (the broadcast covers
  # the other members' sessions). A processing error surfaces as a flash.
  defp consume_group_avatar(:group_avatar, %{done?: true}, socket) do
    scope = socket.assigns.current_scope
    # The target group was pinned when the upload STARTED (validate_group_avatar), so a
    # navigation away mid-upload can't misfire onto the now-selected chat (or crash on nil).
    target = socket.assigns[:group_avatar_target]

    case consume_uploaded_entries(socket, :group_avatar, fn %{path: path}, _e ->
           {:ok, target && Chat.set_group_avatar(scope, target, path)}
         end) do
      [{:ok, updated}] -> {:noreply, sync_selected_avatar(socket, updated)}
      [{:error, reason}] -> {:noreply, put_flash(socket, :error, group_avatar_error(reason))}
      _ -> {:noreply, socket}
    end
  end

  defp consume_group_avatar(:group_avatar, _entry, socket), do: {:noreply, socket}

  # Update the open header/panel only if it's still the group we just set (the broadcast
  # covers everyone else); a no-op if the user navigated away mid-upload.
  defp sync_selected_avatar(socket, updated) do
    case socket.assigns.selected do
      %{id: id} when id == updated.id ->
        assign(socket, selected: %{socket.assigns.selected | avatar_key: updated.avatar_key})

      _ ->
        socket
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

  # Reserve the player's box before any metadata loads (dimensions are known at
  # create now — #117 reads them via ffprobe). Mirror img_box exactly: a DEFINITE
  # width + aspect-ratio, not aspect-ratio alone — without the explicit width the
  # <video> briefly painted its default box on insert (a ~60ms height dip) before
  # the ratio settled, so the optimistic poster→real swap flickered.
  defp video_ratio(%{width: w, height: h})
       when is_integer(w) and is_integer(h) and w > 0 and h > 0,
       do: img_box(%{width: w, height: h})

  defp video_ratio(_attachment), do: nil

  # A portrait clip (taller than wide) otherwise renders as a narrow column that drags its
  # caption into a tall stack of short lines. Render it in a wider, caption-friendly box
  # with an ambient blurred-poster glow filling the sides (Telegram-style); landscape video
  # keeps its natural box (video_ratio).
  defp portrait_video?(%{width: w, height: h})
       when is_integer(w) and is_integer(h) and w > 0 and h > 0,
       do: h > w

  defp portrait_video?(_attachment), do: false

  # The wide box for a portrait video: a fixed 4:5 frame (caption-friendly width) that
  # exposes the poster URL as --vthumb for the ambient ::before glow.
  # width via vw (not %, which is circular here — the video is position:absolute, so the box
  # has no in-flow content width and a % against its shrink-wrapped parent collapses to 0).
  # 20rem matches img_box/1's larger-dimension cap, so a portrait clip is as wide as a photo.
  defp portrait_box_style(%{id: id}),
    do: "--vthumb:url('#{~p"/files/#{id}/thumb"}'); width:min(20rem,80vw); aspect-ratio:4/5;"

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
