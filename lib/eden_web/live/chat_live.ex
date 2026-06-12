defmodule EdenWeb.ChatLive do
  @moduledoc """
  The chat: a conversation list (sidebar) and the selected conversation's message
  window. Realtime via Chat PubSub; the message collection is a LiveView stream
  with backward pagination. Everything is authorized through the Chat context
  using `current_scope`.
  """
  use EdenWeb, :live_view

  on_mount EdenWeb.RailHook

  import EdenWeb.ShellComponents

  alias Eden.{Accounts, Channels, Chat}

  @page 50
  # Bare http/https URLs in message text, turned into links (see linkify/1).
  @url_regex ~r{https?://[^\s<]+}i

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
        last_flat: nil,
        # Knock window (#41): a private room you're not in, reached by link.
        knock_room: nil,
        knock_pending: false
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
        max_entries: 1,
        max_file_size: Chat.max_attachment_bytes()
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
      knock_pending: false
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
      new_invite_url: nil
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
    {:noreply, assign(socket, composer: to_form(%{"body" => body}, as: "message"))}
  end

  def handle_event("send", %{"message" => %{"body" => body} = msg}, socket) do
    %{current_scope: scope, selected: conversation} = socket.assigns
    client_id = msg["client_id"]

    cond do
      is_nil(conversation) ->
        {:noreply, socket}

      socket.assigns.uploads.attachment.entries != [] ->
        send_attachment(socket, scope, conversation, body)

      String.trim(body) == "" ->
        {:noreply, assign(socket, composer: empty_composer())}

      true ->
        send_text(socket, scope, conversation, body, client_id)
    end
  end

  # Ignore malformed send payloads (e.g. a crafted event) instead of crashing.
  def handle_event("send", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :attachment, ref)}
  end

  def handle_event("load_more", _params, socket) do
    %{current_scope: scope, selected: conversation, oldest_id: oldest_id} = socket.assigns

    case conversation && oldest_id &&
           Chat.list_messages(scope, conversation.id, limit: @page, before: oldest_id) do
      {:ok, older} when older != [] ->
        {:noreply,
         socket
         |> stream(:messages, older, at: 0)
         |> assign(has_more: length(older) == @page, oldest_id: hd(older).id)}

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
    {:noreply, assign(socket, show_channel_edit: false)}
  end

  def handle_event("save_channel", %{"channel" => params}, socket) do
    case Channels.update_channel(socket.assigns.current_scope, socket.assigns.channel.id, params) do
      {:ok, channel} ->
        {:noreply,
         assign(socket, channel: channel, show_channel_edit: false, page_title: channel.name)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, channel_form: to_form(changeset))}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(show_channel_edit: false)
         |> put_flash(:error, gettext("Couldn't update that channel."))}
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
    {:noreply, assign(socket, thread_root: nil)}
  end

  # Jump to the thread's root in the main stream: close the panel (on mobile it
  # covers the stream) and focus-highlight the root, reusing the permalink path.
  def handle_event("jump_to_root", _params, socket) do
    case socket.assigns.thread_root do
      %{id: id} ->
        {:noreply,
         socket
         |> assign(thread_root: nil)
         |> push_event("focus_message", %{domId: "messages-#{id}"})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("reply_changed", %{"reply" => %{"body" => body}}, socket) do
    {:noreply, assign(socket, reply_composer: to_form(%{"body" => body}, as: "reply"))}
  end

  def handle_event("send_reply", %{"reply" => %{"body" => body}}, socket) do
    root = socket.assigns.thread_root

    if is_nil(root) or String.trim(body) == "" do
      {:noreply, socket}
    else
      case Chat.create_reply(socket.assigns.current_scope, root.id, %{"body" => body}) do
        {:ok, _reply} ->
          # The reply itself arrives via the {:thread_reply} broadcast.
          {:noreply, assign(socket, reply_composer: to_form(%{"body" => ""}, as: "reply"))}

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

    {:noreply, stream_insert(socket, :messages, message)}
  end

  # A reply landed in a thread of the open conversation: refresh the root's
  # footer (count/time/facepile) and append to the panel if it's open.
  def handle_info({:thread_reply, root, reply}, socket) do
    socket =
      if open?(socket, root.conversation_id) do
        socket
        |> stream_insert(:messages, root)
        |> bump_facepile(root.id, reply.sender)
      else
        socket
      end

    if thread_open_for?(socket, root.id) do
      {:noreply, socket |> assign(thread_root: root) |> stream_insert(:thread, reply)}
    else
      {:noreply, socket}
    end
  end

  # A reply was deleted for everyone: the root's footer changed.
  def handle_info({:thread_updated, root}, socket) do
    socket =
      if open?(socket, root.conversation_id) do
        participants =
          Chat.thread_participants(socket.assigns.current_scope, root.conversation_id, [root.id])

        socket
        |> stream_insert(:messages, root)
        |> assign(
          :thread_participants,
          Map.merge(socket.assigns.thread_participants, participants)
        )
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
  def handle_info({:message_deleted, message}, socket) do
    if open?(socket, message.conversation_id) do
      {:noreply,
       socket
       |> stream_delete_by_dom_id(:messages, "messages-#{message.id}")
       |> stream_delete_by_dom_id(:thread, "thread-#{message.id}")
       |> close_thread_if_root_gone(message.id)}
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
      {:noreply, stream_insert(socket, :messages, message)}
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

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply, assign(socket, online_ids: EdenWeb.Presence.online_ids())}
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

        <div class="flex-1 overflow-y-auto p-2 space-y-0.5">
          <.room_item
            :for={room <- @rooms}
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
        class={["flex-1 flex flex-col min-w-0", !@selected && "hidden md:flex"]}
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
              <span class="ed-room__hash" style="font-size:1.125rem;">#</span>
              <div class="min-w-0">
                <div class="font-semibold truncate" style="font-size:0.9375rem;">
                  {@selected.name}
                </div>
                <div :if={@channel} style="font-size:0.6875rem; color: var(--ed-muted);">
                  {@channel.name}
                </div>
              </div>
            </div>
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

          <div class="flex-1 overflow-y-auto p-4" id="message-scroll" phx-hook=".ScrollBottom">
            <div :if={@has_more} class="text-center mb-3">
              <button class="ed-btn ed-btn--ghost" phx-click="load_more">
                {gettext("Load older")}
              </button>
            </div>
            <div
              class={["flex flex-col", (@selected.channel_id && "ed-flat-list") || "gap-2"]}
              id="messages"
              phx-update="stream"
            >
              <%= for {dom_id, message} <- @streams.messages do %>
                <%= if @selected.channel_id do %>
                  <.flat_message
                    id={dom_id}
                    message={message}
                    conversation_id={@selected.id}
                    mine={message.sender_id == @current_scope.user.id}
                    participants={Map.get(@thread_participants, message.id, [])}
                    admin={@channel && @channel.role in ~w(owner admin)}
                  />
                <% else %>
                  <.message_bubble
                    id={dom_id}
                    message={message}
                    conversation_id={@selected.id}
                    mine={message.sender_id == @current_scope.user.id}
                    group={@selected.is_group}
                    read={read?(message, @other_read_at)}
                  />
                <% end %>
              <% end %>
            </div>
            <%!-- Optimistic, not-yet-acked sends live here (JS-managed; LiveView leaves it alone). --%>
            <div class="flex flex-col gap-2 mt-2" id="pending-messages" phx-update="ignore"></div>
          </div>

          <.form
            for={@composer}
            id="composer"
            phx-hook=".SendQueue"
            data-conversation-id={@selected.id}
            data-layout={if @selected.channel_id, do: "flat", else: "bubble"}
            data-sender-id={@current_scope.user.id}
            data-sender-name={@current_scope.user.display_name}
            phx-submit="send"
            phx-change="composer_changed"
            class="flex flex-col gap-2 p-3 border-t shrink-0"
            style="border-color: var(--ed-border);"
          >
            <div
              :for={entry <- @uploads.attachment.entries}
              data-upload-preview
              class="flex items-center gap-3"
            >
              <.live_img_preview
                :if={image_entry?(entry)}
                entry={entry}
                class="rounded-[var(--ed-radius)] object-cover shrink-0"
                style="width:3rem; height:3rem;"
              />
              <span
                :if={!image_entry?(entry)}
                class="ed-file-chip shrink-0"
                aria-hidden="true"
              >
                <.icon name={entry_icon(entry)} class="size-5" />
              </span>
              <span class="flex-1 min-w-0">
                <span class="block truncate" style="font-size:0.8125rem;">{entry.client_name}</span>
                <span class="block" style="font-size:0.75rem; color: var(--ed-muted);">
                  {human_size(entry.client_size)}
                </span>
              </span>
              <span
                :for={err <- upload_errors(@uploads.attachment, entry)}
                style="font-size:0.75rem; color: var(--ed-danger);"
              >
                {upload_error_text(err)}
              </span>
              <button
                type="button"
                class="ed-btn--icon"
                phx-click="cancel_upload"
                phx-value-ref={entry.ref}
                aria-label={gettext("Remove")}
              >
                <.icon name="hero-x-mark-mini" class="size-5" />
              </button>
            </div>

            <div class="flex items-center gap-2">
              <label class="ed-btn--icon cursor-pointer" aria-label={gettext("Attach a file")}>
                <.icon name="hero-paper-clip-micro" class="size-5" />
                <%!-- sr-only (not hidden) keeps the input focusable so the control is keyboard-reachable. --%>
                <.live_file_input upload={@uploads.attachment} class="sr-only" />
              </label>
              <input
                type="text"
                name="message[body]"
                value={@composer[:body].value}
                class="ed-input"
                placeholder={gettext("Message")}
                autocomplete="off"
              />
              <button
                class="ed-btn ed-btn--primary shrink-0"
                style="width:2.5rem; padding:0; border-radius:var(--ed-radius-full);"
                type="submit"
                aria-label={gettext("Send")}
              >
                <.icon name="hero-paper-airplane-micro" class="size-4" />
              </button>
            </div>
          </.form>
        <% else %>
          <div class="flex-1 grid place-items-center text-center p-8">
            <%!-- Knock window: a private room reached by link that you're not in. --%>
            <div :if={@knock_room} class="space-y-3 max-w-sm">
              <span class="ed-room__hash" style="font-size:1.75rem;">🔒</span>
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
            <div :if={@channel && is_nil(@knock_room)} class="space-y-2 max-w-sm">
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

        <div class="flex-1 overflow-y-auto p-4" id="thread-scroll" phx-hook=".ScrollBottom">
          <%!-- in_thread: the "N replies" separator right below makes the
                root's own footer pill redundant. --%>
          <.flat_message
            id={"thread-root-#{@thread_root.id}"}
            message={%{@thread_root | compact: false}}
            conversation_id={@selected.id}
            mine={@thread_root.sender_id == @current_scope.user.id}
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
              in_thread
            />
          </div>
        </div>

        <.form
          for={@reply_composer}
          id="reply-composer"
          phx-change="reply_changed"
          phx-submit="send_reply"
          class="p-3 border-t shrink-0"
          style="border-color: var(--ed-border);"
        >
          <div class="flex items-center gap-2">
            <input
              type="text"
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
      />
      <.room_form_modal
        :if={@room_modal}
        title={if @room_modal == :new, do: gettext("New room"), else: gettext("Rename room")}
        form={@room_form}
        submit_label={if @room_modal == :new, do: gettext("Create room"), else: gettext("Save")}
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
            this.toBottom()
            // Permalink: scroll to and briefly highlight a message, or report it's gone.
            this.handleEvent("focus_message", ({ domId }) => {
              const el = document.getElementById(domId)
              if (!el) { this.pushEvent("message_unavailable"); return }
              el.scrollIntoView({ block: "center", behavior: "smooth" })
              el.classList.add("ed-msg--focus")
              setTimeout(() => el.classList.remove("ed-msg--focus"), 2200)
            })
            // Rise-in for messages added AFTER mount only — the initial list is
            // already in the DOM when the observer starts, so it never animates
            // (no page-load choreography). Optimistic pending nodes (data-client-id)
            // appear instantly; their real replacement animates once, no double.
            this.riser = new MutationObserver((muts) => {
              for (const mut of muts) {
                for (const node of mut.addedNodes) {
                  if (node.nodeType !== 1) continue
                  const row = node.matches?.(".ed-msg, .ed-flat") ? node
                    : node.querySelector?.(".ed-msg, .ed-flat")
                  if (!row || row.dataset.clientId) continue
                  row.classList.add("ed-msg--enter")
                  setTimeout(() => row.classList.remove("ed-msg--enter"), 200)
                }
              }
            })
            this.riser.observe(this.el, { childList: true, subtree: true })
          },
          beforeUpdate() {
            this.pinned = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 48
          },
          updated() { if (this.pinned) this.toBottom() },
          destroyed() { this.riser && this.riser.disconnect() },
          toBottom() { this.el.scrollTop = this.el.scrollHeight }
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
            // Capture phase so a scroll in ANY ancestor container closes the menu.
            this.onScroll = () => this.close()
            this.wire()

            // Desktop: right-click the host. A keyboard context-menu (Shift+F10 /
            // Menu key) reports clientX/Y 0 — fall back to the host's top-left.
            this.el.addEventListener("contextmenu", (e) => {
              e.preventDefault()
              const r = this.el.getBoundingClientRect()
              this.open(e.clientX || r.left + 8, e.clientY || r.top + 8)
            })

            // Touch: long-press (cancel if the finger moves — that's a scroll/select).
            let timer, sx, sy
            this.el.addEventListener("touchstart", (e) => {
              const t = e.touches[0]; sx = t.clientX; sy = t.clientY
              timer = setTimeout(() => { this.open(sx, sy); this.longPressed = true }, 450)
            }, { passive: true })
            const cancel = () => clearTimeout(timer)
            this.el.addEventListener("touchmove", (e) => {
              const t = e.touches[0]
              if (Math.abs(t.clientX - sx) > 10 || Math.abs(t.clientY - sy) > 10) cancel()
            }, { passive: true })
            this.el.addEventListener("touchend", cancel)
            // Swallow the click/navigation a long-press would otherwise fire
            // (a photo opening, or following a sidebar chat link).
            this.el.addEventListener("click", (e) => {
              if (this.longPressed) { e.preventDefault(); e.stopPropagation(); this.longPressed = false }
            }, true)
          },
          // A stream re-render morphs the item; re-bind the (possibly new) menu node
          // and restore the open state the server render doesn't know about.
          updated() {
            this.wire()
            if (active === this) { this.menu.hidden = false; this.position(this.x, this.y) }
          },
          destroyed() { this.close() },
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
            const ct = e.target.closest("[data-copy-text]")
            const cl = e.target.closest("[data-copy-link]")
            if (ct) this.copy(ct.dataset.text, "text")
            else if (cl) this.copy(cl.dataset.link, "link")
            // Forward/delete dispatch to the server; either way the menu closes.
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
            // Photos go through the normal phx-submit (they carry an upload).
            if (this.el.querySelector("[data-upload-preview]")) return
            // Take over text sends: stop the event reaching LiveView's delegated
            // phx-submit so the message isn't also sent without a client_id.
            e.preventDefault()
            e.stopPropagation()
            const body = (this.input.value || "").trim()
            if (!body) return
            const clientId = crypto.randomUUID()
            this.input.value = ""
            this.addOptimistic(clientId, body)
            this.queue.push({ clientId, body, sent: false })
            this.flush()
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
                if (reply && reply.nack) this.markFailed(item.clientId)
                else this.remove(item.clientId)
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
              row.className = "flex justify-end"
              const bubble = document.createElement("div")
              bubble.className = "ed-bubble ed-bubble--me"
              bubble.style.opacity = "0.55"
              bubble.textContent = body
              row.appendChild(bubble)
            }
            this.pending.appendChild(row)
            if (this.scroller) this.scroller.scrollTop = this.scroller.scrollHeight
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
          remove(clientId) {
            const node = this.pending.querySelector(`[data-client-id="${clientId}"]`)
            if (node) node.remove()
          },
          markFailed(clientId) {
            const node = this.pending.querySelector(`[data-client-id="${clientId}"]`)
            if (!node) return
            node.style.opacity = "1"
            const target = node.querySelector(".ed-bubble") || node.querySelector(".ed-flat__body")
            if (target) target.style.border = "1px solid var(--ed-danger)"
          },
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".Lightbox">
        // In-app image viewer: click a photo to open it full-screen in a single
        // shared overlay (close on backdrop click or Esc). Cmd/Ctrl/Shift/middle
        // click fall through to the normal "open original in a new tab".
        export default {
          mounted() {
            this.el.addEventListener("click", (e) => {
              if (e.metaKey || e.ctrlKey || e.shiftKey || e.button === 1) return
              e.preventDefault()
              this.openLightbox(this.el.dataset.full)
            })
          },
          openLightbox(src) {
            let box = document.getElementById("ed-lightbox")
            if (!box) {
              box = document.createElement("div")
              box.id = "ed-lightbox"
              box.className = "ed-lightbox"
              const img = document.createElement("img")
              img.alt = ""
              box.appendChild(img)
              const close = () => {
                box.classList.remove("ed-lightbox--open")
                document.body.style.overflow = ""
                document.removeEventListener("keydown", box.__onKey)
              }
              box.__onKey = (e) => { if (e.key === "Escape") close() }
              box.addEventListener("click", close)
              document.body.appendChild(box)
            }
            box.querySelector("img").src = src
            box.classList.add("ed-lightbox--open")
            document.body.style.overflow = "hidden"
            document.addEventListener("keydown", box.__onKey)
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
    <div id={@id} class="ed-convo-wrap" phx-hook=".ContextMenu">
      <.link
        patch={~p"/channels/#{@channel.id}/r/#{@room.id}"}
        class={["ed-convo ed-room", @active && "ed-convo--active"]}
        aria-haspopup="menu"
      >
        <span class="ed-room__hash">#</span>
        <span class="ed-convo__name flex-1 truncate">
          {@room.name}
          <span :if={@room.muted} class="ed-convo__muted">
            <.icon name="hero-bell-slash-micro" class="size-3.5" />
            <span class="sr-only">{gettext("Muted")}</span>
          </span>
        </span>
        <span :if={@room.unread_count > 0} class={["ed-badge", @room.muted && "ed-badge--muted"]}>
          {@room.unread_count}
        </span>
      </.link>
      <div class="ed-menu" id={"room-menu-#{@room.id}"} data-menu role="menu" hidden>
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
          :if={@admin}
          type="button"
          class="ed-menu__item"
          role="menuitem"
          phx-click="open_room_rename"
          phx-value-id={@room.id}
        >
          <.icon name="hero-pencil-micro" class="size-4" /> {gettext("Rename room")}
        </button>
        <div :if={@admin} class="ed-menu__sep"></div>
        <button
          :if={@admin}
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

  # Create/rename room modal — one name field.
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
            <div class="flex justify-end">
              <button type="submit" class="ed-btn ed-btn--primary">{@submit_label}</button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end

  # Sidebar preview line. An attachment shows "<emoji> <caption|kind>" so the row
  # is never blank (keeps item height + the time position consistent).
  defp convo_preview(%{last_message_kind: kind} = conversation)
       when kind in ~w(image video file) do
    {emoji, label} = attachment_label(kind)
    caption = conversation.last_message_body
    emoji <> " " <> if(is_binary(caption) and caption != "", do: caption, else: label)
  end

  defp convo_preview(%{last_message_body: body}) when is_binary(body) and body != "", do: body
  defp convo_preview(_conversation), do: gettext("No messages yet")

  defp attachment_label("image"), do: {"📷", gettext("Photo")}
  defp attachment_label("video"), do: {"🎬", gettext("Video")}
  defp attachment_label("file"), do: {"📎", gettext("File")}

  attr :id, :string, required: true
  attr :message, :map, required: true
  attr :conversation_id, :any, required: true
  attr :mine, :boolean, required: true
  attr :participants, :list, default: []
  attr :in_thread, :boolean, default: false
  attr :menu, :boolean, default: true
  attr :admin, :boolean, default: false

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
      <span :if={@message.meta["status"] == "accepted"} class="ed-sysmsg__done">
        {gettext("Added")}
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
        <span :if={@message.forwarded_from} class="ed-forwarded">
          <.icon name="hero-arrow-uturn-right-micro" class="size-3" />
          {forwarded_label(@message.forwarded_from)}
        </span>
        <.attachment_view :if={@message.attachment} attachment={@message.attachment} />
        <div :if={@message.body != ""} class="break-words ed-flat__body">
          <.body_part :for={part <- linkify(@message.body)} part={part} />
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
          <span :if={@message.last_reply_at} class="ed-thread-footer__time">
            <.local_time at={@message.last_reply_at} />
          </span>
        </button>
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
        in_thread={@in_thread}
      />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :message, :map, required: true
  attr :conversation_id, :any, required: true
  attr :mine, :boolean, required: true
  attr :group, :boolean, required: true
  attr :read, :boolean, required: true

  defp message_bubble(assigns) do
    ~H"""
    <div id={@id} class={["ed-msg flex", @mine && "justify-end"]}>
      <div
        class={["ed-bubble", (@mine && "ed-bubble--me") || "ed-bubble--them"]}
        id={"bubble-#{@message.id}"}
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
        <span :if={@message.forwarded_from} class="ed-forwarded">
          <.icon name="hero-arrow-uturn-right-micro" class="size-3" />
          {forwarded_label(@message.forwarded_from)}
        </span>
        <.attachment_view :if={@message.attachment} attachment={@message.attachment} />
        <span :if={@message.body != ""} class="break-words">
          <.body_part
            :for={part <- linkify(@message.body)}
            part={part}
          />
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
        <button
          :if={@message.reply_count > 0}
          type="button"
          class="ed-bubble__thread"
          phx-click="open_thread"
          phx-value-id={@message.id}
        >
          <.icon name="hero-chat-bubble-left-micro" class="size-3.5" />
          {ngettext("%{count} reply", "%{count} replies", @message.reply_count)}
        </button>
        <.message_menu
          message={@message}
          conversation_id={@conversation_id}
          mine={@mine}
        />
      </div>
    </div>
    """
  end

  attr :message, :map, required: true
  attr :conversation_id, :any, required: true
  attr :mine, :boolean, required: true
  attr :in_thread, :boolean, default: false

  # The message context menu — opened by right-click / long-press on the bubble
  # (the `.ContextMenu` hook). Copy actions run client-side; forward/delete dispatch
  # to the LiveView. The hook re-applies the open state after a re-render, so no
  # phx-update="ignore" is needed and item labels stay free to change.
  defp message_menu(assigns) do
    ~H"""
    <div class="ed-menu" id={"menu-#{@message.id}"} data-menu role="menu" hidden>
      <button
        :if={not @in_thread and is_nil(@message.root_id)}
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

  attr :attachment, :map, required: true

  # Renders an attachment by kind: a lightbox-able image, an in-app video player,
  # or a download card for a generic file.
  defp attachment_view(%{attachment: %{kind: "image"}} = assigns) do
    ~H"""
    <a
      id={"att-#{@attachment.id}"}
      phx-hook=".Lightbox"
      data-full={~p"/files/#{@attachment.id}"}
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
        style="max-width:min(20rem,100%); max-height:20rem; width:auto; height:auto;"
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

  attr :part, :any, required: true

  # Renders one piece of a linkified message body: a link or escaped text.
  defp body_part(%{part: {:link, url}} = assigns) do
    assigns = assign(assigns, :url, url)

    ~H"""
    <a class="ed-link" href={@url} target="_blank" rel="noopener noreferrer">{@url}</a>
    """
  end

  defp body_part(%{part: {:text, text}} = assigns) do
    assigns = assign(assigns, :text, text)
    ~H"{@text}"
  end

  # Split message text into `{:text, _}` / `{:link, url}` parts, turning bare
  # http(s) URLs into links. Trailing sentence punctuation stays as text. The URL
  # only ever feeds an `href`/text node that HEEx escapes, so there's no XSS path.
  defp linkify(text) do
    @url_regex
    |> Regex.split(text, include_captures: true)
    |> Enum.flat_map(&classify_body_part/1)
  end

  defp classify_body_part(""), do: []

  defp classify_body_part(part) do
    if String.starts_with?(part, ["http://", "https://"]) do
      {url, trailing} = strip_trailing_punct(part)
      [{:link, url} | if(trailing == "", do: [], else: [{:text, trailing}])]
    else
      [{:text, part}]
    end
  end

  defp strip_trailing_punct(url) do
    trimmed = Regex.replace(~r/[.,;:!?)\]}'"]+$/u, url, "")
    {trimmed, String.replace_prefix(url, trimmed, "")}
  end

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
    |> assign(
      selected: conversation,
      subscribed_id: conversation.id,
      other_read_at: other_read_at(conversation, scope.user),
      has_more: length(messages) == @page,
      oldest_id: messages |> List.first() |> then(&(&1 && &1.id)),
      thread_root: nil,
      last_flat: last_flat,
      thread_participants: facepiles(scope, conversation, messages)
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
      convos = Chat.list_conversations(socket.assigns.current_scope, socket.assigns.folder_id)
      stream(socket, :conversations, convos, opts)
    end
  end

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
    case Chat.list_thread(socket.assigns.current_scope, root_id) do
      {:ok, root, replies} ->
        socket
        |> assign(
          thread_root: root,
          reply_composer: to_form(%{"body" => ""}, as: "reply")
        )
        |> stream(:thread, replies, reset: true)

      {:error, _} ->
        put_flash(socket, :error, gettext("Thread not found."))
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
    assign(socket, subscribed_id: nil)
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

  defp send_text(socket, scope, conversation, body, client_id \\ nil) do
    case Chat.create_message(scope, conversation.id, %{"body" => body, "client_id" => client_id}) do
      {:ok, _message} ->
        # The form path clears the input via the composer assign; the hook path
        # (client_id present) already cleared it client-side, so leave the assign
        # alone to avoid clobbering text typed during a slow round-trip.
        socket = if client_id, do: socket, else: assign(socket, composer: empty_composer())
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

  defp send_attachment(socket, scope, conversation, body) do
    # Store + persist inside the consume callback, while the temp file exists.
    results =
      consume_uploaded_entries(socket, :attachment, fn %{path: path}, entry ->
        {:ok,
         Chat.create_attachment_message(scope, conversation.id, %{
           path: path,
           body: body,
           filename: entry.client_name
         })}
      end)

    case results do
      [{:ok, _message}] ->
        {:noreply, assign(socket, composer: empty_composer())}

      [{:error, reason}] ->
        {:noreply, put_flash(socket, :error, attachment_error(reason))}

      # No entry was consumed (the file is still uploading or failed client-side
      # validation). Don't drop a caption the user already typed.
      [] ->
        if String.trim(body) == "",
          do: {:noreply, socket},
          else: send_text(socket, scope, conversation, body)
    end
  end

  defp attachment_error(:too_large), do: gettext("That file is too large.")
  defp attachment_error(:empty), do: gettext("That file is empty.")
  defp attachment_error(_other), do: gettext("Couldn't send that file.")

  # Client-side upload validation errors surfaced by `allow_upload/3`.
  defp upload_error_text(:too_large), do: gettext("File too large")
  defp upload_error_text(:too_many_files), do: gettext("One file at a time")
  defp upload_error_text(_other), do: gettext("Invalid file")

  # Prefer the lighter thumbnail once it exists; fall back to the original while
  # the worker is still generating it.
  defp thumb_src(%{thumbnail_key: key, id: id}) when is_binary(key), do: ~p"/files/#{id}/thumb"
  defp thumb_src(%{id: id}), do: ~p"/files/#{id}"

  # Composer upload entry helpers (client-side; for preview only, not trusted).
  defp image_entry?(%{client_type: "image/" <> _}), do: true
  defp image_entry?(_entry), do: false

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
end
