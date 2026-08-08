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
  import EdenWeb.PresenceHelpers, only: [status_label: 1, status_text_color_var: 1]

  alias Eden.{Accounts, Channels, Chat}
  alias EdenWeb.ChatLive.AlbumLayout
  alias EdenWeb.ChatLive.ThreadPanel
  alias EdenWeb.Markup

  @page 50
  # Per-page size for the profile media gallery (#136); a "Load more" fetches the next page.
  @gallery_page 30
  # Reel page for the lightbox (#466) — a swipe crosses it in a second, so it is
  # wider than the profile gallery's grid page.
  @lightbox_page 60

  # Typing indicator (#11): throttle outgoing "typing" broadcasts to at most one per the window
  # (Chat.typing_throttle_ms/0 — one source, shared with the thread composer); each received
  # broadcast keeps the indicator alive for the (longer) TTL, after which it auto-expires. TTL >
  # throttle so a continuous typer never flickers off between broadcasts.
  @typing_ttl_ms 4_000
  # "Last seen" heartbeat (#102): touch last_active_at on connect and periodically
  # while active, from this (sandboxed) LiveView process. Frozen while idle. The
  # idle/active transitions also touch, so this only needs coarse granularity.
  @touch_active_ms 300_000

  # Per-chunk upload timeout. LiveView's default is 10s. Uploads are chunked at Chat.upload_chunk_size
  # (1MB) and serialized, so one chunk must land within this window — a 1MB chunk on a slow uplink
  # (say ~110kbps) takes ~70s, so 80s gives it headroom while staying under the 90s no-progress stall
  # watchdog (a genuinely wedged upload still surfaces as failed). Below ~100kbps a 1MB chunk can't
  # finish in time and fails to a retriable card — acceptable for the corporate audience (office/home
  # links), and the chunk size is the knob if that ever needs revisiting.
  @upload_chunk_timeout 80_000

  # Every allow_upload uses Chat.upload_chunk_size() (512KB) — see its @doc: LiveView serializes chunks
  # over the socket, so a bigger chunk = fewer round-trips on a high-latency link (uploads are RTT-bound,
  # not bandwidth-bound). The /live socket's max_frame_size is DERIVED from it in endpoint.ex.

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
        # #209: per-conversation scoped presence for the OPEN 1:1 — %{user_id => "online"}, seeded on
        # open_conv_presence, read only in the header (header_peer_status/4). Empty until a 1:1 opens.
        conv_presence: %{},
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
        # The rows already on screen, so an unchanged one is not re-sent (#513).
        sidebar_rows: %{},
        # True between a media send's submit and its server consume (#95): hides
        # the preview overlay immediately so the in-stream node takes over, instead
        # of the overlay lingering for the whole upload. Reset once consumed.
        sending_media: false,
        # Metadata for an in-flight failed-card Resend (#…): stashed by retry_prepare (client_id,
        # caption, as_file, media?, conversation), read by handle_retry_progress when the
        # :attachment_retry auto-upload completes to build the message. nil when no retry is live.
        pending_retry: nil,
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
        # Group ids whose tail is held OPEN because a failed upload card is parked in #pending for
        # them — so the failed card fuses flush below the delivered rows instead of dangling under a
        # closed (timed) bubble. Set by "group_hold", cleared by "group_release".
        held_groups: MapSet.new(),
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
      # Through `stream_conversations/2`, not a copy of it (#546 review). The copy set
      # `sidebar_top` and streamed the rows but forgot `sidebar_peer_ids`, so a session that
      # mounted straight into a chat had it empty — which used to only mean "presence_diff skips
      # its re-stream", and now means the dot map is empty and `.PresenceDots` hides every dot in
      # the list. One function so the two can't drift again.
      |> stream_conversations([])
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
        chunk_size: Chat.upload_chunk_size(),
        # Staging-only (#392): the preview tray + caption. The real upload rides :attachment_seq
        # (which owns the progress ring); these entries are cancelled on Send, so this config
        # needs no progress callback of its own — the concurrent engine that used one is gone.
        chunk_timeout: @upload_chunk_timeout
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
        chunk_size: Chat.upload_chunk_size(),
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
        chunk_size: Chat.upload_chunk_size(),
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
        chunk_size: Chat.upload_chunk_size(),
        chunk_timeout: @upload_chunk_timeout
      )
      # Thread-reply album (#104): same accept/caps as :attachment, a separate upload so
      # the thread composer stages independently. No progress callback — a thread reply
      # appears on the {:thread_reply} broadcast (no optimistic ring, like text replies).
      |> allow_upload(:thread_attachment,
        accept: :any,
        max_entries: Chat.max_album_entries(),
        max_file_size: Chat.max_attachment_bytes(),
        chunk_size: Chat.upload_chunk_size(),
        chunk_timeout: @upload_chunk_timeout
      )
      # Channel avatar (#70): a single image, processed server-side to a square.
      |> allow_upload(:channel_avatar,
        accept: ~w(.png .jpg .jpeg .gif .webp),
        max_entries: 1,
        max_file_size: 5_000_000,
        chunk_size: Chat.upload_chunk_size(),
        # 60s (not the 10s default): a 512KB chunk on a slow uplink can exceed 10s (#327 review).
        chunk_timeout: @upload_chunk_timeout
      )
      # Group avatar (#178): click the big avatar in the profile panel → pick → it's
      # set at once (auto_upload + progress), processed server-side to a square.
      |> allow_upload(:group_avatar,
        accept: ~w(.png .jpg .jpeg .gif .webp),
        max_entries: 1,
        max_file_size: 5_000_000,
        chunk_size: Chat.upload_chunk_size(),
        # 60s (not the 10s default): a 512KB chunk on a slow uplink can exceed 10s (#327 review).
        chunk_timeout: @upload_chunk_timeout,
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

          _ when socket.assigns.live_action == :enter ->
            enter_remembered_room(socket, channel)

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

  # Back to the list. No sidebar reload (#514): its rows are already correct — the only thing that
  # changes is which one carries the active wash, and `.InstantNav` clears that client-side the
  # moment the list is revealed (`revealList`), a round-trip before this would have.
  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> leave_channel_mode()
     |> unsubscribe()
     |> assign(selected: nil)}
  end

  # The row as the client draws it: a picture, not a storage key (the same rule the notification
  # payload follows, #363/R203), and the initial the avatar falls back to when there is no image.
  defp mention_item(%{everyone: true} = item), do: %{handle: item.handle, everyone: true}

  defp mention_item(%{handle: handle, name: name, id: id, avatar_key: key}) do
    %{
      handle: handle,
      name: name,
      initial: String.first(name || handle) |> to_string() |> String.upcase(),
      avatar: key && EdenWeb.Avatars.user_src(id, key)
    }
  end

  # The message's resolved mentions, or nothing when the association was not preloaded (an
  # optimistic row, a preview struct) — the renderer then leaves every `@word` as text (#576).
  defp mention_rows(%{mentions: %Ecto.Association.NotLoaded{}}), do: []
  defp mention_rows(%{mentions: rows}) when is_list(rows), do: rows
  defp mention_rows(_), do: []

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
        socket = enter_room(socket, loaded)
        socket = if message_id, do: focus_message_target(socket, message_id), else: socket
        {:noreply, socket}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Conversation not found."))
         |> push_navigate(to: ~p"/channels/#{room.channel_id}")}
    end
  end

  # Select a room the user is now a member of (socket → socket, so knock-approval and the normal
  # open path share it). Remembers it as the channel's last room (#81) BEFORE select_conversation —
  # its refresh_rail re-reads list_channels, so the rail's entry link updates.
  defp enter_room(socket, loaded) do
    Channels.record_last_room(socket.assigns.current_scope, loaded.channel_id, loaded.id)
    socket |> refresh_rooms() |> select_conversation(loaded)
  end

  # /channels/:cid/enter — the rail's desktop target (#492). Resolves the remembered room
  # NOW, from the DB, instead of trusting an id the rail rendered a round-trip ago: that
  # snapshot pointed at the PREVIOUS room right after a switch, and following it wrote the
  # stale id back as the remembered one.
  #
  # The nil branch is a belt rather than a reachable state — entry_room_ids falls back to the
  # channel's general room and general is undeletable by design (delete_room refuses it), so
  # there is normally always something to open. That is also why it carries no test.
  defp enter_remembered_room(socket, channel) do
    case Channels.entry_room_id(socket.assigns.current_scope, channel.id) do
      # Patch to the canonical room-list URL rather than settling on /enter (#502 review):
      # /enter is a resolver, not a screen, so leaving the address bar there would make a
      # reload or a bookmark re-run the resolution instead of naming what is on screen.
      nil -> {:noreply, push_patch(socket, to: ~p"/channels/#{channel.id}")}
      room_id -> {:noreply, push_patch(socket, to: ~p"/channels/#{channel.id}/r/#{room_id}")}
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
    # This runs on EVERY messenger navigation, not only on the way out of a channel — so the
    # re-stream at the bottom has to know which it is, or opening a chat re-loads the whole
    # conversation list and undoes #514. Caught by `SidebarCostTest`, which exists for exactly
    # that.
    was_in_channel? = socket.assigns.channel != nil

    if old = socket.assigns.channel_topic_id, do: Channels.unsubscribe_channel(old)

    # Modal flags reset too — otherwise a members/invites modal left open
    # would auto-reopen on the next visit to any channel.
    socket
    |> assign(
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
    # ...and, only when a channel was actually open, re-stream the chat list (#558).
    #
    # `#conversations` is a `phx-update="stream"` container, and channel mode does not render it.
    # A stream is consumed by the render that receives it: once the container leaves the DOM, the
    # rows are gone, and returning to the messenger mounts it EMPTY — the person is met by "no
    # chats yet" and a button to start one, with every conversation they have sitting untouched in
    # the database. Opening any chat repopulated it, which is why it looked intermittent.
    #
    # After the assign, never before: `stream_conversations/2` returns early while `:channel` is
    # set, so the order here is what makes the call do anything at all.
    |> then(&if was_in_channel?, do: stream_conversations(&1, reset: true), else: &1)
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
        album_cid: sanitize_cid(params["album_cid"]),
        # Client-measured pixel dims (#231): a video's box-reservation hint so we can drop
        # the synchronous ffprobe. Layout-only; the media worker stays authoritative.
        width: sanitize_dim(params["width"]),
        height: sanitize_dim(params["height"])
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

  # A grouped file's upload FAILED — its optimistic card is now a visible failed node parked in
  # #pending. Hold the group's tail OPEN so the failed card fuses flush below the delivered rows,
  # instead of dangling under a closed (timed, rounded-off) bubble. Idempotent (a MapSet); released
  # by "group_release" once the last failed sibling is resent or deleted.
  def handle_event("group_hold", %{"group_id" => gid}, socket) do
    {:noreply, hold_group(socket, sanitize_group_id(gid), &MapSet.put/2)}
  end

  def handle_event("group_hold", _params, socket), do: {:noreply, socket}

  # The last failed sibling of a group was resent or deleted — stop holding, so the group's tail
  # closes again (its last delivered row regains its time + rounded bottom).
  def handle_event("group_release", %{"group_id" => gid}, socket) do
    {:noreply, hold_group(socket, sanitize_group_id(gid), &MapSet.delete/2)}
  end

  def handle_event("group_release", _params, socket), do: {:noreply, socket}

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

  # Who the composer may name (#576): members of the OPEN conversation whose handle or display
  # name starts with what has been typed. Scoped by the conversation, so the list itself is the
  # authorization — the client never learns of anyone the sender cannot already see.
  #
  # `seq` is the client's question number, echoed untouched: the same prefix can be outstanding
  # from two composers at once, and the answer has to say which one it answers (#577 review).
  def handle_event("mention_search", %{"q" => q} = params, socket) when is_binary(q) do
    items =
      case socket.assigns.selected do
        nil ->
          []

        conv ->
          socket.assigns.current_scope
          |> Chat.mention_candidates(conv, q)
          |> Enum.map(&mention_item/1)
      end

    {:noreply, push_event(socket, "mention_candidates", %{items: items, seq: params["seq"]})}
  end

  def handle_event("mention_search", _params, socket), do: {:noreply, socket}

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

  # The lightbox's conversation reel (#466): a cursor page of photos+videos, newest
  # first, so the viewer can swipe past the album it was opened from and through the
  # whole dialog. Answered as a REPLY (not a broadcast push_event) so the response
  # belongs to the requesting hook instance and nothing global has to be registered.
  def handle_event("lightbox_media", params, %{assigns: %{selected: %{id: conv_id}}} = socket) do
    before = params["before"]

    # Photos only for now (#474 review): the viewer renders an <img>, so a video item
    # would page into a frame the browser can't decode. Video slides need the player
    # from the video overlay — tracked separately.
    case Chat.list_conversation_media(socket.assigns.current_scope, conv_id, ~w(image),
           limit: @lightbox_page,
           before: before,
           with_message: true
         ) do
      {:ok, media} ->
        # The counter's denominator — the reel loads lazily backwards, so without the
        # total the viewer could only ever say "60 of 60+" (#466). A membership lost
        # between the two reads must not MatchError the LiveView down (#474 review):
        # fall back to the page size, which only softens the counter.
        total =
          case Chat.count_conversation_media(socket.assigns.current_scope, conv_id, ~w(image)) do
            {:ok, n} -> n
            {:error, _} -> length(media)
          end

        {:reply,
         %{
           items: Enum.map(media, &lightbox_item(&1, socket)),
           more: length(media) == @lightbox_page,
           total: total
         }, socket}

      {:error, _} ->
        {:reply, %{items: [], more: false, total: 0}, socket}
    end
  end

  def handle_event("lightbox_media", _params, socket),
    do: {:reply, %{items: [], more: false, total: 0}, socket}

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
    # #209: idle/backgrounded also drops an invisible user's conversation-scoped "online"
    # (the partner sees offline), independent of the auto-only global idle write.
    {:noreply, socket |> assign(idle?: true) |> maybe_apply_idle() |> apply_conv_presence()}
  end

  def handle_event("presence_active", _params, socket) do
    {:noreply, socket |> assign(idle?: false) |> maybe_apply_idle() |> apply_conv_presence()}
  end

  # Tab hidden (#206): stop auto-marking incoming messages read while the user isn't looking
  # (presence already went away via presence_idle from the same visibilitychange).
  def handle_event("tab_hidden", _params, socket),
    do: {:noreply, assign(socket, tab_visible: false)}

  # Tab visible again (#206): resume, and read whatever arrived in the open chat while away
  # (mark_read broadcasts {:read} → the badges refresh via #204). Also read the open thread panel
  # (#370/R055): while backgrounded its incoming replies were held unread, so catch them up now.
  def handle_event("tab_visible", _params, socket) do
    socket = assign(socket, tab_visible: true)
    scope = socket.assigns.current_scope

    case socket.assigns.selected do
      %{id: id} -> Chat.mark_read(scope, id)
      _ -> :ok
    end

    case socket.assigns[:thread_root] do
      %{id: root_id} -> Chat.mark_thread_read(scope, root_id)
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
        results = ThreadPanel.run_thread_search(socket, root_id, q)
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
    socket =
      if params["surface"] == "thread", do: ThreadPanel.close_thread_panel(socket), else: socket

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
      |> then(&if(from_thread?, do: ThreadPanel.close_thread_panel(&1), else: &1))
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
    {:noreply, ThreadPanel.open_thread(socket, id)}
  end

  def handle_event("close_thread", _params, socket) do
    {:noreply, socket |> ThreadPanel.reset_thread_select() |> ThreadPanel.close_thread_panel()}
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
         |> ThreadPanel.refresh_thread_list()}

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

        # ...but the client has ALREADY painted the chip (#521), so it has to be told. A re-stream
        # does NOT do it: the row's server-rendered markup is unchanged by a refusal, LiveView
        # sends no diff, and the invented chip survives (measured). An explicit event is the only
        # thing that reaches the party that guessed.
        #
        # And it carries the TRUTH, not just "no" (#562 review). Undoing by inverting what the
        # client painted assumes a refusal means the reaction is absent — false for an add-add
        # race, where the reaction IS recorded and the loser of the race is the one being told no.
        # Inverting there would show "not mine" over a row where it is. So the event says what the
        # state actually is and the client sets it.
        {:noreply,
         push_event(
           socket,
           "react_rejected",
           Map.merge(
             %{id: to_string(id), emoji: emoji},
             Chat.reaction_state(socket.assigns.current_scope, id, emoji)
           )
         )}
    end
  end

  # A malformed/hostile payload (no emoji, or a non-string emoji) — ignore rather
  # than crash the LiveView on this client-reachable event.
  def handle_event("react", _params, socket), do: {:noreply, socket}

  # Quote-reply (#71): stage the target in the composer tray. The menu/swipe/arrow
  # also focus the composer client-side (JS.focus), so this just sets the assign.
  def handle_event("reply", %{"id" => id}, socket) do
    case Chat.get_message(socket.assigns.current_scope, id) do
      # A race (the target was deleted while the menu/swipe was open) — say so instead of a silent
      # no-op that focuses the composer with no quote and no explanation (#383/R175).
      nil -> {:noreply, put_flash(socket, :error, gettext("That message is unavailable."))}
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
     |> ThreadPanel.maybe_broadcast_thread_typing(body)}
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
         |> stream_conversations(reset: true)
         |> push_patch(to: ~p"/app/c/#{conversation.id}")}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Couldn't start the chat."))}
    end
  end

  def handle_event("start", %{"member_ids" => ids} = params, socket) do
    ids = List.wrap(ids)
    named? = String.trim(params["title"] || "") != ""

    # A name was typed but only one person is picked — a group needs ≥2, so warn instead of
    # silently dropping the name into an unnamed 1:1 DM (#369/R176).
    if named? and length(ids) == 1 do
      {:noreply,
       put_flash(socket, :error, gettext("Pick at least two people for a named group."))}
    else
      start_conversation(socket, ids, params)
    end
  end

  def handle_event("start", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("Pick at least one person."))}
  end

  defp start_conversation(socket, ids, params) do
    scope = socket.assigns.current_scope
    opts = if length(ids) > 1, do: [group: true, title: params["title"]], else: []

    case Chat.create_conversation(scope, ids, opts) do
      {:ok, conversation} ->
        {:noreply,
         socket
         |> assign(show_new: false)
         |> stream_conversations(reset: true)
         |> push_patch(to: ~p"/app/c/#{conversation.id}")}

      {:error, :no_members} ->
        {:noreply, put_flash(socket, :error, gettext("Pick at least one person."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't start the chat."))}
    end
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
        if ThreadPanel.thread_open_for?(socket, message.root_id),
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
         |> ThreadPanel.maybe_update_thread_root(message)
         |> refresh_sidebar()}

      open?(socket, message.conversation_id) ->
        {:noreply, socket |> ThreadPanel.maybe_update_thread_root(message) |> refresh_sidebar()}

      true ->
        {:noreply, refresh_sidebar(socket)}
    end
  end

  # A reply landed in a thread of the open conversation: refresh the root's
  # footer (count/time/facepile), the viewer's unread, and the panel if open.
  def handle_info({:thread_reply, root, reply}, socket) do
    viewing? = ThreadPanel.thread_open_for?(socket, root.id)

    # Reading the thread keeps it read on the server (the DB just incremented it) — but only in a
    # FOCUSED tab (#370/R055). A backgrounded tab with the panel open must NOT auto-read incoming
    # replies (they'd be marked read across every device before the user ever saw them); the
    # tab_visible handler reads the open thread on return, mirroring the main stream (#206).
    if viewing? and socket.assigns.tab_visible,
      do: Chat.mark_thread_read(socket.assigns.current_scope, root.id)

    socket =
      if open?(socket, root.conversation_id) do
        socket
        # Authoritative unread from the server: covers the auto-followed root
        # author (no local key yet) and viewers reading right now (now zero).
        |> ThreadPanel.sync_thread_unread(root.id)
        |> ThreadPanel.restream_root_if_loaded(root)
        |> ThreadPanel.bump_facepile(root.id, reply.sender)
        |> ThreadPanel.refresh_thread_list()
      else
        socket
      end

    if viewing? do
      {reply, socket} = ThreadPanel.mark_thread_compact(socket, reply)

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
        |> ThreadPanel.restream_root_if_loaded(root)
        # Set the facepile for THIS root explicitly (#370/R177): when the last reply was deleted,
        # thread_participants returns no key for it, so a Map.merge would leave the stale avatars
        # in place — a facepile of participants for a thread that now has zero replies.
        |> assign(
          :thread_participants,
          Map.put(
            socket.assigns.thread_participants,
            root.id,
            Map.get(participants, root.id, [])
          )
        )
        |> ThreadPanel.sync_thread_unread(root.id)
        |> ThreadPanel.refresh_thread_list()
      else
        socket
      end

    if ThreadPanel.thread_open_for?(socket, root.id) do
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
       |> ThreadPanel.close_thread_if_root_gone(message.id)
       |> assign(:thread_unreads, Map.delete(socket.assigns.thread_unreads, message.id))
       # #136: drop the deleted message's media from an open profile gallery.
       |> maybe_drop_gallery(message)
       # Re-fuse the merged file bubble if a group member was the one deleted.
       |> reshape_group(message.conversation_id, message.group_id)
       |> forget_row(message.id)
       # Drop the vanished row from the selection MapSet + forward carry so the bar count
       # and forward plaque don't tally a message that's no longer in the stream (#379/R056).
       |> prune_removed_message(message.id)
       |> ThreadPanel.refresh_thread_list()}
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
       |> ThreadPanel.refresh_thread_list()}
    else
      {:noreply, socket}
    end
  end

  # Delete-for-me (on the user's own topic): drop the message from this session
  # and refresh the sidebar preview (the hidden message may have been the last one).
  def handle_info({:message_hidden, conversation_id, message_id, group_id, root_id}, socket) do
    socket =
      if open?(socket, conversation_id),
        do:
          socket
          |> stream_delete_by_dom_id(:messages, "messages-#{message_id}")
          |> stream_delete_by_dom_id(:thread, "thread-#{message_id}")
          |> ThreadPanel.close_thread_if_root_gone(message_id)
          # Re-fuse the merged file bubble if a group member was hidden.
          |> reshape_group(conversation_id, group_id)
          |> forget_row(message_id)
          # Same reconciliation as delete-for-both (#379/R056): a hidden row must leave the
          # selection set + forward carry too.
          |> prune_removed_message(message_id)
          # Hiding an unread thread reply decremented its badge server-side (#370/R129) — refresh
          # this session's thread unread + list so the badge drops live, not on the next open.
          |> refresh_hidden_thread(root_id),
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
        previous = socket.assigns.other_read_at
        socket = assign(socket, other_read_at: read_at)

        if conversation.channel_id do
          {:noreply, socket}
        else
          # Only the rows whose tick actually flips (#513). This used to re-fetch and re-stream
          # the whole page — fifty rendered bubbles, ~35-75 KB, for a ✓ → ✓✓ on usually one row —
          # and it fired for EVERY incoming message while the chat is open, i.e. right in the
          # window where the sender is watching their own send land.
          #
          # `read?/2` is `inserted_at <= other_read_at`, so the flip set is exactly the viewer's
          # own messages in `(previous, read_at]`. Bounded to the loaded window by `after_id`,
          # then filtered through `compacts`: streaming a paginated-out row would append it at
          # the bottom, out of order — the same trap the {:message_edited} path documents.
          {:noreply, stream_read_flips(socket, scope, conversation, previous, read_at)}
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
        socket
        |> forget_sidebar_row(conversation_id)
        |> stream_delete_by_dom_id(:conversations, "conversations-#{conversation_id}")
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
      # Drop the one row instead of reloading the list for it (#514): the group is gone, and a
      # stream delete says exactly that without a query.
      {:noreply,
       socket
       |> forget_sidebar_row(conversation_id)
       |> stream_delete_by_dom_id(:conversations, "conversations-#{conversation_id}")}
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

  # #165: a group was renamed — update the open header/panel title; the sidebar row is driven by
  # the {:conversation_activity} ping that `rename_group/3` sends alongside this one
  # (`notify_members`), and that handler updates the ONE row. Rebuilding the whole list here as
  # well cost ~6 queries for a row the other message was already about (#514).
  def handle_info({:conversation_renamed, conv}, socket) do
    if open?(socket, conv.id) do
      {:noreply, assign(socket, selected: %{socket.assigns.selected | title: conv.title})}
    else
      {:noreply, socket}
    end
  end

  # #178: a group's photo changed — header/panel from `selected`, sidebar row on its own.
  #
  # NOT the same as a rename, despite what the old comment here claimed: `set_group_avatar/3`
  # sends only `broadcast_avatar_change`, no `notify_members`, so there is no
  # {:conversation_activity} ping to lean on and dropping the update outright would leave a stale
  # photo in the list. One row instead of the whole list (#514) — and no `at: 0`, because changing
  # a photo is not activity and must not bump the chat to the top.
  def handle_info({:conversation_avatar_changed, conv}, socket) do
    socket = put_sidebar_conversation(socket, conv.id, [])

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

  # #209: a diff on the conversation-scoped topic — recompute the partner's scoped status for the
  # OPEN 1:1 only. MUST precede the global handler (which matches any presence_diff) so a scoped diff
  # never triggers a global statuses/0 recompute or a sidebar re-stream. Guarded on the topic matching
  # the current selection, so a stale in-flight diff from a just-left conversation can't mutate
  # conv_presence after a fast switch.
  def handle_info(
        %Phoenix.Socket.Broadcast{event: "presence_diff", topic: "conv:" <> _ = topic},
        %{assigns: %{selected: %{id: id, is_group: false, channel_id: nil}}} = socket
      ) do
    if topic == EdenWeb.Presence.conv_topic(id),
      do: {:noreply, assign(socket, conv_presence: EdenWeb.Presence.conv_statuses(id))},
      else: {:noreply, socket}
  end

  # A scoped diff with no matching 1:1 open (nil/group/room selection, or a just-left chat) — drop it
  # here so it can't fall through to the global handler.
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", topic: "conv:" <> _}, socket),
    do: {:noreply, socket}

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", payload: payload}, socket) do
    # Header status + open profile read @statuses (plain assigns) and refresh on
    # this update for free. The sidebar dots live in a `phx-update="stream"` list,
    # so they need a re-stream (#10) — but only when a conversation *peer's* status
    # actually changed; otherwise skip the per-diff DB re-query, since presence is
    # one global topic and every connect/nav by anyone fans a diff to all sessions
    # (#94 review). A status-only change (away↔online) lands in the diff's
    # joins+leaves keys too, so the same gate catches it. No-op in channel mode
    # (rooms show no per-message presence dot).
    changed = presence_changed_ids(payload)

    # Merge only who changed, instead of rebuilding the whole online map (#514). Presence is one
    # global topic, so this handler runs in EVERY session on every connect, disconnect and status
    # change by anyone; walking the entire online set each time is O(online) per session per
    # event. Dropping first is what makes someone going offline disappear: absent from the map is
    # how offline is spelled everywhere else.
    statuses =
      socket.assigns.statuses
      |> Map.drop(changed)
      |> Map.merge(EdenWeb.Presence.statuses_for(changed))

    socket = assign(socket, statuses: statuses)

    # No sidebar re-stream (#514). The dots are `[data-presence-uid]` now and `.PresenceDots`
    # re-applies them from the assign above — which is a plain assign and does re-render. This
    # used to cost ~7 queries in EVERY session whenever anyone you talk to changed status, and
    # presence is one global topic, so every connect and every navigation by anyone fanned a diff
    # to everyone.
    {:noreply, stamp_peer_offline(socket, changed)}
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
      # #209: reconcile the scoped track too — going invisible while a 1:1 is open starts it;
      # going visible untracks it (the partner now sees me via the global status instead).
      |> apply_conv_presence()

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

    # Gate the sidebar rebuild on whether this person can appear in it at all (#514).
    # `{:user_updated}` rides a process-wide topic, so before this every profile edit by anyone
    # in the organisation cost EVERY live session a full `list_conversations` (~7 queries, no
    # LIMIT) plus a diff of the whole sidebar stream. `refresh_selected_for/2` right below was
    # already gated the same way — this brings the sidebar in line with it.
    socket =
      if Chat.shares_conversation?(scope, user.id) do
        refresh_sidebar(socket)
      else
        socket
      end

    {:noreply, refresh_selected_for(socket, user)}
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
      <div id="idle-tracker" phx-hook="IdleTracker" hidden></div>
      <%!-- Carry-and-drop forward: re-hydrates the plaque from sessionStorage on every mount,
            so a carried message survives navigation across DMs, rooms and channels. --%>
      <div id="forward-carry" phx-hook="ForwardCarry" hidden></div>

      <%!-- Live presence dots (#102, widened in #514). Both the flat message rows and the sidebar
            chats live in `phx-update="stream"` containers, so a server re-render never reaches an
            existing avatar's dot. That is why a presence diff used to re-stream the whole sidebar:
            ~7 queries in every session, on every status change of anyone you talk to, and presence
            is one global topic.
            This host carries a plain assign, which DOES re-render, and the hook re-applies both the
            dot class and its screen-reader label by user id. The labels ride along because the hook
            cannot localize on its own — the same reason `PasswordReveal` gets its strings this way. --%>
      <div
        id="presence-dots"
        phx-hook="PresenceDots"
        data-statuses={Jason.encode!(dot_statuses(@statuses, @sidebar_peer_ids, @selected))}
        data-label-online={status_label("online")}
        data-label-away={status_label("away")}
        data-label-dnd={status_label("dnd")}
        hidden
      >
      </div>

      <%!-- Shared sidebar menus (#508): ONE of each per page, the same idiom as #message-menu and
            #reaction-grid. They used to be rendered hidden INSIDE every chat row and every room
            row — measured on a stand with eleven chats, that was 60% of the sidebar's DOM nodes
            and 59% of its bytes, and `Chat.list_conversations/2` has no LIMIT, so it grows with
            the chat list rather than with the screen.

            Neither carries per-row state. The .ContextMenu hook writes the owning row's id onto
            every item's `phx-value-id` and flips `data-needs` visibility on open, so the actions
            stay plain `phx-click` markup — which is what keeps `data-confirm` working. The
            predicates themselves stay in Elixir: the server puts them on the row as data-*. --%>
      <div
        id="convo-menu"
        class="ed-menu"
        data-menu
        role="menu"
        aria-label={gettext("Chat actions")}
        hidden
      >
        <button type="button" class="ed-menu__item" role="menuitem" phx-click="mark_as_read">
          <.icon name="hero-check-circle-micro" class="size-4" /> {gettext("Mark as read")}
        </button>
        <button type="button" class="ed-menu__item" role="menuitem" phx-click="toggle_mute">
          <span data-needs="unmuted"><.icon name="hero-bell-slash-micro" class="size-4" /></span>
          <span data-needs="muted" hidden><.icon name="hero-bell-micro" class="size-4" /></span>
          <span data-needs="unmuted">{gettext("Mute")}</span>
          <span data-needs="muted" hidden>{gettext("Unmute")}</span>
        </button>
        <button
          type="button"
          class="ed-menu__item"
          role="menuitem"
          phx-click="move_to_folder_prompt"
        >
          <.icon name="hero-folder-micro" class="size-4" /> {gettext("Move to folder…")}
        </button>
        <div class="ed-menu__sep"></div>
        <%!-- Leaving a group is IRREVERSIBLE (unlike a DM's re-surfaceable hide), so it gets its
              own label + a "can't undo" confirm (#369/R069). The owner is caught after confirm
              with a "transfer ownership first" flash (delete_chat handler); the group profile
              panel also carries this Leave affordance next to the transfer-ownership actions. --%>
        <button
          type="button"
          class="ed-menu__item ed-menu__item--danger"
          role="menuitem"
          phx-click="delete_chat"
          data-needs="group"
          data-confirm={gettext("Leave this group? You can't undo this.")}
          hidden
        >
          <.icon name="hero-arrow-right-start-on-rectangle-micro" class="size-4" />
          {gettext("Leave group")}
        </button>
        <button
          type="button"
          class="ed-menu__item ed-menu__item--danger"
          role="menuitem"
          phx-click="delete_chat"
          data-needs="direct"
          data-confirm={gettext("Delete this chat? It will be removed from your list.")}
          hidden
        >
          <.icon name="hero-trash-micro" class="size-4" /> {gettext("Delete chat")}
        </button>
      </div>

      <div
        id="room-menu"
        class="ed-menu"
        data-menu
        role="menu"
        aria-label={gettext("Room actions")}
        hidden
      >
        <button type="button" class="ed-menu__item" role="menuitem" phx-click="mark_as_read">
          <.icon name="hero-check-circle-micro" class="size-4" /> {gettext("Mark as read")}
        </button>
        <button
          type="button"
          class="ed-menu__item"
          role="menuitem"
          phx-click="toggle_room_favorite"
        >
          <.icon name="hero-star-micro" class="size-4" />
          <span data-needs="unfav">{gettext("Favorite")}</span>
          <span data-needs="fav" hidden>{gettext("Unfavorite")}</span>
        </button>
        <button type="button" class="ed-menu__item" role="menuitem" phx-click="toggle_mute">
          <span data-needs="unmuted"><.icon name="hero-bell-slash-micro" class="size-4" /></span>
          <span data-needs="muted" hidden><.icon name="hero-bell-micro" class="size-4" /></span>
          <span data-needs="unmuted">{gettext("Mute")}</span>
          <span data-needs="muted" hidden>{gettext("Unmute")}</span>
        </button>
        <%!-- The link is per-room, so the hook copies it off the row on open — the one piece of
              this menu that cannot be static. --%>
        <button type="button" class="ed-menu__item" role="menuitem" data-copy-link data-link="">
          <.icon name="hero-link-micro" class="size-4" /> {gettext("Copy link")}
        </button>
        <%!-- Admin items stay behind a SERVER gate, not a hidden attribute. Being a channel admin
              is a property of the PAGE, not of the row, so it costs nothing to decide here — and
              a member must not receive markup labelled "Delete room" at all. The server re-checks
              every one of these events anyway, but shipping the affordance and hiding it in JS is
              a different promise than never shipping it (#508). Only "which room" stays
              client-side: `deletable` is the general room, which cannot be deleted. --%>
        <%= if @channel && @channel.role in ~w(owner admin) do %>
          <div class="ed-menu__sep"></div>
          <button type="button" class="ed-menu__item" role="menuitem" phx-click="open_room_add">
            <.icon name="hero-user-plus-micro" class="size-4" /> {gettext("Add members")}
          </button>
          <button type="button" class="ed-menu__item" role="menuitem" phx-click="open_room_rename">
            <.icon name="hero-pencil-micro" class="size-4" /> {gettext("Rename room")}
          </button>
          <div class="ed-menu__sep" data-needs="deletable" hidden></div>
          <button
            type="button"
            class="ed-menu__item ed-menu__item--danger"
            role="menuitem"
            phx-click="delete_room"
            data-needs="deletable"
            data-confirm={gettext("Delete this room and all its messages? This cannot be undone.")}
            hidden
          >
            <.icon name="hero-trash-micro" class="size-4" /> {gettext("Delete room")}
          </button>
        <% end %>
      </div>
      <%!-- Instant navigation: paints the tapped chat's shell + a shimmer skeleton the
            moment a sidebar row is tapped, so the pane opens in the SAME frame instead of
            waiting out the cross-border RTT to chat.ihi.ru (patch nav is a full round-trip).
            The .ScrollBottom hook announces when the real stream lands (ed:conv-shown) and
            this fades out. Pure client-side overlay — never touches #messages / morphdom. --%>
      <div
        id="instant-nav"
        phx-hook="InstantNav"
        data-user-id={@current_scope.user.id}
        data-composer-placeholder={gettext("Message")}
        hidden
      >
      </div>
      <%!-- Notification renderer host (#215 sound / #217 desktop), shared with every
            authed page via EdenWeb.Notifier + NotifyHook (#272). `focused_conv` lets a
            background tab stay silent for the chat this tab is reading (#363/R165). --%>
      <.notifier prefs={@notify_prefs} focused_conv={@selected && @selected.id} />
      <%!-- Tab unread badge (#216): reflects total unread (DMs/groups + unmuted channels)
            in the browser tab as a "(N)" title prefix, so a backgrounded tab shows there's
            something waiting. data-count is recomputed on every rail refresh. --%>
      <div
        id="tab-badge"
        phx-hook="TabBadge"
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
          phx-hook="RoomSortable"
          data-admin={to_string(@channel.role in ~w(owner admin))}
        >
          <div class="ed-bounce-wrap space-y-0.5">
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
            data-opens="modal"
            phx-click="toggle_new"
            aria-label={gettext("New chat")}
          >
            <.icon name="hero-pencil-square-mini" class="size-5" />
          </button>
        </header>

        <form
          id="sidebar-search"
          class="ed-search"
          phx-change="search"
          phx-submit="search"
          phx-hook="SearchBox"
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
          phx-hook="FolderTabs"
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
              phx-hook="ContextMenu"
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
          <div id="conversations" phx-hook="SidebarReorder" phx-update="stream" class="space-y-0.5">
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
              <button class="ed-btn ed-btn--primary" data-opens="modal" phx-click="toggle_new">
                <.icon name="hero-pencil-square-micro" class="size-4" /> {gettext("New chat")}
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

      <%!-- Cancel target for a navigation swiped away mid-flight (#477). The gesture needs a
            way to settle the app back on the LIST without touching history, and it cannot
            reuse the header back arrow: that one only exists while a chat is open (@selected),
            which is exactly what is NOT true while one is still loading. Rendered always,
            never focusable, and `replace` so the settle cannot add an entry of its own. --%>
      <.link
        patch={if @channel, do: ~p"/channels/#{@channel.id}", else: ~p"/app"}
        replace
        data-nav-list
        class="hidden"
        aria-hidden="true"
        tabindex="-1"
      >
      </.link>

      <main
        id="chat-dropzone"
        phx-hook="DropZone"
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
            <%!-- patch, not navigate: same-LiveView mode switch, so an in-flight upload survives
                  (see the rail note in shell_components).
                  REPLACE, not push (#476): LiveView pushes history state only in the server-reply
                  callback, so a back rendered as a forward patch could never SHORTEN the stack —
                  it grew it (`/app → /c/A → /app → /c/B`), and when rapid switching superseded the
                  intermediate back-patch (backFinish's _navGen cancel, #439) the list entry was
                  never pushed at all, leaving `chat → chat → chat`. Either way the next system
                  back (Android hardware, iOS mid-load history.back()) walked into a chat the user
                  had opened earlier instead of returning to the list. Replacing consumes the
                  chat's entry, so no pop can land in an old chat. --%>
            <.link
              patch={if @channel, do: ~p"/channels/#{@channel.id}", else: ~p"/app"}
              replace
              class="ed-btn--icon md:hidden"
              aria-label={gettext("Back")}
              data-nav-back
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
                if ThreadPanel.unread_thread_count(@thread_unreads) > 0,
                  do:
                    gettext("Threads, %{count} unread",
                      count: ThreadPanel.unread_thread_count(@thread_unreads)
                    ),
                  else: gettext("Threads")
              }
              aria-expanded={to_string(@thread_list_open)}
            >
              <.icon name="hero-chat-bubble-left-right-mini" class="size-5" />
              <span :if={ThreadPanel.unread_thread_count(@thread_unreads) > 0} class="ed-thread-badge">
                {ThreadPanel.unread_thread_count(@thread_unreads)}
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
              data-opens="aside"
              phx-click="open_profile"
              aria-label={gettext("View profile")}
            >
              <.avatar
                name={title(@selected, @current_scope.user)}
                src={conversation_avatar_src(@selected, @current_scope.user)}
                status={header_peer_status(@selected, @current_scope.user, @statuses, @conv_presence)}
                size={:sm}
              />
              <div class="min-w-0">
                <div class="font-semibold truncate" style="font-size:0.9375rem;">
                  {title(@selected, @current_scope.user)}
                </div>
                <div
                  :if={not @selected.is_group}
                  style={"font-size:0.6875rem; color: var(#{status_text_color_var(header_peer_status(@selected, @current_scope.user, @statuses, @conv_presence))});"}
                >
                  <%= if status = header_peer_status(@selected, @current_scope.user, @statuses, @conv_presence) do %>
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
                      <.local_time
                        at={message.inserted_at}
                        class="ed-convo__time"
                        id={"t-dmsearch-#{message.id}"}
                      />
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
            phx-hook="ScrollBottom"
            data-conversation-id={@selected.id}
            data-has-more={to_string(@has_more)}
            data-focus-id={@focus_id}
            data-focus-nonce={@focus_nonce}
            data-lb-close={gettext("Close")}
            data-lb-prev={gettext("Previous")}
            data-lb-next={gettext("Next")}
            data-lb-of={gettext("of")}
            data-lb-viewer={gettext("Photo viewer")}
            data-lb-menu={gettext("Photo actions")}
            data-lb-show={gettext("Show in chat")}
            data-lb-save={gettext("Save")}
            data-lb-reply={gettext("Reply")}
            data-lb-forward={gettext("Forward")}
            data-lb-del-me={gettext("Delete for me")}
            data-lb-del-all={gettext("Delete for everyone")}
            data-lb-del-confirm={gettext("Delete this message for everyone?")}
          >
            <%!-- Floating day chip (#83): server-rendered so a re-render never drops it;
                  the .DateRail hook sets its label to the topmost visible day + toggles
                  .is-visible while scrolling. --%>
            <div id="date-chip" class="ed-date-chip" aria-hidden="true"></div>
            <%!-- Older messages auto-load when you scroll near the top (#113); the
                  ScrollBottom hook preserves the scroll position across the prepend.
                  This spinner only comes into view at the very top — i.e. exactly
                  when a page is loading. --%>
            <div class="ed-msgs-flow">
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
                class={
                  [
                    "flex flex-col",
                    (@selected.channel_id && "ed-flat-list") || "gap-2",
                    (@selection != nil and @select_surface == :main) && "ed-selecting",
                    # Rendered WITH the suppression already on (#565 review): the first paint happens
                    # before any hook runs, so a class added in `mounted()` arrives too late and the
                    # whole screen plays its reveals on load. `.DateRail` takes it off after a frame;
                    # a stream insert never re-sends this attribute, so a single arrival still
                    # animates, while a wholesale re-render (a chat switch) brings it back and is
                    # suppressed again — which is the intent.
                    "ed-feed--bulk"
                  ]
                }
                id="messages"
                phx-update="stream"
                phx-hook="DateRail"
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
              <%!-- Empty-state (#154, #355 R060), shown while #messages holds no streamed rows. It
                  MUST live OUTSIDE the stream container (CSS :has() on the sibling reveals it): a
                  non-stream child inside #messages breaks LiveView's append anchoring — with
                  .DateRail's ds-* separators present, appended messages land at the TOP of the
                  list instead of the bottom (the "forward/message only shows after refresh" bug).
                  Rendered for EVERY conversation (rooms + DMs + groups) — a freshly-created DM/group
                  used to open with a bare empty pane; the sub-copy adapts to the surface. --%>
              <div id="messages-empty" role="status" class="ed-room-empty">
                <div class="ed-room-empty__medallion" aria-hidden="true">
                  <.icon name="hero-chat-bubble-left-right" class="size-7" />
                </div>
                <p class="ed-room-empty__title">{gettext("No messages yet")}</p>
                <p class="ed-room-empty__sub">{empty_state_sub(@selected, @current_scope.user)}</p>
              </div>
              <%!-- Optimistic, not-yet-acked sends live here (JS-managed; LiveView leaves it alone). --%>
              <%!-- No container gap/margin (#351): optimistic rows carry their OWN natural margin
                  (bubbles + flat, compact-aware) so they sit EXACTLY where the real row will land in
                  the stream — a fixed container gap couldn't match the variable stream spacing
                  (compact rows are tight) and made the message jump on swap. --%>
              <div class="flex flex-col" id="pending-messages" phx-update="ignore"></div>
              <%!-- Rubber-band tail (#439): grows to keep the scroller's content over 100%
                  so iOS always bounces, WITHOUT stretching #messages (that pushed the
                  optimistic bubble to the bottom of short chats — the send "jump"). --%>
              <div class="ed-msgs-tail" aria-hidden="true"></div>
            </div>
          </div>
          <%!-- Shared full-emoji grid (#72): ONE popover for the page, opened by a
                message menu's "more" chevron, instead of a 39-button grid hidden in
                every message. Positioned + targeted by the .ReactionGrid hook. --%>
          <%!-- Mention autocomplete (#576): ONE popover for the page, driven by the .Mentions hook
                on whichever composer has focus. The list comes from the server (members of THIS
                conversation), so a handle can never name someone who is not in the room.
                `phx-update="ignore"`: the rows are drawn by the hook and the composer patches on
                EVERY keystroke (`composer_changed`) — without it morphdom restores this element's
                empty, hidden server markup milliseconds after the list opens, and the list
                flickers out from under the finger. --%>
          <div
            id="mention-pop"
            class="ed-mention-pop"
            phx-hook="Mentions"
            phx-update="ignore"
            role="listbox"
            aria-label={gettext("Mention someone")}
            data-label-all={gettext("Everyone")}
            hidden
          >
          </div>
          <div
            id="reaction-grid"
            class="ed-react-grid"
            phx-hook="ReactionGrid"
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

          <%!-- Shared message menu (#508): ONE per page, exactly like #reaction-grid above.
                It used to be rendered hidden INSIDE every bubble and every flat row, which
                measured 68% of the feed's DOM nodes and 64% of its bytes (24 nodes / ~5 KB per
                message). That mattered beyond render cost: the instant-nav cache stores
                #messages.innerHTML and MsgCache.put silently DROPS anything over 1 MB, so the
                hidden menus decided when a scrolled thread quietly stopped being cached at all
                — around 117 messages instead of ~317.

                Carries no per-message state: the .ContextMenu hook fills visibility + reaction
                highlights from the row's data-* on open, and items dispatch through pushEvent
                with the row's id — the same reason #reaction-grid needs none. `data-needs`
                marks an item whose visibility depends on the message; the server computes those
                predicates onto the row (data-can-*), so the rules stay in Elixir. --%>
          <div
            id="message-menu"
            class="ed-menu"
            data-menu
            role="menu"
            aria-label={gettext("Message actions")}
            hidden
          >
            <div class="ed-menu__reacts" role="group" aria-label={gettext("React")}>
              <button
                :for={e <- @my_quick}
                type="button"
                class="ed-menu__react"
                data-act="react"
                data-emoji={e}
              >
                {e}
              </button>
              <%!-- Opens the shared full-emoji grid (#72) for the row the menu is on. --%>
              <button
                type="button"
                class="ed-menu__react ed-menu__react-more"
                data-react-expand
                aria-label={gettext("More emoji")}
                aria-haspopup="menu"
              >
                <.icon name="hero-chevron-down-micro" class="size-4" />
              </button>
            </div>
            <div class="ed-menu__sep"></div>
            <%!-- Quote-reply (#71). The row carries data-reply-event, so a reply from a thread
                  row lands in the thread and one from a room row lands in the room. --%>
            <button type="button" class="ed-menu__item" role="menuitem" data-act="reply">
              <.icon name="hero-arrow-uturn-left-micro" class="size-4" /> {gettext("Reply")}
            </button>
            <button
              type="button"
              class="ed-menu__item"
              role="menuitem"
              data-act="open_thread"
              data-needs="thread"
              hidden
            >
              <.icon name="hero-chat-bubble-left-micro" class="size-4" /> {gettext("Reply in thread")}
            </button>
            <button
              type="button"
              class="ed-menu__item"
              role="menuitem"
              data-act="start_edit"
              data-needs="edit"
              hidden
            >
              <.icon name="hero-pencil-square-micro" class="size-4" /> {gettext("Edit")}
            </button>
            <button
              type="button"
              class="ed-menu__item"
              role="menuitem"
              data-act="copy_text"
              data-needs="copy"
              hidden
            >
              <.icon name="hero-clipboard-micro" class="size-4" /> {gettext("Copy text")}
            </button>
            <button type="button" class="ed-menu__item" role="menuitem" data-act="copy_link">
              <.icon name="hero-link-micro" class="size-4" /> {gettext("Copy link")}
            </button>
            <button type="button" class="ed-menu__item" role="menuitem" data-act="forward_prompt">
              <.icon name="hero-arrow-uturn-right-micro" class="size-4" /> {gettext("Forward")}
            </button>
            <button type="button" class="ed-menu__item" role="menuitem" data-act="enter_select">
              <.icon name="hero-check-circle-micro" class="size-4" /> {gettext("Select")}
            </button>
            <button type="button" class="ed-menu__item" role="menuitem" data-act="delete_for_me">
              <.icon name="hero-eye-slash-micro" class="size-4" /> {gettext("Delete for me")}
            </button>
            <%!-- The confirmation text rides the button because the hook asks for it itself:
                  `data-confirm` is a phx-click feature, and these items push directly. --%>
            <button
              type="button"
              class="ed-menu__item ed-menu__item--danger"
              role="menuitem"
              data-act="delete_for_both"
              data-needs="own"
              data-confirm-text={gettext("Delete this message for everyone?")}
              hidden
            >
              <.icon name="hero-trash-micro" class="size-4" /> {gettext("Delete for everyone")}
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
            phx-hook="SendQueue"
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
            data-sending-media-label={gettext("Sending media")}
            data-cancel-label={gettext("Cancel upload")}
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
              inert={live_entries(@uploads.attachment) != []}
            >
              <%!-- Attach stays live while a PREVIOUS send uploads (TG-style): a fresh pick just
                    stages into the compose overlay and opens it as a new send — the sequential engine
                    (:attachment_seq) queues it behind the in-flight one, so no waiting, no "in queue"
                    gating. The overlay owns "Add more" once something is staged (below). --%>
              <%!-- While carrying a forward, Send = drop the forward — so gate attach + the text
                    input + emoji (they'd be silently dropped, #369/R053), keeping only Send live.
                    `readonly`/`inert` (not `disabled`) so message[body] still submits and routes
                    through drop_forward. --%>
              <label
                class="ed-btn--icon cursor-pointer"
                aria-label={gettext("Attach a file")}
                inert={@pending_forward != nil}
              >
                <.icon name="hero-paper-clip-micro" class="size-5" />
                <%!-- sr-only (not hidden) keeps the input focusable / keyboard-reachable.
                      Only ONE live_file_input may exist per upload (same id) — when the
                      compose modal is open it owns "Add more", so the bar's drops out
                      (#130). The bar is behind the scrim then anyway. --%>
                <.live_file_input
                  :if={live_entries(@uploads.attachment) == []}
                  upload={@uploads.attachment}
                  class="sr-only"
                />
              </label>
              <%!-- The static half of the combobox contract for `@` (#576); the hook supplies the
                    moving part (`aria-activedescendant`) as the list is steered. --%>
              <input
                type="text"
                id="composer-body"
                name="message[body]"
                role="combobox"
                aria-controls="mention-pop"
                aria-expanded="false"
                aria-autocomplete="list"
                value={@composer[:body].value}
                class={["ed-input", @pending_forward && "opacity-60"]}
                placeholder={
                  if @pending_forward, do: gettext("Press Send to forward"), else: gettext("Message")
                }
                autocomplete="off"
                phx-hook="PasteUpload"
                phx-debounce="250"
                readonly={@pending_forward != nil}
              />
              <%!-- phx-update="ignore": the picker is fully client-managed (its
                    open/closed `hidden` is toggled by the hook, contents are a
                    static emoji set). Without it, the per-keystroke phx-change
                    re-render re-asserts the pop's static `hidden` and snaps the
                    picker shut after one pick — defeating multi-select (#90). --%>
              <div
                class="ed-emoji"
                id="emoji-picker"
                phx-hook="EmojiPicker"
                phx-update="ignore"
                inert={@pending_forward != nil}
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
            <%!-- Shows whenever something is staged — INCLUDING while a previous send is still
                  uploading (@sending_media), so attaching another file during an upload opens the
                  lightbox normally (TG-style) instead of the file vanishing. The client hides it for
                  the brief send round-trip (this.sending) so the just-sent batch doesn't flash; once
                  its staged entries are cancelled the overlay clears, and a fresh pick re-opens it. --%>
            <.compose_overlay
              :if={live_entries(@uploads.attachment) != []}
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
              <p style="font-weight:600;">{gettext("No chat selected")}</p>
              <p style="color: var(--ed-muted); font-size:0.875rem;">
                {gettext("Pick a chat or start a new one.")}
              </p>
              <button class="ed-btn ed-btn--primary" data-opens="modal" phx-click="toggle_new">
                <.icon name="hero-pencil-square-micro" class="size-4" /> {gettext("New chat")}
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
        phx-hook="DropZone"
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
                    <.local_time
                      at={message.inserted_at}
                      class="ed-convo__time"
                      id={"t-roomsearch-#{message.id}"}
                    />
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
          phx-hook="ScrollBottom"
          data-pending-id="thread-pending"
        >
          <%!-- The formatter sits HERE, not on the replies list (#560 review): the thread's ROOT
                message renders above that list, so a hook scoped to `#thread-replies` left the
                root's timestamp in the server's UTC. One instance covers both. --%>
          <div class="ed-bounce-wrap" id="thread-body" phx-hook="LocalTimes">
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
          phx-hook="ThreadSendQueue"
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
          <%!-- #348: thread attachments open the SAME compose lightbox as the main composer
                (media grid + caption + send), not a cramped inline tray. A scoped caption id keeps
                the two overlays from colliding; the send routes into this thread via .ThreadSendQueue
                (which reads THIS overlay and delegates to the shared sequential feeder). --%>
          <.compose_overlay
            :if={live_entries(@uploads.thread_attachment) != []}
            upload={@uploads.thread_attachment}
            form={@reply_composer}
            caption_id="thread-compose-caption"
            upload_name="thread_attachment"
          />
          <div class="flex items-center gap-2">
            <label class="ed-btn--icon cursor-pointer shrink-0" aria-label={gettext("Attach a file")}>
              <.icon name="hero-paper-clip-micro" class="size-5" />
              <%!-- Only ONE live_file_input may exist per upload (same id): when the lightbox is
                    open it owns "Add more", so the bar's input drops out (#348, mirrors the main). --%>
              <.live_file_input
                :if={live_entries(@uploads.thread_attachment) == []}
                upload={@uploads.thread_attachment}
                class="sr-only"
              />
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
              phx-hook="PasteUpload"
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
          <div class="ed-bounce-wrap">
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
        <%!-- SR-only status. Managed dots used to go without it, because the hook that updates
              them "can't localize" — but it can, if the server hands it the strings, which is how
              `PasswordReveal` has always done it. So the label is rendered here for every dot and
              carried live by `.PresenceDots`, which sets both the class and this text (#514).
              Without that, moving the sidebar's dots to the client would have silently dropped
              their status for screen readers. --%>
        <span :if={(@status || @dot_uid) && @dot_label} class="sr-only" data-presence-label>
          {@status && status_label(@status)}
        </span>
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
    <%!-- The menu itself lives once at the page root (#508); the row publishes only what the
          menu needs to configure itself, so the predicates stay computed in Elixir. --%>
    <div
      id={@id}
      class="ed-convo-wrap"
      data-id={@conversation.id}
      data-group={@conversation.is_group && "1"}
      data-muted={@conversation.muted && "1"}
      phx-hook="ContextMenu"
    >
      <.link
        patch={~p"/app/c/#{@conversation.id}"}
        class={["ed-convo", @active && "ed-convo--active"]}
        aria-haspopup="menu"
      >
        <%!-- A managed dot (#514): the row lives in a `phx-update="stream"` list, so a server
              re-render never reaches it — which is why a presence diff used to re-stream the
              WHOLE sidebar, ~7 queries, on every status change of anyone you talk to. --%>
        <.avatar
          name={title(@conversation, @user)}
          src={conversation_avatar_src(@conversation, @user)}
          status={peer_status(@conversation, @user, @statuses)}
          dot_uid={peer_uid(@conversation, @user)}
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
              id={"t-conv-#{@conversation.id}"}
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
              <.local_time
                at={message.inserted_at}
                class="ed-convo__time"
                id={"t-searchres-#{message.id}"}
              />
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
              <.local_time
                at={message.inserted_at}
                class="ed-convo__time"
                id={"t-chansearch-#{message.id}"}
              />
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
    down = String.downcase(body)

    # Trigram search (#56) also returns typo-tolerant hits where `q` is NOT a literal substring
    # of the body. There `String.split(down, q)` yields the whole body, and the window would run
    # off to a meaningless tail (#379/R070) — so anchor at the START of the body instead. Without
    # a fuzzy match offset there's no correct anchor, and `highlight_parts/2` likewise won't mark
    # (the literal term isn't present); a DB-side match anchor (ts_headline / similarity offset)
    # is the fuller fix and a separate follow-up.
    start =
      if q != "" and String.contains?(down, q) do
        before = down |> String.split(q, parts: 2) |> hd()
        max(String.length(before) - 24, 0)
      else
        0
      end

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
      data-room="1"
      data-muted={@room.muted && "1"}
      data-fav={@room.favorite && "1"}
      data-deletable={not @room.is_general && "1"}
      data-link={url(~p"/channels/#{@channel.id}/r/#{@room.id}")}
      draggable={to_string(@admin)}
      phx-hook="ContextMenu"
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
          phx-hook="FocusTrap"
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
                src={thumb_small_src(att)}
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
  defp kind_icon(_), do: "hero-document"

  attr :members, :list, required: true
  attr :channel, :map, required: true
  attr :me, :map, required: true
  attr :statuses, :any, required: true

  # Channel members: roles, online dots, and the owner/admin action matrix
  # (the context re-checks every action).
  defp channel_members_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-30" data-modal>
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
          phx-hook="FocusTrap"
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
                data-opens="popover"
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
                  style="color: var(--ed-danger-strong);"
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

  # Unified render for a system message (#360): ONE component for both the group bubble path and
  # the flat room path, matching on Chat.SystemMessage.describe/1 (a tagged tuple) — never a raw
  # jsonb key. A join-request (rooms) carries the admin Add/Decline actions + resolved status;
  # group member notices render just the centered text; an unknown/future action renders blank
  # (so a new system type in a room never masquerades as "requested to join", #360/R189).
  attr :id, :string, required: true
  attr :message, :map, required: true
  attr :admin, :boolean, default: false

  defp system_message(assigns) do
    assigns = assign(assigns, :info, Chat.SystemMessage.describe(assigns.message.meta))

    ~H"""
    <div id={@id} class="ed-sysmsg">
      <span>{system_message_text(@info)}</span>
      <%= case @info do %>
        <% {:join_request, %{status: status}} -> %>
          <button
            :if={@admin and status == "pending"}
            type="button"
            class="ed-btn ed-btn--primary ed-btn--sm"
            phx-click="approve_join"
            phx-value-id={@message.id}
          >
            {gettext("Add")}
          </button>
          <button
            :if={@admin and status == "pending"}
            type="button"
            class="ed-btn ed-btn--ghost ed-btn--sm"
            phx-click="decline_join"
            phx-value-id={@message.id}
          >
            {gettext("Decline")}
          </button>
          <span :if={status == "accepted"} class="ed-sysmsg__done">{gettext("Added")}</span>
          <span :if={status == "declined"} class="ed-sysmsg__muted">{gettext("Declined")}</span>
        <% _ -> %>
      <% end %>
    </div>
    """
  end

  defp system_message_text({:member_added, %{name: name}}),
    do: gettext("%{name} was added to the group", name: name)

  defp system_message_text({:member_removed, %{name: name}}),
    do: gettext("%{name} was removed from the group", name: name)

  defp system_message_text({:join_request, %{requester_name: name}}),
    do: gettext("%{name} requested to join", name: name)

  defp system_message_text(:unknown), do: ""

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
      data-opens="popover"
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
    <div class="fixed inset-0 z-30" data-modal>
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
          phx-hook="FocusTrap"
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
                phx-hook="CopyUrl"
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
    <div class="fixed inset-0 z-30" data-modal>
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
          phx-hook="FocusTrap"
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
    <div class="fixed inset-0 z-30" data-modal>
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
          phx-hook="FocusTrap"
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
                phx-hook="CopyUrl"
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
                style="color: var(--ed-danger-strong);"
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
          phx-hook="FocusTrap"
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

  # Per-message data the SHARED menu (#508) reads when it opens on this row. Emitted as a
  # handful of attributes instead of 24 hidden nodes per message. The predicates are computed
  # HERE on purpose: what may be edited, branched or copied is a product rule, and it stays in
  # Elixir rather than being re-derived in the hook. `nil` attributes are dropped by HEEx, so a
  # row only pays for the flags that are actually true.
  defp menu_attrs(message, mine, me, conversation_id, opts \\ []) do
    system? = message.kind == "system"
    body = message.body || ""

    [
      "data-own": flag(mine),
      "data-can-edit": flag(mine and not system? and is_nil(message.deleted_at)),
      "data-can-thread":
        flag(
          Keyword.get(opts, :threads, false) and not Keyword.get(opts, :in_thread, false) and
            is_nil(message.root_id)
        ),
      "data-can-copy": flag(body != ""),
      "data-emoji-mine": blank_to_nil(Enum.join(mine_emoji(message, me), " ")),
      # The raw body, because "Copy text" must write to the clipboard INSIDE the click gesture
      # (Firefox refuses a deferred write) and the markdown source exists nowhere else in the
      # DOM — the bubble renders it. Path only for the permalink; the origin is the client's.
      "data-text": blank_to_nil(body),
      "data-link": ~p"/app/c/#{conversation_id}/m/#{message.id}"
    ]
  end

  defp flag(true), do: "1"
  defp flag(_), do: nil

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

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
      <%!-- The inner row is what makes the reveal animatable (#565): a grid track can go from
            0fr to 1fr, an element cannot go from height 0 to auto. The chips live in the track,
            which is clipped while it opens. --%>
      <div class="ed-reactions__row">
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

  attr :selection, :any, required: true
  attr :confirming, :boolean, default: false
  attr :container, :string, default: "#messages"
  # compact = always icon-only (the thread panel is a narrow column even on desktop, where a
  # viewport-based `sm:` label reveal would overflow it). The main composer bar stays responsive.
  attr :compact, :boolean, default: false

  # The bottom action bar shown in place of the composer while selecting (Telegram-style):
  # a count + the actions on the selected messages (forward / copy / delete).
  #
  # It also carries what the .SelectSync hook needs to BUILD the per-row select overlays (#561),
  # which the server no longer renders: the sprite href for the check glyph, and the two
  # accessible labels. The preview label keeps the msgid translators already have and is handed
  # over with a `{}` where the text goes — only the client can read a rendered row.
  defp selection_bar(assigns) do
    assigns = assign(assigns, :count, MapSet.size(assigns.selection))

    ~H"""
    <div
      class="ed-selbar"
      id="selbar"
      phx-hook="SelectSync"
      data-container={@container}
      data-selected={Jason.encode!(MapSet.to_list(@selection))}
      data-check-icon={~p"/images/icons.svg" <> "#hero-check-micro"}
      data-label-select={gettext("Select message")}
      data-label-select-preview={gettext("Select: %{preview}", preview: "{}")}
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
        phx-hook="CopySelection"
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
          phx-hook="FocusTrap"
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
    <.system_message id={@id} message={@message} admin={@admin} />
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
      phx-hook="ContextMenu"
      aria-haspopup={@menu && "menu"}
      {(@menu &&
          menu_attrs(@message, @mine, @me, @conversation_id, threads: true, in_thread: @in_thread)) ||
         []}
    >
      <div class="ed-flat__gutter">
        <button
          :if={!@message.compact && @message.sender}
          type="button"
          class="ed-flat__avatar-btn"
          data-profile-trigger
          data-opens="popover"
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
            data-opens="popover"
            phx-click="show_profile"
            phx-value-id={@message.sender_id}
          >
            {@message.sender.display_name}
          </button>
          <span :if={!@message.sender} class="ed-flat__name">{gettext("Deleted account")}</span>
          <span :if={@message.edited_at} class="ed-edited">{gettext("edited")}</span>
          <span class="ed-flat__time"><.local_time at={@message.inserted_at} hook={false} /></span>
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
          msg={@message}
          mine={@mine}
        />
        <div :if={@message.body != ""} class="break-words ed-flat__body">
          {Markup.to_iodata(@message.body, mention_rows(@message))}
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
            <.local_time at={@message.last_reply_at} hook={false} />
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
    # Groups only ever carry member add/remove notices (join-requests are a rooms feature), so
    # admin defaults false — the join-request actions never render here (#360).
    ~H"""
    <.system_message id={@id} message={@message} />
    """
  end

  defp message_bubble(assigns) do
    # A photo/video message renders Telegram-style: no frame, the media fills the
    # bubble, the time overlays it. Files keep the normal padded bubble.
    media? =
      Enum.any?(
        assigns.message.attachments,
        &(&1.kind in ~w(image video) and not &1.as_file and not AlbumLayout.strip_photo?(&1))
      )

    assigns =
      assigns
      |> assign(:media?, media?)
      # A file-card message (attachments, but not inline media — includes "send as file" photos).
      # Give it the same fixed-width, card-fills bubble as a merged file group so a SOLO file doesn't
      # size to its own name (varying widths + a big empty bubble) — TG shows files at a steady width.
      |> assign(:file?, assigns.message.attachments != [] and not media?)
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
      <%!-- Bubble + reactions stack in a column so reactions hang UNDER the bubble
            (aligned to its side), not inside it (#107). Inside the bubble their chip
            outline + count blended into the bubble fill and read as a bare emoji. --%>
      <div class={["flex flex-col min-w-0", (@mine && "items-end") || "items-start"]}>
        <div
          class={[
            "ed-bubble",
            (@mine && "ed-bubble--me") || "ed-bubble--them",
            @media? && "ed-bubble--media",
            @file? && "ed-bubble--file",
            @grp && "ed-bubble--grp",
            @grp == :first && "ed-bubble--grp-first",
            @grp == :middle && "ed-bubble--grp-mid",
            @grp == :last && "ed-bubble--grp-last"
          ]}
          id={"bubble-#{@message.id}"}
          data-message-id={@message.id}
          phx-hook="ContextMenu"
          aria-haspopup="menu"
          {menu_attrs(@message, @mine, @me, @conversation_id)}
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
                style="font-size:0.75rem; font-weight:600; color: var(--ed-primary-strong-text);"
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
              <.album_view
                attachments={@message.attachments}
                message_id={@message.id}
                msg={@message}
                mine={@mine}
              />
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
              <span class="break-words">
                {Markup.to_iodata(@message.body, mention_rows(@message))}
              </span>
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
              style="font-size:0.75rem; font-weight:600; color: var(--ed-primary-strong-text);"
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
              msg={@message}
              mine={@mine}
            />
            <%!-- Caption + meta share a flow-root block so a long caption can't stretch
                  a media bubble wider than the photo (#135-twin): the wrap is constrained
                  to the media width (CSS width:0/min-width:100%) and the caption wraps to
                  it, while the meta floats bottom-right with text wrapping before it (#108).
                  In a merged file group the time+tick shows ONCE, on the LAST row (the middle
                  rows drop the cap entirely so the cards stack flush). --%>
            <div :if={@message.body != "" or @grp in [nil, :last]} class="ed-bubble__cap">
              <span :if={@message.body != ""} class="break-words">
                {Markup.to_iodata(@message.body, mention_rows(@message))}
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
    <.local_time at={@at} hook={false} />
    <span :if={@ticks} class="inline-flex items-center" style="margin-left:2px;">
      <.icon :if={not @read} name="hero-check-micro" class="size-3.5" />
      <span :if={@read} class="inline-flex items-center">
        <.icon name="hero-check-micro" class="size-3.5 -mr-2" />
        <.icon name="hero-check-micro" class="size-3.5" />
      </span>
    </span>
    """
  end

  attr :upload, :any, required: true
  attr :form, :any, required: true
  attr :editing, :boolean, default: false
  # Scope (#348): the main composer and the thread composer each render their OWN overlay bound to
  # their own upload; caption_id keeps the ids unique, and the hooks read the caption via the
  # [data-compose-caption] marker (scoped to each composer's this.el), so the two never collide.
  attr :caption_id, :string, default: "compose-caption"
  # The upload this overlay is bound to, as the string the shared "cancel_upload" event expects
  # (#348) — so a per-tile ✕ targets the RIGHT config ("attachment" for the main, "thread_attachment"
  # for the thread). Defaults to the main composer's.
  attr :upload_name, :string, default: "attachment"

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
                phx-hook="ImgPreview"
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
                  phx-hook="VideoPreview"
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
                phx-value-upload={@upload_name}
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
                phx-value-upload={@upload_name}
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
            id={@caption_id}
            data-compose-caption
            name="message[caption]"
            value={@form[:caption].value}
            class="ed-input"
            placeholder={gettext("Add a caption…")}
            autocomplete="off"
            phx-hook="PasteUpload"
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
  # The owning message + own-message flag (#465): album_view builds the lightbox
  # chrome's meta (sender, time, permalink, mine) once and hands it to every tile.
  attr :msg, :map, default: nil
  attr :mine, :boolean, default: false

  # A message's attachments (#58). One renders exactly as before; several render
  # as a media grid (images as lightbox tiles, sharing a gallery so the lightbox
  # can page through them) followed by any videos/files stacked as full items.
  defp album_view(%{attachments: [single]} = assigns) do
    assigns =
      assigns
      |> assign(:attachment, as_file_if_strip(single))
      |> assign(:meta, lightbox_meta(assigns))

    ~H"""
    <.attachment_view attachment={@attachment} meta={@meta} />
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
      |> assign(:meta, lightbox_meta(assigns))

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
          meta={@meta}
          sizes={tile_sizes(aspect, sum)}
          style={"flex:#{aspect} 1 0;#{tile_radius(ri, length(@rows), ti, length(row))}"}
        />
      </div>
    </div>
    <.attachment_view :for={attachment <- @rest} attachment={attachment} />
    """
  end

  # Everything the lightbox chrome needs about the owning message. `at` is an ISO
  # timestamp formatted client-side in the viewer's locale/zone (the DateRail
  # precedent — gettext and the TZ are unreachable inside the hook).
  defp lightbox_meta(%{msg: %{} = msg} = assigns) do
    %{
      id: msg.id,
      who: sender_name(msg),
      at: DateTime.to_iso8601(msg.inserted_at),
      link: ~p"/app/c/#{msg.conversation_id}/m/#{msg.id}",
      mine: (assigns[:mine] && "1") || nil
    }
  end

  defp lightbox_meta(_assigns), do: %{}

  # Match the STRUCT, not any map (#472 review): %Ecto.Association.NotLoaded{} is a
  # struct too, so a bare %{} pattern would take this clause and raise KeyError.
  defp sender_name(%{sender: %Accounts.User{} = s}), do: s.display_name || s.username
  defp sender_name(_), do: nil

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
  attr :meta, :map, default: %{}

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
        <img src={thumb_small_src(@attachment)} loading="lazy" alt="" />
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
      phx-hook="Lightbox"
      data-full={~p"/files/#{@attachment.id}"}
      data-thumb={thumb_small_src(@attachment)}
      data-gallery={@gallery}
      data-msg={@meta[:id]}
      data-who={@meta[:who]}
      data-at={@meta[:at]}
      data-link={@meta[:link]}
      data-mine={@meta[:mine]}
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
      phx-hook="VideoExpand"
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
        phx-hook="StreamVideo"
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
    <div class="fixed inset-0 z-30" data-modal>
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
          aria-label={gettext("New chat")}
          id="dlg-new-conv"
          phx-hook="FocusTrap"
          tabindex="-1"
        >
          <div class="flex items-center justify-between">
            <h2 style="font-weight:600;">{gettext("New chat")}</h2>
            <button class="ed-btn--icon" phx-click="close_new" aria-label={gettext("Close")}>
              <.icon name="hero-x-mark-mini" class="size-5" />
            </button>
          </div>

          <%= if @people == [] do %>
            <p style="color: var(--ed-muted); font-size:0.875rem;">
              {gettext("No one else has joined yet.")}
            </p>
          <% else %>
            <form phx-submit="start" class="space-y-3" phx-hook="NewConvGate" id="new-conv-form">
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
              <button class="ed-btn ed-btn--primary w-full" type="submit" disabled>
                {gettext("Start")}
              </button>
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
    <div class="fixed inset-0 z-30" data-modal>
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
          phx-hook="FocusTrap"
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
            <.link navigate={~p"/app/settings"} class="ed-btn ed-btn--primary inline-flex">
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
        phx-hook="Popover"
        phx-window-keydown="close_profile"
        phx-key="Escape"
        role="dialog"
        aria-modal="true"
        aria-label={gettext("Profile")}
        tabindex="-1"
      >
        <div class="flex flex-col">
          <%!-- Compact identity header: a small avatar with name/@handle/status stacked tight
                beside it, on the SAME left axis as the bio + corp rows below — reads at a glance
                for a short profile instead of a tall centered stack (mirrors the chat header).
                The avatar deliberately uses the DEFAULT size (2.5rem/40px, the message-row size)
                rather than the old :lg (3.5rem) — sized for this compact row, not a hero stack. --%>
          <div class="flex items-center gap-3">
            <.avatar
              name={@user.display_name}
              src={avatar_src(@user)}
              status={@status}
              dot_label={false}
            />
            <div class="min-w-0 leading-tight">
              <h2 class="font-semibold truncate" style="font-size:0.9375rem;">
                {@user.display_name}
              </h2>
              <p class="truncate" style="color: var(--ed-muted); font-size:0.8125rem;">
                @{@user.username}
              </p>
              <p
                class="mt-0.5"
                style={"font-size:0.75rem; color: var(#{status_text_color_var(@status)});"}
              >
                {status_label(@status)}
              </p>
            </div>
          </div>

          <p
            :if={@user.bio}
            class="mt-4 whitespace-pre-line break-words"
            style="font-size:0.875rem; color: var(--ed-ink);"
          >
            {@user.bio}
          </p>

          <.managed_identity user={@user} />
        </div>

        <%!-- The own card carries no action — editing lives in Settings, not worth a quick-access
              button; another person's card offers Message. --%>
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
  # (filled by the admin panel #174 / a future sync). Both surfaces now show the full
  # corporate identity (position, structure, corp email), so the card carries who a
  # person is in the org, not just their handle (#209 follow-up).
  #
  # Spacing logic: the value is pinned tight under its label (small margin + tight
  # leading — the default 1.5 line-height was what made the pairs look loose), and
  # the gap BETWEEN rows is clearly larger, so it reads as grouped pairs.
  attr :user, :map, required: true

  defp managed_identity(assigns) do
    fields =
      [
        {gettext("Position"), assigns.user.position},
        {gettext("Structure"), assigns.user.structure},
        {gettext("Corporate email"), assigns.user.corp_email}
      ]
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
            style={"font-size:0.75rem; color: var(#{status_text_color_var(@peer_status)});"}
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
              style="color: var(--ed-danger-strong); font-size:0.75rem;"
            >
              {gettext("Remove photo")}
            </button>
            <p
              :for={err <- (@upload && upload_errors(@upload)) || []}
              class="mt-1.5"
              style="color: var(--ed-danger-strong); font-size:0.75rem;"
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
                <div class="ed-member-row" id={"member-#{m.user.id}"} phx-hook="ContextMenu">
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
          <%!-- Leave the group (#369/R069): the affordance also lives here, next to the
                transfer-ownership actions, since an owner must transfer first — the delete_chat
                handler flashes that on {:error, :owner}. Irreversible, so a "can't undo" confirm. --%>
          <button
            type="button"
            class="ed-btn ed-btn--danger w-full mt-3"
            phx-click="delete_chat"
            phx-value-id={@conversation.id}
            data-confirm={gettext("Leave this group? You can't undo this.")}
          >
            <.icon name="hero-arrow-right-start-on-rectangle-micro" class="size-4" />
            {gettext("Leave group")}
          </button>
        </div>

        <div
          id="gallery-tabs"
          class="ed-gallery-tabs"
          role="tablist"
          aria-label={gettext("Shared media")}
          phx-hook="GalleryTabs"
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
      phx-hook="GalleryMonths"
      data-locale={Gettext.get_locale()}
    >
      <.media_tile
        :for={item <- @media}
        item={item}
        dom_id={"g-#{item.id}"}
        class="ed-gallery-tile"
        gallery="conv-gallery"
        sizes="(max-width: 640px) 33vw, 128px"
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
      phx-hook="GalleryMonths"
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
  # Message context for the lightbox chrome (#465): sender, time, permalink and the
  # own-message flag drive the title bar and the action menu. The profile gallery
  # passes none — its lightbox opens chrome-less.
  attr :meta, :map, default: %{}
  # The tile's rendered width, as an `<img sizes>` value. The album computes it exactly from the
  # mosaic geometry; the gallery states its grid. Without it the browser assumes the full viewport
  # and always picks the widest candidate, which is the bug this was meant to fix.
  attr :sizes, :string, default: nil

  # Shared media grid tile (#136): an image opens the lightbox (paging its `gallery`); a video
  # is a poster with a play badge. Used by the message album (album_view) AND the profile
  # gallery, so the lightbox/poster behaviour lives in ONE place. The phx-hook must be a
  # LITERAL string — a dynamic value skips the compile-time colocated-hook rewrite.
  defp media_tile(%{item: %{kind: "image"}} = assigns) do
    ~H"""
    <a
      id={@dom_id}
      phx-hook="Lightbox"
      data-full={~p"/files/#{@item.id}"}
      data-thumb={thumb_small_src(@item)}
      data-gallery={@gallery}
      data-ts={DateTime.to_unix(@item.inserted_at)}
      data-msg={@meta[:id]}
      data-who={@meta[:who]}
      data-at={@meta[:at]}
      data-link={@meta[:link]}
      data-mine={@meta[:mine]}
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
        srcset={thumb_srcset(@item)}
        sizes={@sizes}
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
      phx-hook="VideoExpand"
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
      <img
        :if={@item.thumbnail_key}
        src={thumb_src(@item)}
        srcset={thumb_srcset(@item)}
        sizes={@sizes}
        loading="lazy"
        decoding="async"
        alt=""
      />
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

  # No "audio" tab: audio isn't a classified kind (#373, Variant B), so the tab was always empty.
  defp gallery_tabs do
    [
      {"image", gettext("Photo")},
      {"video", gettext("Video")},
      {"file", gettext("Files")}
    ]
  end

  defp gallery_empty_text("image"), do: gettext("No photos in this chat yet")
  defp gallery_empty_text("video"), do: gettext("No videos in this chat yet")
  defp gallery_empty_text("file"), do: gettext("No files in this chat yet")

  defp gallery_empty_icon("image"), do: "hero-photo"
  defp gallery_empty_icon("video"), do: "hero-film"
  defp gallery_empty_icon("file"), do: "hero-document"

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
  # A STABLE id where the caller can supply one (#479). The fallback below mints a fresh
  # id on every render, which means morphdom's getNodeKey can never match and it is forced
  # to discard + re-add this node on EVERY patch of the surrounding row. That is invisible
  # on desktop but not on touch: a touch target is fixed at touchstart, so a finger resting
  # on this timestamp when its row re-renders is left holding a detached node, whose
  # touchend then reaches nobody — the orphaned long-press timer of #479. It also costs a
  # hook teardown + remount per row per patch.
  #
  # Every caller that HAS a stable key now passes one (#495): sidebar chats, and the four
  # search surfaces, each with its own prefix because two result panels can be mounted at
  # once and duplicate DOM ids would break morphdom outright.
  #
  # The fallback stays for msg_meta, which renders the time for message bubbles and media
  # pills but only receives `at` — giving it a stable id means threading the message id
  # through that component and its two call sites, which is a wider change than this one and
  # belongs with whatever next touches that seam. Those nodes sit inside message rows, whose
  # long-press is already guarded at fire time by #479, so what remains there is cost, not a
  # correctness gap.
  attr :id, :string, default: nil
  # Inside the message feed, pass `hook={false}` (#557): the container formats every <time> it
  # holds, so a row does not need a hook instance of its own. Measured on a 462-row feed: 450
  # `LocalTime` instances, i.e. 450 `mounted()` calls every time the chat opens.
  attr :hook, :boolean, default: true

  defp local_time(%{hook: false} = assigns) do
    ~H"""
    <time class={@class} datetime={DateTime.to_iso8601(@at)}>
      {Calendar.strftime(@at, "%H:%M")}
    </time>
    """
  end

  defp local_time(assigns) do
    # assign, not assign_new (#489 review): :dom_id is not an attr, so there is never an
    # existing value to preserve and assign_new only read as if there were.
    assigns = assign(assigns, :dom_id, assigns.id || "t-#{System.unique_integer([:positive])}")

    ~H"""
    <time
      class={@class}
      phx-hook="LocalTime"
      id={@dom_id}
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
        phx-hook="LastSeen"
        id={"ls-peer-#{@peer.id}"}
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
    {messages, _lg} = mark_group_pos(messages)

    # Keep a still-uploading group's tail open so the reload doesn't split it from its #pending tail.
    {messages, last_group} = reopen_inflight_tail(socket, messages)

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
    # No sidebar re-stream here (#514). Its only two jobs — move the active wash and clear the
    # opened chat's unread badge — are done by `.InstantNav` at tap time, a round-trip earlier,
    # and cost nothing; doing them again server-side meant ~6 queries and the whole stream table
    # on every navigation. A fresh load renders both from `@active`/`unread_count` as before.
    #
    # The rooms list still refreshes: it is a plain assign, not a stream, and an opened room kept
    # a stale unread badge without it.
    |> refresh_rooms()
    # Reading a room clears its unread, which lowers the channel's rail badge.
    |> then(fn s -> if conversation.channel_id, do: refresh_rail(s), else: s end)
    # #209: subscribe to + publish on the conversation-scoped presence topic (1:1 only).
    |> open_conv_presence()
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
        {messages, _lg} = mark_group_pos(messages)
        {messages, last_group} = reopen_inflight_tail(socket, messages)

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
      # A full re-stream replaces every row, so the remembered rows describe rows that no longer
      # exist — clear them, or the next update to an unchanged-looking row would be skipped
      # against a stale memory.
      #
      # CLEARED, not re-seeded from `convos` (#551 review): these come from
      # `list_conversations/2` and never compare equal to a `get_conversation_summary/2` result,
      # so seeding them looked like it primed the cache while priming nothing. An empty map is
      # honest — the first update after a re-stream is sent, and that is correct.
      |> assign(sidebar_peer_ids: peers, sidebar_top: top_conv_id(convos), sidebar_rows: %{})
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
        socket
        |> forget_sidebar_row(conversation_id)
        |> stream_delete_by_dom_id(:conversations, dom_id)

      # Reorder-to-top (activity bump, #194): stream_insert(at: 0) updates an existing row in
      # place but does NOT lift it to the front, so delete first to actually reposition it — BUT
      # only when the chat isn't already on top. Re-sending into the chat that's already at the
      # top would otherwise delete+re-insert it for no net move, re-running the bump animation on
      # every message. When it's already top, a plain in-place update keeps it there (no recreate,
      # no animation).
      Keyword.has_key?(insert_opts, :at) and socket.assigns.sidebar_top != conversation_id ->
        socket
        |> remember_sidebar_row(conversation_id, summary)
        |> stream_delete_by_dom_id(:conversations, dom_id)
        |> stream_insert(:conversations, summary, insert_opts)
        |> assign(sidebar_top: conversation_id)

      # Identical to the row already on screen — sending it again costs ~2.6 KB of diff for a
      # picture that does not change (#513). One incoming message in the open chat legitimately
      # updates this row twice: `{:conversation_activity}` (it arrived) and the read handler (we
      # read it, drop the badge). `mark_read` runs before both, so both compute the SAME row, and
      # the second was pure repetition.
      #
      # Only for a plain in-place update: the reorder branch above must still run even when the
      # content matches, because moving a row is not something a fingerprint can see.
      sidebar_row_unchanged?(socket, conversation_id, summary) ->
        socket

      true ->
        socket
        |> remember_sidebar_row(conversation_id, summary)
        |> stream_insert(:conversations, summary, insert_opts)
    end
  end

  # The last row sent for this conversation, compared by VALUE. Cleared when the row is deleted so
  # a re-appearing chat is always sent afresh.
  #
  # The summary itself, not a hash of it (#551 review). `:erlang.phash2/1` is 32 bits and not
  # collision-free, and the failure it buys is a row that silently keeps showing the wrong preview
  # until something else changes it — for a saving of a few bytes per conversation over holding
  # the struct that is already in memory. Exact comparison also cannot drift: a field added to the
  # row later is compared without anyone remembering to add it here.
  defp sidebar_row_unchanged?(socket, conversation_id, summary),
    do: Map.get(socket.assigns.sidebar_rows, conversation_id) == summary

  defp remember_sidebar_row(socket, conversation_id, summary),
    do:
      assign(socket, sidebar_rows: Map.put(socket.assigns.sidebar_rows, conversation_id, summary))

  # Every path that takes a row OUT of the stream forgets it here too (#551 review). Otherwise the
  # remembered copy outlives the row, and when that chat comes back — re-added to a folder, a DM
  # re-surfaced by a new message — the insert would be skipped as "unchanged" against a row that
  # is no longer on screen, and the chat would simply not appear.
  defp forget_sidebar_row(socket, conversation_id),
    do: assign(socket, sidebar_rows: Map.delete(socket.assigns.sidebar_rows, conversation_id))

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

  # A pending knock was approved while its window is open: walk the requester straight INTO the
  # room with a positive flash (#369/R076), instead of just clearing the window and dropping them
  # on the channel's room-list to hunt for the newly-visible room themselves.
  defp maybe_clear_knock(%{assigns: %{knock_room: %{id: id}}} = socket) do
    scope = socket.assigns.current_scope

    with true <- Chat.room_member?(id, scope.user.id),
         {:ok, loaded} <- Chat.get_conversation(scope, id) do
      socket
      |> assign(knock_room: nil, knock_pending: false)
      |> enter_room(loaded)
      |> put_flash(:info, gettext("You've been given access to #%{room}.", room: loaded.name))
    else
      # Not approved yet — leave the knock window up. (A get_conversation failure right after the
      # membership check is a room deleted in the gap; drop the window without entering.)
      false -> socket
      {:error, _} -> assign(socket, knock_room: nil, knock_pending: false)
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
  def mark_compact(messages, %{channel_id: nil}), do: {messages, nil}

  def mark_compact(messages, _room) do
    Enum.map_reduce(messages, nil, fn message, prev ->
      {%{message | compact: compact?(message, prev)}, {message.sender_id, message.inserted_at}}
    end)
  end

  def compact?(message, {sender_id, ts}) do
    message.sender_id == sender_id and
      DateTime.diff(message.inserted_at, ts) < @compact_window_s
  end

  def compact?(_message, nil), do: false

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

  # On a full re-stream (chat switch / permalink jump), the static mark_group_pos CLOSES the last
  # delivered member of a file group with :last (time + rounded-off bottom) — but if THIS session is
  # still uploading that group, it actually continues into the optimistic #pending rows below.
  # Closing it there splits the bubble ([delivered group · time][still-uploading group]) until the
  # next live landing heals the seam; navigating away and back forces exactly this reload, so the
  # split is what the user sees. Re-open the in-flight tail so it fuses across the reload, mirroring
  # mark_group_new's in-flight handling. Returns {messages, last_group}.
  defp reopen_inflight_tail(socket, messages) do
    messages =
      case List.last(messages) do
        %{group_id: gid, group_pos: pos} = tail
        when not is_nil(gid) and pos in [nil, :last] ->
          if group_open?(socket, gid) do
            # A lone delivered member (nil) opens the group as :first; a closed run (:last, ≥2
            # delivered) drops to :middle so it shows no time and keeps its squared bottom — either
            # way the tail stays open to fuse with the still-uploading #pending rows.
            reopened = %{tail | group_pos: if(is_nil(pos), do: :first, else: :middle)}
            List.replace_at(messages, -1, reopened)
          else
            messages
          end

        _ ->
          messages
      end

    {messages, group_tail(messages)}
  end

  # Live insert (DMs): continue or break the grouped-file run. While the group is STILL uploading on
  # THIS (sender's) session — its send queue has more items coming — a landed row renders as :first
  # / :middle (never :last), so it fuses with the in-flight optimistic bubble below instead of
  # detaching as its own tailed bubble. The FINAL file (queue drained) lands as :last, closing the
  # bubble. A recipient (no send queue) sees the ordinary progressive merge. Mirrors the flat
  # compact seam. Returns {message_with_pos, socket} and records the new tail + group_pos map.
  defp mark_group_new(socket, message) do
    open? = group_open?(socket, message.group_id)

    case socket.assigns.last_group do
      {sid, gid, prev, prev_pos}
      when sid == message.sender_id and not is_nil(message.group_id) and gid == message.group_id ->
        # Continuation: this row is :middle while more are coming, else :last (the tail).
        message = %{message | group_pos: if(open?, do: :middle, else: :last)}
        {message, socket |> demote_prev(prev, prev_pos) |> track_group(message)}

      _ ->
        # First row of a group. Open → :first (opens the bubble the #pending tail continues);
        # else a solo/ungrouped row (nil).
        message = %{message | group_pos: if(open?, do: :first, else: nil)}
        {message, track_group(socket, message)}
    end
  end

  # A file group's tail stays OPEN (fuses with the #pending rows below) while it's still uploading
  # on this session OR while a failed upload card is held in #pending for it — both sender-only
  # signals a recipient never has (they see the ordinary progressive merge).
  defp group_open?(socket, gid) do
    not is_nil(gid) and
      (group_in_flight?(socket, gid) or MapSet.member?(socket.assigns.held_groups, gid))
  end

  # Add/remove a group id to/from the held-open set (op is MapSet.put/2 or MapSet.delete/2), then
  # reshape it so its delivered tail opens/closes to match. Shared by the group_hold/release events.
  defp hold_group(socket, nil, _op), do: socket

  defp hold_group(socket, gid, op) do
    socket = update(socket, :held_groups, &op.(&1, gid))
    if conv = socket.assigns.selected, do: reshape_group(socket, conv.id, gid), else: socket
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
    {marked, _tail} = mark_group_pos(rows)
    # Keep the tail open while the group is in flight or holds a failed card (else the delivered
    # rows would close with a time above the still-parked #pending failed card).
    {marked, tail} = reopen_inflight_tail(socket, marked)

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

  # A row just left the stream (deleted-for-both by another member, or hidden by another tab):
  # reconcile the two server-owned id sets that live ALONGSIDE the stream so neither counts a
  # gone row (#379/R056). The selection bar reads its count from `@selection`, and the forward
  # plaque from `@pending_forward` — a stale id would over-count both. The stream row itself is
  # removed by the caller; this only touches the sets.
  defp prune_removed_message(socket, message_id) do
    socket
    |> prune_selection(message_id)
    |> prune_forward(message_id)
  end

  # A hidden message that was a thread reply (root_id set) → re-read its thread's unread badge +
  # list so the count drops live after the server-side decrement (#370/R129); a nil root is a no-op.
  defp refresh_hidden_thread(socket, nil), do: socket

  defp refresh_hidden_thread(socket, root_id) do
    socket
    |> ThreadPanel.sync_thread_unread(root_id)
    |> ThreadPanel.refresh_thread_list()
  end

  # Deselecting the last row exits select mode (Telegram-style, mirroring `toggle_select`) — no
  # dead bar of disabled actions over an empty selection.
  defp prune_selection(%{assigns: %{selection: %MapSet{} = sel}} = socket, message_id) do
    cond do
      not MapSet.member?(sel, message_id) ->
        socket

      MapSet.size(sel) == 1 ->
        assign(socket, selection: nil, sel_delete: nil, select_surface: nil)

      true ->
        assign(socket, selection: MapSet.delete(sel, message_id))
    end
  end

  defp prune_selection(socket, _message_id), do: socket

  # Filter the carried message out; an emptied carry clears the plaque + the client mirror, a
  # non-empty one re-mirrors the remaining ids to sessionStorage. `^messages` short-circuits when
  # the removed id wasn't carried (no needless client push).
  defp prune_forward(%{assigns: %{pending_forward: [_ | _] = messages}} = socket, message_id) do
    case Enum.reject(messages, &(&1.id == message_id)) do
      ^messages ->
        socket

      [] ->
        socket |> assign(pending_forward: nil) |> push_event("carry_clear", %{})

      kept ->
        socket
        |> assign(pending_forward: kept)
        |> push_event("carry_set", %{ids: Enum.map(kept, & &1.id)})
    end
  end

  defp prune_forward(socket, _message_id), do: socket

  # Re-streaming a row (reaction/thumbnail) loses the virtual compact flag (the
  # broadcast struct doesn't carry it); restore it from what we recorded when the
  # row was first streamed so the flat layout stays put.
  def restore_compact(socket, message),
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
        |> ThreadPanel.open_thread(root_id)
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
      {:ok, fresh} ->
        socket = assign(socket, selected: fresh)

        # A 1:1 DM shows the renamed member only in the header (assign above) — its bubbles carry
        # no sender label, so no re-stream. Groups (bubbles) AND rooms (flat rows) DO render the
        # name in the message rows, so re-stream them so it refreshes — but through
        # mark_compact + mark_group_pos so the virtual `compact` (#155) and `group_pos` (merged
        # file album, #379/R058) flags survive. A raw re-stream drops both — that's the #155
        # regression, and it's why the room branch used to skip the re-stream entirely (#379/R077).
        if fresh.is_group or fresh.channel_id do
          restream_marked(socket, scope, fresh)
        else
          socket
        end

      {:error, _} ->
        socket
    end
  end

  # Re-stream a conversation's message window with the virtual render flags recomputed and their
  # tracking assigns refreshed — the shared tail of select_conversation, reused wherever a live
  # rename/edit forces a full re-stream without losing compact/group_pos.
  defp restream_marked(socket, scope, conversation) do
    {:ok, messages} = Chat.list_messages(scope, conversation.id, limit: @page)
    {messages, last_flat} = mark_compact(messages, conversation)
    {messages, _lg} = mark_group_pos(messages)
    {messages, last_group} = reopen_inflight_tail(socket, messages)

    socket
    |> assign(
      last_flat: last_flat,
      last_group: last_group,
      compacts: Map.new(messages, &{&1.id, &1.compact}),
      group_pos: Map.new(messages, &{&1.id, &1.group_pos})
    )
    |> stream(:messages, messages, reset: true)
  end

  defp unsubscribe(socket) do
    if id = socket.assigns[:subscribed_id], do: Chat.unsubscribe(id)
    # Leaving a conversation's topic means its typers are no longer relevant —
    # clear them here so every deselect path (not just chat-switch) drops them
    # (#94 review). Stale TTL timers fire later and self-ignore on token mismatch.
    socket |> close_conv_presence() |> assign(subscribed_id: nil) |> clear_typing()
  end

  # Open (#209): a 1:1 subscribes to its member-only scoped presence topic, seeds the partner's
  # scoped status, and publishes MY own if I'm an active invisible user. The membership check that
  # let me open this conversation is the same boundary that authorizes reading its presence. Groups
  # and rooms don't participate — an invisible user stays fully offline there.
  defp open_conv_presence(
         %{assigns: %{selected: %{is_group: false, channel_id: nil} = conv}} = socket
       ) do
    # Presence is per live SESSION — track/subscribe only on the connected mount, never the HTTP
    # dead render (whose short-lived process would otherwise leave a phantom scoped track, #102 pattern).
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Eden.PubSub, EdenWeb.Presence.conv_topic(conv.id))

      socket
      |> assign(:conv_presence, EdenWeb.Presence.conv_statuses(conv.id))
      |> apply_conv_presence()
    else
      assign(socket, :conv_presence, %{})
    end
  end

  defp open_conv_presence(socket), do: assign(socket, :conv_presence, %{})

  # Close (#209): drop my scoped track + unsubscribe the topic for the conversation being left, and
  # clear the local map. Reads the still-current `selected` (unsubscribe runs before the new one is
  # assigned). A no-op reset for groups/rooms/none.
  defp close_conv_presence(
         %{
           assigns: %{
             selected: %{is_group: false, channel_id: nil} = conv,
             current_scope: %{user: user}
           }
         } =
           socket
       ) do
    EdenWeb.Presence.untrack_conv(self(), conv.id, user.id)
    Phoenix.PubSub.unsubscribe(Eden.PubSub, EdenWeb.Presence.conv_topic(conv.id))
    assign(socket, :conv_presence, %{})
  end

  defp close_conv_presence(socket), do: assign(socket, :conv_presence, %{})

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
    |> case do
      # A group whose owner removed everyone else has no other active members → an empty auto-name.
      # Give it a real label instead of "" (#355 R001) — the sidebar/header no longer show a blank.
      "" -> gettext("Group")
      name -> name
    end
  end

  defp title(conversation, user) do
    case others(conversation, user) do
      [first | _] -> first.display_name
      [] -> gettext("Just you")
    end
  end

  # Empty-state sub-copy (#355 R060), adapted to the surface: a room prompts posting to it, a group
  # invites the first message, a 1:1 greets the peer by name.
  defp empty_state_sub(%{channel_id: cid, name: name}, _user) when not is_nil(cid),
    do: gettext("Be the first to post in #%{room}.", room: name)

  defp empty_state_sub(%{is_group: true}, _user),
    do: gettext("Be the first to write in this group.")

  defp empty_state_sub(conversation, user),
    do: gettext("Say hi to %{name} 👋", name: title(conversation, user))

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

  # One reel item as the viewer needs it: the full source, a strip thumbnail, and the
  # owning message's chrome data (sender/time/permalink/mine) — the same shape the
  # rendered tiles carry, so paging into a not-yet-rendered photo shows full chrome.
  defp lightbox_item(att, socket) do
    msg = att.message
    me = socket.assigns.current_scope.user

    %{
      id: att.id,
      kind: att.kind,
      full: ~p"/files/#{att.id}",
      thumb: thumb_small_src(att),
      msg: msg && msg.id,
      who: msg && sender_name(%{sender: msg.sender}),
      at: msg && DateTime.to_iso8601(msg.inserted_at),
      link: msg && ~p"/app/c/#{msg.conversation_id}/m/#{msg.id}",
      mine: (msg && me && msg.sender_id == me.id && "1") || nil
    }
  end

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
    do: EdenWeb.Avatars.user_src(id, key)

  defp avatar_src(_user), do: nil

  # Avatar image URL for a group (#178), cache-busted by the avatar key (nil → initials).
  defp group_avatar_src(%{id: id, avatar_key: key}) when is_binary(key),
    do: EdenWeb.Avatars.group_src(id, key)

  defp group_avatar_src(_conversation), do: nil

  # The avatar a conversation shows: a group's own photo (#178), else the DM peer's.
  defp conversation_avatar_src(%{is_group: true} = conv, _user), do: group_avatar_src(conv)
  defp conversation_avatar_src(conv, user), do: avatar_src(peer(conv, user))

  defp group_avatar_error(:too_large), do: gettext("That image is too large (up to 5 MB).")
  defp group_avatar_error(:not_accepted), do: gettext("Use a JPEG, PNG, GIF or WebP image.")
  defp group_avatar_error(:too_many_files), do: gettext("Pick a single image.")
  defp group_avatar_error(:unprocessable), do: gettext("Couldn't process that image.")
  defp group_avatar_error(_other), do: gettext("Couldn't upload that image.")

  # Guarded (#355 R001): a solo auto-named group renders title == "" → String.first("") is nil →
  # String.upcase(nil) crashed the WHOLE sidebar render (every conversation streams there, so one
  # bad group blocked opening the messenger). Fall back to "?" for "" / nil — and for a
  # whitespace-only name (#386 review), which trim catches before it would show a blank letter.
  defp initials(name) when is_binary(name) do
    case String.trim(name) do
      "" -> "?"
      trimmed -> trimmed |> String.first() |> String.upcase()
    end
  end

  defp initials(_), do: "?"

  # Presence status of a 1:1's other participant (nil for groups / offline), used
  # to color the avatar dot + header label (#102).
  # Statuses the dots on screen actually need: the sidebar's DM peers plus, in a room, its
  # members. Not the whole global map — that would put every online user in the org on the wire
  # for every session.
  # Takes the three values it needs, NOT the whole `assigns` (#546 review). Passing `assigns` into
  # a function from a template hides which assigns the expression reads, so LiveView can no longer
  # tell when it may skip re-computing it — any change to anything marks this dirty.
  defp dot_statuses(statuses, peer_ids, selected) do
    room = if selected && selected.channel_id, do: room_member_ids(selected), else: []
    Map.take(statuses, peer_ids ++ room)
  end

  # The DM peer's id, or nil for a group — what tags a sidebar dot for `.PresenceDots` (#514).
  defp peer_uid(conversation, user) do
    case peer(conversation, user) do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp peer_status(%{is_group: true}, _user, _statuses), do: nil

  defp peer_status(conversation, user, statuses) do
    case others(conversation, user) do
      [other | _] -> Map.get(statuses, other.id)
      [] -> nil
    end
  end

  # Header-only presence (#209): the 1:1 header shows an invisible partner as "online" via the
  # conversation-scoped topic, while every GLOBAL surface (sidebar, message avatars, profile card)
  # keeps calling peer_status/3 and sees them offline. Scoped "online" wins; else the global status;
  # else nil → the header's "last seen" fallback. A normal peer is never in conv_presence, so this
  # is identical to peer_status/3 for them.
  defp header_peer_status(%{is_group: true}, _user, _statuses, _conv_presence), do: nil

  defp header_peer_status(conversation, user, statuses, conv_presence) do
    case others(conversation, user) do
      [other | _] -> Map.get(conv_presence, other.id) || Map.get(statuses, other.id)
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

  # Reconcile MY conversation-scoped track (#209): an invisible user with a pure 1:1 open and
  # active (not idle/backgrounded) publishes "online" to that conversation's members only; every
  # other state untracks. Never touches the global topic — that's apply_presence's job. Called
  # wherever the inputs change: opening a chat, idle/active, and a manual status change.
  defp apply_conv_presence(
         %{assigns: %{selected: selected, current_scope: %{user: user}} = a} = socket
       ) do
    if scoped_online?(selected, a.my_status, a.idle?) do
      EdenWeb.Presence.track_conv(self(), selected.id, user.id)
    else
      if selected, do: EdenWeb.Presence.untrack_conv(self(), selected.id, user.id)
    end

    socket
  end

  # Only a pure 1:1 (no group, no channel room), invisible, and active earns a scoped "online".
  defp scoped_online?(%{is_group: false, channel_id: nil}, "invisible", false), do: true
  defp scoped_online?(_conversation, _status, _idle), do: false

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

  # Re-stream the rows a read receipt actually changed, keeping every virtual flag the raw DB
  # rows do not carry: `compact` (collapsed author headers, #155) and `group_pos` (merged file
  # albums, #379/R058). Losing either was the reason the naive whole-page re-stream existed.
  defp stream_read_flips(socket, scope, conversation, previous, read_at) do
    compacts = socket.assigns.compacts

    # Bound the query by the loaded window from both ends: never older than its first row, never
    # more rows than it holds. The interval usually bounds this to nothing at all, but on the
    # FIRST receipt there is no previous marker, so every own message up to `read_at` flips and
    # the window is the only bound left (#529 review).
    case Chat.list_own_messages_between(scope, conversation.id, previous, read_at,
           after_id: compacts |> Map.keys() |> Enum.min(fn -> nil end),
           limit: map_size(compacts)
         ) do
      {:ok, messages} ->
        messages
        |> Enum.filter(&Map.has_key?(compacts, &1.id))
        |> Enum.reduce(socket, fn message, acc ->
          streamed =
            restore_group_pos(acc, %{message | compact: Map.get(compacts, message.id, false)})

          stream_insert(acc, :messages, streamed)
        end)

      {:error, _} ->
        socket
    end
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
  # sobelow_skip ["Traversal.FileModule"] — source.path is a server-side temp from
  # consume_seq_entry, never user input (the false positive the removed engine's twins also carried).
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
    source = consume_seq_media(socket, entry) |> put_client_dims(pending)
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
    # Take this send's caption for the FIRST album only (it rides that album inline).
    caption = if not queue.caption_used and queue.caption != "", do: queue.caption, else: ""

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

    # The caption counts as USED only if it actually rode a COMMITTED album (#361/R081): if this
    # album failed, leave `caption_used` untouched so the text is still available for the next
    # album or the trailing-caption fallback — otherwise the user's caption silently vanishes.
    caption_used = queue.caption_used or (caption != "" and match?({:ok, _}, result))

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

  # Carry the client-measured video dims (#231) onto the consumed source so Chat.media_dimensions
  # can reserve the box without a synchronous ffprobe. Images ignore these (they use the header read).
  defp put_client_dims(source, %{width: w, height: h}) when is_map(source),
    do: Map.merge(source, %{width: w, height: h})

  defp put_client_dims(source, _pending), do: source

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

  # A client-measured pixel dimension (#231): a positive int, capped so a forged value can't drive
  # an absurd aspect-ratio into the layout CSS. Layout hint only — never a storage/serving decision.
  defp sanitize_dim(n) when is_integer(n) and n > 0 and n <= 100_000, do: n
  # `seq_item` is a pushEvent, so a numeric field arrives as an integer — but tolerate a string
  # too (a future form/param path, or a client that stringifies), so the hint is never silently
  # dropped (#340 review).
  defp sanitize_dim(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> sanitize_dim(n)
      _ -> nil
    end
  end

  defp sanitize_dim(_), do: nil

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
    |> then(fn s ->
      # #348: the thread composer stages into :thread_attachment (its lightbox is the SAME overlay),
      # so a clear-tray / Escape / scrim-click (cancel_all_uploads) must drop it too — else the thread
      # lightbox can't be dismissed. Only one overlay is open at a time, so the other reduce is a no-op.
      Enum.reduce(live_entries(s.assigns.uploads.thread_attachment), s, fn entry, acc ->
        cancel_upload(acc, :thread_attachment, entry.ref)
      end)
    end)
    # A cleared tray or a conversation switch abandons the staged send, so drop the sending flag
    # + the progress gate (#95) — else a stale `true` hides the overlay next staging. Runs on
    # cancel_all_uploads + select_conversation.
    |> assign(sending_media: false, last_media_pct: nil, last_file_pct: %{})
  end

  # Cancel ONE attachment entry (#137) — the tray X (before send) and the in-flight X on the
  # optimistic card share this. Abort the entry, drop its ref from the in-flight stash + the
  # progress gate. When that empties the upload, the cleanup depends on which X it was:
  # in-flight (a real send) clears sending_media + caption/reply/typing + the orphaned caption
  # node; a tray cancel keeps the reply (the user may still send a text reply).
  defp cancel_attachment_entry(socket, ref) do
    in_flight? = socket.assigns.sending_media

    # `cancel_upload/3` raises on an unknown ref, so only touch entries still live in the
    # config — a stale ref (already cancelled by a stall's media_send_reset, or a late tap
    # after the entry finished) is a safe no-op, not a crash.
    known_ref? = Enum.any?(socket.assigns.uploads.attachment.entries, &(&1.ref == ref))

    socket =
      socket
      |> then(&if(known_ref?, do: cancel_upload(&1, :attachment, ref), else: &1))
      |> assign(last_file_pct: Map.delete(socket.assigns.last_file_pct, ref))

    cond do
      # Other live entries are still uploading — the completion path resets the flags when the
      # last one lands. Cancelled ghosts are excluded so the LAST active cancel still falls
      # through to the reset (#158).
      live_entries(socket.assigns.uploads.attachment) != [] ->
        socket

      in_flight? ->
        # A real send was cancelled: re-enable the composer (sending_media) and clear the
        # caption/reply/typing it carried.
        socket
        |> clear_media_caption()
        |> assign(sending_media: false, last_media_pct: nil, reply_to: nil, last_typing_at: nil)

      true ->
        # Tray cancel BEFORE send: the overlay closes (no media left) — clear only the
        # caption field; KEEP the reply (the user may still send a text reply) (#137 review P2-1).
        clear_media_caption(socket)
    end
  end

  ## Typing indicator (#11)

  # Tell the open conversation we're typing — throttled (composer_changed fires
  # per keystroke) and only with real content. Monotonic ms so the throttle is
  # immune to wall-clock changes.
  defp maybe_broadcast_typing(%{assigns: %{selected: nil}} = socket, _body), do: socket

  defp maybe_broadcast_typing(socket, body) do
    now = System.monotonic_time(:millisecond)
    last = socket.assigns.last_typing_at

    if String.trim(body) != "" and (is_nil(last) or now - last >= Chat.typing_throttle_ms()) do
      Chat.broadcast_typing(socket.assigns.current_scope, socket.assigns.selected.id)
      assign(socket, last_typing_at: now)
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

  # One owner for "is this a usable id" (#520). This used to re-implement the policy — the same
  # `Integer.parse`, but WITHOUT the bigint bound that #494 added after a 26-digit id reached
  # Postgrex and crashed it. The duplicate was harmless only because the context doors normalise
  # too; it was exactly the drift #494 was filed about. Callers here expect `nil` for "no", so the
  # canonical `:error` is translated rather than the policy re-stated.
  defp safe_int(v) do
    case Eden.Ids.normalize(v) do
      :error -> nil
      id -> id
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

      # A media SEND is owned entirely by the sequential engine now (:attachment_seq via
      # queue_start/seq_item) — the client cancels the staged :attachment entries on Send, so
      # they never reach here "all done". The old concurrent path (media_sending → send_attachment)
      # is gone (#392); a bare "send" with no live staged entries just falls through to text.
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
    # live_entries (not raw .entries), mirroring send_dispatch (#158/#361/R061): a photo X'd
    # mid-batch lingers as a cancelled? ghost that is never done?, which would make `entries != []`
    # true but `all done?` false — dropping the reply into the TEXT branch and silently NOT sending
    # the attachments that ARE staged. Filtering ghosts keeps the album branch honest.
    entries = live_entries(socket.assigns.uploads.thread_attachment)

    cond do
      # #164 text→media: editing a thread reply + attached media converts it to media (parity
      # with the main composer) — before the plain edit branch, else the media is stranded.
      socket.assigns.thread_editing && all_uploads_done?(entries) ->
        save_thread_edit_to_media(socket, body)

      # #164: an active thread-reply edit routes send_reply to edit_message, not a new reply.
      socket.assigns.thread_editing ->
        ThreadPanel.save_thread_edit(socket, body)

      is_nil(root) ->
        {:noreply, socket}

      # An album reply (#104): the attachments are the content, so an empty caption is OK.
      # Mirror the main composer (P0): consume only once every entry is done. The thread
      # composer submits normally (no optimistic typing during upload), so this is
      # always true in normal use — but it stops a crafted "send_reply" sent while an
      # attachment is still uploading from reaching consume_uploaded_entries, which
      # raises on an in-progress entry and crashes the LiveView.
      all_uploads_done?(entries) ->
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

    ok = Enum.count(results, &match?({:ok, _}, &1))
    fail = length(results) - ok

    # An honest, per-count flash (#369/R083/R084), mirroring `delete_selection`. A full success
    # needs no toast — the copies land visibly at the stream bottom. A PARTIAL success must say
    # which failed, else the user thinks nothing forwarded and re-clicks into duplicates; the
    # carry is cleared (the successes already landed). A TOTAL failure keeps the carry so a retry
    # (e.g. in another chat) is one click.
    socket =
      cond do
        fail == 0 ->
          clear_forward_carry(socket)

        ok == 0 ->
          put_flash(
            socket,
            :error,
            ngettext("Couldn't forward the message.", "Couldn't forward the messages.", fail)
          )

        true ->
          socket
          |> clear_forward_carry()
          |> put_flash(
            :error,
            ngettext(
              "Couldn't forward %{count} message.",
              "Couldn't forward %{count} messages.",
              fail,
              count: fail
            )
          )
      end

    {:noreply, socket}
  end

  defp clear_forward_carry(socket) do
    socket |> assign(pending_forward: nil) |> push_event("carry_clear", %{})
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

  defp selected_id(socket), do: socket.assigns.selected && socket.assigns.selected.id

  # The album optimistic client_ids — one per album a pick is split into (#193), as a list of
  # binaries (legacy single-id clients send a bare string; wrap it). Capped defensively.
  defp sanitize_album_ids(ids) when is_list(ids),
    do: ids |> Enum.filter(&is_binary/1) |> Enum.take(16)

  defp sanitize_album_ids(id) when is_binary(id), do: [id]
  defp sanitize_album_ids(_), do: []

  # Tell the hook to drop the exact optimistic media node for a send that produced
  # no real row (server error or no consumed entry), so it doesn't spin forever and
  # pin its preview data-URLs (#95). A nil id (no twin tracked) is a no-op.
  defp push_media_failed(socket, nil), do: socket
  defp push_media_failed(socket, id), do: push_event(socket, "media_failed", %{id: id})

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
        socket = ThreadPanel.cancel_staged_thread_attachments(socket)

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
              {:noreply, ThreadPanel.reset_reply_composer(socket)}

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
        socket = if client_id, do: socket, else: ThreadPanel.reset_reply_composer(socket)
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

  # A 1×1 transparent GIF: what a photo shows while its thumbnail is still being generated.
  # The geometry is already reserved by img_box + aspect-ratio, so nothing moves when the real
  # image lands over {:thumbnail_ready}.
  @pending_image "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"

  # Prefer the lighter thumbnail once it exists.
  #
  # Falling back to the ORIGINAL while the worker runs is what made a RECIPIENT download the
  # full-size photo: 321 KB on the reference 3840×2160 shot where the 92 KB thumbnail was about
  # to arrive a moment later over {:thumbnail_ready} — and an album of ten multiplied that. The
  # sender never saw it because their optimistic snapshot carries a data-URL; the recipient had
  # no such cover.
  #
  # The three states are answered by FACTS, not by age (#532 review): a thumbnail exists, or
  # generation is over and produced none (`thumb_failed`, set by the worker), or it is still
  # coming and the reserved box stands in. An earlier version guessed by `inserted_at`, which
  # expires only on a re-render — so a permanently failed thumbnail could leave a blank photo
  # for the rest of a session.
  # A mosaic tile's rendered width in CSS pixels. `.ed-album` is a definite 20rem and a row's
  # tiles split it in proportion to their aspect ratios (`flex:<aspect> 1 0`), so the width is
  # exactly `320 * aspect / sum` — the same arithmetic the browser is about to do. Rounded up:
  # under-stating the box makes the browser pick a candidate too small and the photo goes soft.
  @album_width 320
  defp tile_sizes(aspect, sum) when is_number(aspect) and is_number(sum) and sum > 0,
    do: "#{ceil(@album_width * aspect / sum)}px"

  defp tile_sizes(_aspect, _sum), do: nil

  # The tile-sized variant (#516): what every SMALL photo surface asks for — the file card's
  # 36px square, the edit-media tile, the lightbox reel's 44px strip. Falls back to `thumb_src`
  # so "no preview yet" and "preview failed" keep behaving exactly as before.
  defp thumb_small_src(%{thumbnail_key: key, id: id}) when is_binary(key),
    do: ~p"/files/#{id}/thumb/s"

  defp thumb_small_src(attachment), do: thumb_src(attachment)

  # Both candidates for a tile whose rendered width is not fixed. An album tile is 320 CSS px on
  # its own row and 105 three-across; a server that picks one size gets the other wrong, and at
  # 2x DPR the difference is either a soft photo or ten times the bytes. `srcset` hands the choice
  # to the only party that knows both the box and the device: the browser.
  #
  # Only when a preview exists — with none there is nothing to derive a variant from, and
  # `thumb_src` is already serving the original or a placeholder.
  defp thumb_srcset(%{thumbnail_key: key, id: id} = attachment) when is_binary(key) do
    small = candidate_width(attachment, Eden.Images.tile_width())
    wide = candidate_width(attachment, Chat.thumbnail_max())

    # No descriptors, no offer. Dimensions are best-effort at create (a video probed where ffmpeg
    # was unavailable has none), and a source no wider than the tile size makes both candidates
    # the same picture — offering a choice between identical images just costs a decision.
    if small && wide && small < wide do
      ~s(#{~p"/files/#{id}/thumb/s"} #{small}w, #{~p"/files/#{id}/thumb"} #{wide}w)
    end
  end

  defp thumb_srcset(_attachment), do: nil

  # What a candidate is ACTUALLY wide, which is what the `w` descriptor promises and what the
  # browser picks by. Both sizes fit the image into a SQUARE box — libvips `thumbnail` with one
  # dimension caps the long edge — so a portrait photo's preview is narrower than the cap:
  # 2160x3840 comes out 450x800, not 800 wide, and its tile variant 144x256, not 256.
  #
  # Declaring the cap instead told the browser those candidates had more pixels than they do, so
  # it settled for the wide one and rendered soft — the srcset quietly doing the opposite of its
  # job (#540 review). Verified against libvips across landscape, portrait and never-upscaled
  # sources, including the tile variant, which is derived from the preview rather than the
  # original and still lands on the same number.
  defp candidate_width(%{width: w, height: h}, cap)
       when is_integer(w) and is_integer(h) and w > 0 and h > 0,
       do: round(w * min(1.0, min(cap / w, cap / h)))

  defp candidate_width(_attachment, _cap), do: nil

  defp thumb_src(%{thumbnail_key: key, id: id}) when is_binary(key), do: ~p"/files/#{id}/thumb"
  defp thumb_src(%{thumb_failed: true, id: id}), do: ~p"/files/#{id}"
  defp thumb_src(%{id: _id}), do: @pending_image

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
