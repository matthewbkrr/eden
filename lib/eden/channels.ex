defmodule Eden.Channels do
  @moduledoc """
  The Channels context: corporate containers (≈ Mattermost teams / Discord
  servers) with per-user roles. Thematic chat rooms inside a channel live in
  the Chat context as conversations bound to a channel (#29); this context owns
  the containers, membership, and roles.

  Authorization mirrors Chat: every function takes a `%Scope{}`. Non-members
  get `{:error, :not_found}` (existence is not leaked); members lacking the
  required role get `{:error, :forbidden}`. Realtime: channel-scoped events
  broadcast on `channel:<id>` (subscribe only after `get_channel/2`
  authorized access); rail-level changes ping each member's
  `user:<id>:channels` topic with `:channels_changed`.
  """
  import Ecto.Query, warn: false

  alias Eden.Accounts
  alias Eden.Accounts.{Scope, User}
  alias Eden.Channels.{Channel, Invite, Membership}
  alias Eden.Chat
  alias Eden.Ids
  alias Eden.Images
  alias Eden.Notifications
  alias Eden.Repo
  alias Eden.Storage

  @pubsub Eden.PubSub

  # Sanity cap on channels a single user can CREATE (counted by `creator_id`, which never
  # changes — like folders): an anti-flood guard on creation, deliberately NOT a cap on
  # channels currently owned. `transfer_ownership/3` moves the `owner` role but not
  # `creator_id`, so the two can diverge; that's intended (#358/R117 — the guard is about
  # who spammed the rail into existence, not who holds it now).
  @max_channels 20

  @doc "Most channels one user can create (`create_channel/2` returns `{:error, :limit}` beyond it)."
  def max_channels, do: @max_channels

  @doc "A changeset for channel forms (create / rename)."
  def change_channel(%Channel{} = channel \\ %Channel{}, attrs \\ %{}),
    do: Channel.changeset(channel, attrs)

  ## Channels

  @doc """
  Creates a channel; the creator becomes its `owner` (Mattermost: the team
  creator becomes Team Admin). Returns `{:ok, channel}` (with the virtual
  `role` filled), `{:error, changeset}`, or `{:error, :limit}`.
  """
  def create_channel(%Scope{user: user}, attrs) do
    created = Repo.aggregate(from(c in Channel, where: c.creator_id == ^user.id), :count)

    if created >= @max_channels do
      {:error, :limit}
    else
      case insert_channel_with_owner(user, attrs) do
        {:ok, channel} ->
          broadcast_user(user.id, :channels_changed)
          {:ok, %{channel | role: "owner"}}

        error ->
          error
      end
    end
  end

  defp insert_channel_with_owner(user, attrs) do
    Repo.transact(fn ->
      with {:ok, channel} <-
             %Channel{creator_id: user.id} |> Channel.changeset(attrs) |> Repo.insert(),
           {:ok, _membership} <- insert_membership(channel.id, user.id, "owner"),
           # Every channel starts usable: the general room (Town Square), marked
           # is_general so the join/undeletable/open guards have one source.
           {:ok, _room} <-
             Chat.create_room(channel.id, %{"name" => "general"}, [user.id], is_general: true) do
        {:ok, channel}
      end
    end)
  end

  @doc """
  Channels the scoped user belongs to (creation order), each with the virtual
  `role`, `muted` flag, and `unread_count` (rail badge: aggregate of the user's
  joined-room unreads, room-mute-aware) filled.
  """
  def list_channels(%Scope{user: user} = scope) do
    unread = Chat.channel_unread_counts(scope)

    rows =
      from(c in Channel,
        join: m in Membership,
        on: m.channel_id == c.id and m.user_id == ^user.id,
        order_by: [asc: c.id],
        select: {c, m.role, m.muted_at, m.last_room_id}
      )
      |> Repo.all()

    # The rail links each channel to its entry room (#81): the last room opened,
    # or general — resolved against the user's current room memberships.
    entry = Chat.entry_room_ids(scope, Map.new(rows, fn {c, _r, _m, last} -> {c.id, last} end))

    Enum.map(rows, fn {channel, role, muted_at, _last} ->
      %{
        channel
        | role: role,
          muted: not is_nil(muted_at),
          unread_count: Map.get(unread, channel.id, 0),
          entry_room_id: Map.get(entry, channel.id)
      }
    end)
  end

  @doc """
  Toggles the scoped user's mute on a channel (badge-only). Pings the user's
  other sessions with `:channels_changed` so every rail refreshes. Returns
  `{:ok, muted?}` or `{:error, :not_found}`.
  """
  def toggle_channel_mute(%Scope{user: user}, channel_id) do
    with id when is_integer(id) <- Ids.normalize(channel_id),
         %Membership{} = membership <-
           Repo.one(from m in Membership, where: m.channel_id == ^id and m.user_id == ^user.id) do
      muted_at = if membership.muted_at, do: nil, else: now()

      # update_all (not Repo.update on the struct): a no-op, not a
      # StaleEntryError crash, if the membership vanished concurrently — e.g.
      # the user was removed from the channel mid-click.
      Repo.update_all(from(m in Membership, where: m.id == ^membership.id),
        set: [muted_at: muted_at]
      )

      broadcast_user(user.id, :channels_changed)
      {:ok, not is_nil(muted_at)}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  User ids who have muted `channel_id` (badge-only channel mute). Public so the
  notification fan-out in `Eden.Chat` can drop them from a room message's recipients
  **server-side** (#271) — channel mute is Channels data, so Chat asks through this
  function rather than reaching into `channel_memberships`. Trusted caller (no `Scope`):
  the fan-out has already scoped who's eligible; this only subtracts muters.
  """
  def muted_user_ids(channel_id) do
    Repo.all(
      from m in Membership,
        where: m.channel_id == ^channel_id and not is_nil(m.muted_at),
        select: m.user_id
    )
  end

  @doc """
  Records the scoped user's last-opened `room_id` for `channel_id` (#81) so
  re-entering the channel reopens it (see `list_channels/1`'s `entry_room_id`).
  `update_all` — a no-op (not a `StaleEntryError`) if the membership vanished
  concurrently, and skips non-members. Always `:ok`.
  """
  def record_last_room(%Scope{user: user}, channel_id, room_id) do
    Repo.update_all(
      from(m in Membership, where: m.channel_id == ^channel_id and m.user_id == ^user.id),
      set: [last_room_id: room_id]
    )

    :ok
  end

  @doc "Fetches a channel the scoped user belongs to (virtual `role` filled), or `{:error, :not_found}`."
  def get_channel(%Scope{user: user}, channel_id) do
    with id when is_integer(id) <- Ids.normalize(channel_id),
         {channel, role} <-
           Repo.one(
             from c in Channel,
               join: m in Membership,
               on: m.channel_id == c.id and m.user_id == ^user.id,
               where: c.id == ^id,
               select: {c, m.role}
           ) do
      {:ok, %{channel | role: role}}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Ensures the scoped user is a member of the channel and returns it (#41:
  channels are never closed — following any link auto-joins, landing the user
  in `general`). `{:error, :not_found}` only when the channel doesn't exist.
  Idempotent: an existing member just gets the channel back.
  """
  def ensure_member(%Scope{} = scope, channel_id) do
    case get_channel(scope, channel_id) do
      {:ok, channel} -> {:ok, channel}
      {:error, :not_found} -> auto_join(scope, channel_id)
    end
  end

  # Join an existing channel the user isn't in yet (the #41 auto-join). A
  # missing channel stays :not_found — existence isn't leaked.
  defp auto_join(%Scope{user: user} = scope, channel_id) do
    with id when is_integer(id) <- Ids.normalize(channel_id),
         true <- Repo.exists?(from c in Channel, where: c.id == ^id) do
      {:ok, joined} = Repo.transact(fn -> {:ok, join_channel_tx(id, user.id)} end)
      if joined, do: announce_join(id, user.id)
      get_channel(scope, id)
    else
      _ -> {:error, :not_found}
    end
  end

  defp announce_join(channel_id, user_id) do
    broadcast_user(user_id, :channels_changed)
    broadcast_channel(channel_id, {:members_changed, channel_id})
  end

  @doc """
  Updates a channel's name/about. Requires admin or owner. Broadcasts
  `{:channel_renamed, channel}` on the channel topic and pings every member's
  rail. `{:error, :not_found | :forbidden | changeset}`.
  """
  def update_channel(%Scope{} = scope, channel_id, attrs) do
    with {:ok, channel} <- get_channel(scope, channel_id),
         :ok <- ensure_role(channel.role, ~w(owner admin)),
         {:ok, updated} <- apply_update(channel, attrs) do
      updated = %{updated | role: channel.role}
      broadcast_channel(updated.id, {:channel_renamed, updated})
      notify_members(updated.id, :channels_changed)
      {:ok, updated}
    end
  end

  # stale_error_field: a channel deleted between the read and the write becomes
  # {:error, :not_found} instead of an Ecto.StaleEntryError crash (same class as
  # the folder/mute toggle races fixed in #23/#24 reviews).
  defp apply_update(channel, attrs) do
    channel
    |> Channel.changeset(attrs)
    |> Repo.update(stale_error_field: :id)
    |> normalize_stale()
  end

  defp normalize_stale({:error, %Ecto.Changeset{errors: errors} = changeset}) do
    # :id is never cast, so an error there can only be the stale marker.
    if Keyword.has_key?(errors, :id), do: {:error, :not_found}, else: {:error, changeset}
  end

  defp normalize_stale(result), do: result

  @doc """
  Sets a channel's avatar (#70). Admin or owner. Processes the upload into a
  square JPEG (shared `Eden.Images`), stores it via the adapter, swaps
  `avatar_key`, deletes the previous blob, and pings every member's rail.
  `source_path` is a local temp file. `{:error, :not_found | :forbidden |
  :too_large | :unprocessable}`.
  """
  def set_channel_avatar(%Scope{} = scope, channel_id, source_path) do
    with {:ok, channel} <- get_channel(scope, channel_id),
         :ok <- ensure_role(channel.role, ~w(owner admin)),
         {:ok, jpeg} <- Images.square_avatar(source_path) do
      store_and_swap_avatar(channel, jpeg)
    end
  end

  defp store_and_swap_avatar(channel, jpeg) do
    key = Storage.build_key("avatars", "jpg")

    with :ok <- Storage.put_binary(key, jpeg),
         {:ok, updated} <- put_avatar_key(channel, key) do
      # Best-effort cleanup of the replaced blob (don't fail the update on it).
      if channel.avatar_key, do: Storage.delete(channel.avatar_key)
      notify_members(updated.id, :channels_changed)
      {:ok, %{updated | role: channel.role}}
    else
      error ->
        # The new blob may be written but the row update failed (e.g. the channel
        # was deleted mid-flight) — reclaim it so it isn't orphaned.
        Storage.delete(key)
        error
    end
  end

  @doc "Removes a channel's avatar (and its blob). Admin or owner."
  def remove_channel_avatar(%Scope{} = scope, channel_id) do
    with {:ok, channel} <- get_channel(scope, channel_id),
         :ok <- ensure_role(channel.role, ~w(owner admin)),
         {:ok, updated} <- put_avatar_key(channel, nil) do
      if channel.avatar_key, do: Storage.delete(channel.avatar_key)
      notify_members(updated.id, :channels_changed)
      {:ok, %{updated | role: channel.role}}
    end
  end

  # Swap a channel's avatar_key, race-safely: a concurrent delete between the read
  # and the write becomes {:error, :not_found}, not an Ecto.StaleEntryError crash
  # — same convention as update_channel/3.
  defp put_avatar_key(channel, key) do
    channel
    |> Ecto.Changeset.change(avatar_key: key)
    |> Repo.update(stale_error_field: :id)
    |> normalize_stale()
  end

  @doc """
  Deletes a channel. Owner only. Member rails refresh via `:channels_changed`;
  sessions inside the channel get `{:channel_deleted, id}` on the channel topic.
  Rooms cascade by FK; their attachment blobs and the channel's own avatar blob
  are reclaimed (forward-safely) after the delete commits.
  """
  def delete_channel(%Scope{} = scope, channel_id) do
    with {:ok, channel} <- get_channel(scope, channel_id),
         :ok <- ensure_role(channel.role, ~w(owner)) do
      delete_channel_record(channel)
    end
  end

  # The blob-reclaiming, broadcast-emitting delete, factored out of delete_channel/2 so the
  # orphaned-owner offboarding path (#358) can reuse it without the owner-only guard.
  defp delete_channel_record(%Channel{} = channel) do
    member_ids = member_ids(channel.id)
    # Collected BEFORE the delete — the FK cascade wipes the rows we'd query.
    blob_keys = Chat.channel_room_blob_keys(channel.id)

    # stale_error_field: an already-deleted channel (e.g. a concurrent owner
    # session) is :not_found, not a StaleEntryError crash.
    case Repo.delete(channel, stale_error_field: :id) do
      {:ok, _} ->
        # Rooms cascaded with the channel; reclaim their attachment blobs
        # (forward-safely) only after the delete committed.
        Chat.delete_unreferenced_blobs(blob_keys)
        # The channel's own avatar blob (#70) — best-effort cleanup.
        if channel.avatar_key, do: Storage.delete(channel.avatar_key)
        broadcast_channel(channel.id, {:channel_deleted, channel.id})
        Enum.each(member_ids, &broadcast_user(&1, :channels_changed))
        :ok

      {:error, _stale} ->
        {:error, :not_found}
    end
  end

  ## Rooms (authorized orchestration over Chat's data operations)

  @doc """
  Rooms of a channel for the sidebar (unread badges + muted flags), authorized
  by channel membership. `{:error, :not_found}` for non-members.
  """
  def list_rooms(%Scope{} = scope, channel_id) do
    with {:ok, channel} <- get_channel(scope, channel_id) do
      {:ok, Chat.list_rooms(scope, channel.id)}
    end
  end

  @doc "Creates a room (admin+); all current members are materialized into it."
  def create_room(%Scope{user: user} = scope, channel_id, attrs) do
    with {:ok, channel} <- get_channel(scope, channel_id),
         :ok <- ensure_role(channel.role, ~w(owner admin)),
         # #41: seed only the creator. Others join open rooms via link or are
         # added to private ones — no channel-wide fan-out anymore.
         {:ok, room} <- Chat.create_room(channel.id, attrs, [user.id]) do
      broadcast_channel(channel.id, {:room_created, room})
      {:ok, room}
    end
  end

  @doc """
  Saves room settings (admin+ of its channel): name and, since #43, visibility.
  Kept under its historical name — the `:room_renamed` broadcast likewise covers
  any settings change (subscribers re-read the room list either way).
  """
  def rename_room(%Scope{} = scope, room_id, attrs) do
    with %{} = room <- Chat.get_room(room_id),
         {:ok, channel} <- get_channel(scope, room.channel_id),
         :ok <- ensure_role(channel.role, ~w(owner admin)),
         {:ok, renamed} <- Chat.update_room(room, attrs) do
      broadcast_channel(channel.id, {:room_renamed, renamed})
      {:ok, renamed}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  Deletes a room (admin+): messages and attachment blobs are reclaimed through
  the Chat GC path. The default last room may also be deleted — an empty
  channel is allowed.
  """
  def delete_room(%Scope{} = scope, room_id) do
    with %{} = room <- Chat.get_room(room_id),
         # general is the channel's Town Square — undeletable (#42 guard).
         false <- room.is_general,
         {:ok, channel} <- get_channel(scope, room.channel_id),
         :ok <- ensure_role(channel.role, ~w(owner admin)) do
      :ok = Chat.hard_delete_conversation(room.id)
      broadcast_channel(channel.id, {:room_deleted, room.id})
      :ok
    else
      nil -> {:error, :not_found}
      true -> {:error, :general}
      error -> error
    end
  end

  @doc """
  Requests to join a private room (#41 knock). The requester must be a channel
  member (auto-joined the channel) but not a room member, and the room must be
  private. Posts a join-request system message into the room (deduped: one
  pending request per requester). `{:ok, :requested | :already}` or
  `{:error, :not_found | :not_private | :member}`.
  """
  def request_room_join(%Scope{user: user} = scope, room_id) do
    with %{visibility: "private"} = room <- Chat.get_room(room_id),
         {:ok, _channel} <- get_channel(scope, room.channel_id),
         false <- Chat.room_member?(room.id, user.id) do
      case Chat.pending_join_request(room.id, user.id) do
        nil -> post_join_request(room, user)
        _existing -> {:ok, :already}
      end
    else
      nil -> {:error, :not_found}
      %{} -> {:error, :not_private}
      true -> {:error, :member}
      error -> error
    end
  end

  # Post a fresh join-request system message. A system message has no validated user input
  # (meta is server-built, body is ""), so create_system_message's ONLY error path is the
  # conversation_id FK — i.e. the room was deleted concurrently (#258). Mapping that error to
  # `:not_found` is exact, not lossy; there's no validation failure it could mask.
  defp post_join_request(room, user) do
    room.id
    |> Chat.create_system_message(Chat.SystemMessage.join_request(user))
    |> case do
      {:ok, message} ->
        notify_knock(room, user, message)
        {:ok, :requested}

      {:error, _} ->
        {:error, :not_found}
    end
  end

  # #363/R029: a knock is actionable but silent otherwise — the admin/owner only learns of it
  # by opening the room. Ring them. This is done HERE (not in the generic `create_system_message`,
  # which stays a dumb utility) so only the join-request system message notifies — member
  # add/remove notices don't. A knock has no `%User{}` sender, so `Chat.notify_payload/1` can't
  # build it (that match is a hard contract); we build a dedicated `kind: "knock"` payload with
  # the requester as sender_* and the room as the title, and fan it out through the same
  # `Notifications.deliver/2` seam every message uses. The unread/badge side (R120) is left as-is
  # on purpose — bumping the shared unread on a NULL-sender system message would noise every
  # member's badge; the knock's signal is the notification + the visible in-room request row.
  defp notify_knock(room, requester, message) do
    case knock_recipient_ids(room.channel_id, requester.id) do
      [] -> :ok
      ids -> Notifications.deliver(ids, knock_payload(room, requester, message))
    end
  end

  # The channel's owner + admins, minus the requester, minus anyone who muted the channel or
  # is in Do-Not-Disturb or is deactivated/anonymized — the same delivery gates a message gets
  # (#363), read off `channel_memberships`. All-SQL; a no-op empty list when no eligible admin.
  defp knock_recipient_ids(channel_id, requester_id) do
    Repo.all(
      from(m in Membership,
        join: u in User,
        on: u.id == m.user_id,
        where:
          m.channel_id == ^channel_id and m.role in ["owner", "admin"] and
            m.user_id != ^requester_id and is_nil(m.muted_at) and
            u.presence_status != "dnd" and u.active == true and is_nil(u.deleted_at),
        select: m.user_id
      )
    )
  end

  # A knock's locale-neutral notification payload (contract in `Eden.Notifications` moduledoc).
  # `kind: "knock"` tells the renderer to head the banner with the room and word it as a join
  # request; the requester rides in the sender_* fields (avatar + name), so the recipient's
  # session formats it without a `%User{}` message sender.
  defp knock_payload(room, requester, message) do
    %{
      conversation_id: room.id,
      message_id: message.id,
      root_id: nil,
      channel_id: room.channel_id,
      kind: "knock",
      conv_title: room.name,
      sender_id: requester.id,
      sender_name: requester.display_name,
      avatar_key: requester.avatar_key,
      preview: "",
      media_kind: nil
    }
  end

  @doc """
  Approves a pending join request (admin+ of the room's channel): adds the
  requester to the room and flips the request to accepted. Idempotent on an
  already-accepted request. `{:error, :not_found | :forbidden}`.
  """
  def approve_room_join(%Scope{} = scope, message_id) do
    with %{} = msg <- Chat.get_system_message(message_id),
         # Read the shape through its owner (#360) — a non-join_request system message falls to
         # the else clause as :not_found, never a raw-key match in the web/context boundary.
         {:join_request, %{requester_id: req_id, status: status}} <-
           Chat.SystemMessage.describe(msg.meta),
         %{} = room <- Chat.get_room(msg.conversation_id),
         {:ok, channel} <- get_channel(scope, room.channel_id),
         :ok <- ensure_role(channel.role, ~w(owner admin)) do
      cond do
        status != "pending" ->
          :ok

        # The requester was permanently deleted (#303) after knocking — don't resurrect an
        # anonymized account into the room; settle the stale knock as declined (#305 review).
        requester_deleted?(req_id) ->
          decline_pending(msg)

        true ->
          approve_pending(channel, room, req_id, msg)
      end
    else
      # {:error, reason} from get_channel/ensure_role passes through; anything
      # else (nil, a non-join_request system message) is :not_found — never a
      # bare struct that the caller's {:ok | {:error, _}} contract can't handle.
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

  # Materialize an accepted knock: (re-)ensure channel membership (the requester may have
  # left since knocking, so a room membership never exists without its channel one), join
  # the room, then flip the request to accepted. All three commit in ONE transaction (#261),
  # like every other `join_channel_tx` caller — a crash mid-way must not leave a channel
  # membership without its general room, which a repeat approve (seeing the membership
  # already there) wouldn't heal. Broadcasts fire only after the commit; a room deleted
  # between our reads and the resolve (#258) rolls back and returns `{:error, _}`.
  defp approve_pending(channel, room, req_id, msg) do
    Repo.transact(fn ->
      _ = join_channel_tx(channel.id, req_id)
      :ok = Chat.join_room(room.id, req_id)

      case Chat.resolve_join_request(msg, "accepted") do
        {:ok, _} -> {:ok, :approved}
        {:error, _} = error -> error
      end
    end)
    |> case do
      {:ok, :approved} ->
        broadcast_user(req_id, :channels_changed)
        broadcast_channel(channel.id, {:members_changed, channel.id})
        :ok

      {:error, _} ->
        {:error, :not_found}
    end
  rescue
    # The room was GC'd between get_room and the join writes (#258 review): join_room's
    # insert_all hits an FK violation (Postgrex.Error), which the transaction rolls back
    # (no half-done, #261) and re-raises. Map it to :not_found so approve is non-crashing,
    # like decline/request.
    Postgrex.Error -> {:error, :not_found}
  end

  defp requester_deleted?(req_id) do
    Repo.exists?(from u in User, where: u.id == ^req_id and not is_nil(u.deleted_at))
  end

  @doc """
  Declines a pending join request (admin+ of the room's channel): flips the
  request message to "declined" without joining anyone. The requester may
  knock again afterwards (only "pending" blocks a re-request).
  `{:error, :not_found | :forbidden}`.
  """
  def decline_room_join(%Scope{} = scope, message_id) do
    with %{meta: %{"action" => "join_request"} = meta} = msg <-
           Chat.get_system_message(message_id),
         %{} = room <- Chat.get_room(msg.conversation_id),
         {:ok, channel} <- get_channel(scope, room.channel_id),
         :ok <- ensure_role(channel.role, ~w(owner admin)) do
      if meta["status"] == "pending", do: decline_pending(msg), else: :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

  # Flip a pending request to declined; `:not_found` (not a crash) if the room was
  # deleted concurrently and the message is already gone (#258).
  defp decline_pending(msg) do
    case Chat.resolve_join_request(msg, "declined") do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  Adds existing eden users to a room directly (admin+ of its channel — the #41
  internal-add). Non-channel users are materialized into the channel (general)
  too, all in one transaction. Returns `{:ok, newly_added_ids}` (idempotent for
  users already in the room); added users' rails refresh.
  """
  def add_room_members(%Scope{} = scope, room_id, user_ids) do
    with %{} = room <- Chat.get_room(room_id),
         {:ok, channel} <- get_channel(scope, room.channel_id),
         :ok <- ensure_role(channel.role, ~w(owner admin)) do
      ids = user_ids |> Enum.map(&Ids.normalize/1) |> Enum.filter(&is_integer/1)
      # Intersect with real, non-deleted users — a phantom id would raise an FK violation,
      # and an anonymized account (#303) must never be re-added to a room (deletion is
      # terminal, #305 review).
      ids = Repo.all(from u in User, where: u.id in ^ids and is_nil(u.deleted_at), select: u.id)

      {:ok, added} =
        Repo.transact(fn ->
          {:ok, Enum.filter(ids, &add_one_to_room(channel.id, room.id, &1))}
        end)

      Enum.each(added, &broadcast_user(&1, :channels_changed))
      if added != [], do: broadcast_channel(channel.id, {:members_changed, channel.id})
      {:ok, added}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  # Channel (general) + room, inside the caller's transaction. Returns whether
  # the user was newly added to the room.
  defp add_one_to_room(channel_id, room_id, user_id) do
    join_channel_tx(channel_id, user_id)

    if Chat.room_member?(room_id, user_id) do
      false
    else
      :ok = Chat.join_room(room_id, user_id)
      true
    end
  end

  @doc "Reorders a channel's rooms (admin+)."
  def reorder_rooms(%Scope{} = scope, channel_id, ordered_ids) do
    with {:ok, channel} <- get_channel(scope, channel_id),
         :ok <- ensure_role(channel.role, ~w(owner admin)) do
      :ok = Chat.reorder_rooms(channel.id, ordered_ids)
      broadcast_channel(channel.id, :rooms_reordered)
      :ok
    end
  end

  ## Members

  @doc """
  Channel members with roles, ordered owner → admins → members (by name
  within). Authorized by membership.
  """
  def list_members(%Scope{} = scope, channel_id) do
    with {:ok, channel} <- get_channel(scope, channel_id) do
      members =
        Repo.all(
          from m in Membership,
            join: u in User,
            on: u.id == m.user_id,
            # Anonymized (#303) accounts never show in the member panel — a dead "Удалённый
            # аккаунт" owner/member would just be noise (#358/R004). Message authorship in rooms
            # takes the name from a different path, so this is panel-only.
            where: m.channel_id == ^channel.id and is_nil(u.deleted_at),
            order_by: [
              asc:
                fragment(
                  "case ? when 'owner' then 0 when 'admin' then 1 else 2 end",
                  m.role
                ),
              asc: u.display_name
            ],
            select: %{user: u, role: m.role}
        )

      {:ok, members}
    end
  end

  @doc """
  Adds existing eden users to the channel (admin+). Membership and the room
  materialization commit in one transaction (a join must never be half-done);
  idempotent for users who are already members. Added users' rails refresh.
  """
  def add_members(%Scope{} = scope, channel_id, user_ids) do
    with {:ok, channel} <- get_channel(scope, channel_id),
         :ok <- ensure_role(channel.role, ~w(owner admin)) do
      ids = user_ids |> Enum.map(&Ids.normalize/1) |> Enum.filter(&is_integer/1)
      # Intersect with real, non-deleted users: a phantom id would raise an FK violation
      # inside insert_all (on_conflict only absorbs unique conflicts), and an anonymized
      # account (#303) must never be re-added (#305 review).
      ids = Repo.all(from u in User, where: u.id in ^ids and is_nil(u.deleted_at), select: u.id)

      {:ok, added} =
        Repo.transact(fn ->
          added = Enum.filter(ids, &join_channel_tx(channel.id, &1))
          {:ok, added}
        end)

      Enum.each(added, &broadcast_user(&1, :channels_changed))
      if added != [], do: broadcast_channel(channel.id, {:members_changed, channel.id})
      {:ok, added}
    end
  end

  # Membership + room materialization, inside the caller's transaction.
  # Returns false when the user was already a member (insert skipped).
  defp join_channel_tx(channel_id, user_id) do
    {count, _} =
      Repo.insert_all(
        Membership,
        [
          %{
            channel_id: channel_id,
            user_id: user_id,
            role: "member",
            inserted_at: now(),
            updated_at: now()
          }
        ],
        on_conflict: :nothing
      )

    if count == 1 do
      # #41: a channel join grants Town Square only; other rooms are earned.
      :ok = Chat.join_general(channel_id, user_id)
      true
    else
      false
    end
  end

  @doc """
  Removes a member (their room memberships go too, one transaction). Owners
  may remove anyone but themselves; admins only plain members. The removed
  user's sessions get `{:removed_from_channel, id}` and navigate away.
  """
  def remove_member(%Scope{user: actor} = scope, channel_id, user_id) do
    with {:ok, channel} <- get_channel(scope, channel_id),
         :ok <- ensure_role(channel.role, ~w(owner admin)),
         target_id when is_integer(target_id) <- Ids.normalize(user_id),
         false <- target_id == actor.id,
         target_role when is_binary(target_role) <- role_of(channel.id, target_id),
         :ok <- ensure_removable(channel.role, target_role) do
      remove_membership_tx(channel.id, target_id)
      notify_removed(channel.id, target_id)
      :ok
    else
      true -> {:error, :self}
      nil -> {:error, :not_found}
      :error -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  # Owners out-rank admins; admins out-rank members. Nobody removes an owner.
  defp ensure_removable("owner", target) when target in ~w(admin member), do: :ok
  defp ensure_removable("admin", "member"), do: :ok
  defp ensure_removable(_actor, _target), do: {:error, :forbidden}

  @doc """
  Leaves the channel. The owner can't leave — transfer ownership or delete
  the channel instead (`{:error, :owner}`).
  """
  def leave_channel(%Scope{user: user} = scope, channel_id) do
    with {:ok, channel} <- get_channel(scope, channel_id) do
      if channel.role == "owner" do
        {:error, :owner}
      else
        remove_membership_tx(channel.id, user.id)
        notify_removed(channel.id, user.id)
        :ok
      end
    end
  end

  defp remove_membership_tx(channel_id, user_id) do
    {:ok, :ok} =
      Repo.transact(fn ->
        Repo.delete_all(
          from m in Membership, where: m.channel_id == ^channel_id and m.user_id == ^user_id
        )

        :ok = Chat.leave_rooms(channel_id, user_id)
        {:ok, :ok}
      end)
  end

  defp notify_removed(channel_id, user_id) do
    broadcast_user(user_id, {:removed_from_channel, channel_id})
    broadcast_user(user_id, :channels_changed)
    broadcast_channel(channel_id, {:members_changed, channel_id})
  end

  @doc "Promotes/demotes between admin and member. Owner only; never the owner row."
  def set_member_role(%Scope{user: actor} = scope, channel_id, user_id, role)
      when role in ["admin", "member"] do
    with {:ok, channel} <- get_channel(scope, channel_id),
         :ok <- ensure_role(channel.role, ~w(owner)),
         target_id when is_integer(target_id) <- Ids.normalize(user_id),
         false <- target_id == actor.id,
         target_role when is_binary(target_role) and target_role != "owner" <-
           role_of(channel.id, target_id) do
      update_role(channel.id, target_id, role)
      broadcast_channel(channel.id, {:members_changed, channel.id})
      :ok
    else
      true -> {:error, :self}
      nil -> {:error, :not_found}
      :error -> {:error, :not_found}
      "owner" -> {:error, :forbidden}
      {:error, _} = error -> error
    end
  end

  # A hand-crafted role (e.g. "owner") must be an error, not a
  # FunctionClauseError crash bubbling through the LiveView.
  def set_member_role(_scope, _channel_id, _user_id, _role), do: {:error, :invalid_role}

  @doc """
  Hands the channel to another member: they become `owner`, the current owner
  becomes `admin` (one transaction). Unblocks the owner's leave.
  """
  def transfer_ownership(%Scope{user: actor} = scope, channel_id, user_id) do
    with {:ok, channel} <- get_channel(scope, channel_id),
         :ok <- ensure_role(channel.role, ~w(owner)),
         target_id when is_integer(target_id) <- Ids.normalize(user_id),
         false <- target_id == actor.id,
         target_role when is_binary(target_role) <- role_of(channel.id, target_id),
         :ok <- transfer_tx(channel.id, actor.id, target_id) do
      broadcast_channel(channel.id, {:members_changed, channel.id})
      broadcast_user(target_id, :channels_changed)
      :ok
    else
      true -> {:error, :self}
      nil -> {:error, :not_found}
      :error -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  # The target's promotion is count-checked: if they left between the read and
  # the write, rolling back keeps the channel from ending up ownerless.
  defp transfer_tx(channel_id, actor_id, target_id) do
    Repo.transact(fn ->
      case update_role(channel_id, target_id, "owner") do
        {1, _} ->
          update_role(channel_id, actor_id, "admin")
          {:ok, :ok}

        _ ->
          {:error, :not_found}
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      error -> error
    end
  end

  defp role_of(channel_id, user_id) do
    Repo.one(
      from m in Membership,
        where: m.channel_id == ^channel_id and m.user_id == ^user_id,
        select: m.role
    )
  end

  defp update_role(channel_id, user_id, role) do
    Repo.update_all(
      from(m in Membership, where: m.channel_id == ^channel_id and m.user_id == ^user_id),
      set: [role: role]
    )
  end

  @doc """
  Reassigns every channel solely owned by `user_id` to a live successor so an account's
  deactivation (#251) / permanent deletion (#303) never leaves a channel with a dead,
  unremovable owner (#358).

  A **system offboarding operation**, so — unlike `transfer_ownership/3` — it takes no
  `%Scope{}` and deliberately bypasses the owner-only guards: the caller (the erasure worker
  for deletion, the AdminLive deactivate path for deactivation) has already authorized the
  account action. The successor is picked deterministically: the most senior **usable**
  (active, not deleted) member — admins before plain members, then oldest join, then id —
  and re-verified UNDER LOCK at promote time so a successor deactivated mid-flight is skipped.

  With **no usable successor** (the owner is the last usable member), the fallback depends on
  `delete_orphans:` (default `false`): the **irreversible deletion** path passes `true` to
  delete the now-permanently-ownerless channel (blobs reclaimed); the **reversible
  deactivation** path leaves it untouched (`false`) — reactivation must restore a working
  channel, and a solo channel strands no one else in the meantime.

  Idempotent: once the departing owner holds no `owner` rows, a re-run is a no-op (so the
  durable deletion worker can retry safely). Returns `:ok`.
  """
  def reassign_orphaned_ownerships(user_id, opts \\ []) when is_integer(user_id) do
    delete_orphans? = Keyword.get(opts, :delete_orphans, false)

    from(m in Membership,
      where: m.user_id == ^user_id and m.role == "owner",
      select: m.channel_id
    )
    |> Repo.all()
    |> Enum.each(&reassign_one(&1, user_id, delete_orphans?))
  end

  defp reassign_one(channel_id, owner_id, delete_orphans?) do
    case pick_successor(channel_id, owner_id) do
      nil -> if delete_orphans?, do: delete_orphaned_channel(channel_id), else: :ok
      successor_id -> promote_or_retry(channel_id, owner_id, successor_id, delete_orphans?)
    end
  end

  # The most senior USABLE member other than the departing owner: admins before members, then
  # oldest join, then id — deterministic. Excludes deleted AND deactivated users so we never
  # hand ownership to another dead/blocked account (which would re-orphan the channel).
  defp pick_successor(channel_id, owner_id) do
    Repo.one(
      from m in Membership,
        join: u in User,
        on: u.id == m.user_id,
        where:
          m.channel_id == ^channel_id and m.user_id != ^owner_id and
            is_nil(u.deleted_at) and u.active == true,
        order_by: [
          asc: fragment("case ? when 'admin' then 0 else 1 end", m.role),
          asc: m.inserted_at,
          asc: m.user_id
        ],
        limit: 1,
        select: m.user_id
    )
  end

  defp promote_or_retry(channel_id, owner_id, successor_id, delete_orphans?) do
    case promote_tx(channel_id, owner_id, successor_id) do
      :ok ->
        broadcast_channel(channel_id, {:members_changed, channel_id})
        broadcast_user(successor_id, :channels_changed)
        :ok

      # The chosen successor left OR was deactivated between the pick and the write — re-pick
      # from scratch (finds another usable member, or falls to the no-successor path).
      # Terminates: each retry either promotes someone or shrinks the usable-candidate set.
      :retry ->
        reassign_one(channel_id, owner_id, delete_orphans?)
    end
  end

  # Promote the successor, then demote the departing owner to plain member (no privilege kept
  # on the dead account — mirrors #303) in one transaction.
  defp promote_tx(channel_id, owner_id, successor_id) do
    Repo.transact(fn -> promote_locked(channel_id, owner_id, successor_id) end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, :retry} -> :retry
    end
  end

  # Re-verify the successor is STILL usable under a `FOR UPDATE` lock (#358 review): a
  # deactivation racing this promote would otherwise hand ownership to a now-blocked account
  # and re-orphan the channel. Also count-checked, so a successor whose membership vanished
  # rolls back rather than leaving the channel ownerless. Both cases → :retry (re-pick).
  defp promote_locked(channel_id, owner_id, successor_id) do
    cond do
      not usable?(successor_id) ->
        {:error, :retry}

      match?({0, _}, update_role(channel_id, successor_id, "owner")) ->
        {:error, :retry}

      true ->
        update_role(channel_id, owner_id, "member")
        {:ok, :ok}
    end
  end

  defp usable?(user_id) do
    Repo.one(
      from u in User,
        where: u.id == ^user_id and u.active == true and is_nil(u.deleted_at),
        lock: "FOR UPDATE",
        select: u.id
    ) != nil
  end

  defp delete_orphaned_channel(channel_id) do
    case Repo.get(Channel, channel_id) do
      nil -> :ok
      channel -> delete_channel_record(channel)
    end
  end

  ## Invite links

  @invite_ttl_days 7

  @doc """
  Creates a shareable invite link (admin+). Returns `{:ok, invite, raw_token}`
  — the raw token exists only here (the DB stores its hash). Defaults: expires
  in #{@invite_ttl_days} days, unlimited uses (`max_uses: n` to cap).
  """
  def create_invite(%Scope{user: user} = scope, channel_id, opts \\ []) do
    with {:ok, channel} <- get_channel(scope, channel_id),
         :ok <- ensure_role(channel.role, ~w(owner admin)) do
      insert_invite(channel.id, nil, user.id, opts)
    end
  end

  @doc """
  Creates a shareable invite link into a **private room** (admin+ of the room's
  channel). Redemption joins the channel (`general`) AND the room in one
  transaction — the no-knock fast path. Open rooms get no tokens (their plain
  link is the invite). `{:ok, invite, raw_token}` or
  `{:error, :not_found | :not_private | :forbidden}`.
  """
  def create_room_invite(%Scope{user: user} = scope, room_id, opts \\ []) do
    with %{visibility: "private"} = room <- Chat.get_room(room_id),
         {:ok, channel} <- get_channel(scope, room.channel_id),
         :ok <- ensure_role(channel.role, ~w(owner admin)) do
      insert_invite(channel.id, room.id, user.id, opts)
    else
      nil -> {:error, :not_found}
      %{} -> {:error, :not_private}
      error -> error
    end
  end

  defp insert_invite(channel_id, room_id, created_by_id, opts) do
    raw = Accounts.build_token()

    expires_at =
      Keyword.get_lazy(opts, :expires_at, fn ->
        DateTime.utc_now() |> DateTime.add(@invite_ttl_days, :day) |> DateTime.truncate(:second)
      end)

    %Invite{
      channel_id: channel_id,
      room_id: room_id,
      created_by_id: created_by_id,
      hashed_token: Accounts.hash_token(raw)
    }
    |> Invite.create_changeset(%{expires_at: expires_at, max_uses: opts[:max_uses]})
    |> Repo.insert()
    |> case do
      {:ok, invite} -> {:ok, invite, raw}
      error -> error
    end
  end

  @doc "Active (unrevoked, unexpired) invite links of a channel, newest first. Admin+."
  def list_invites(%Scope{} = scope, channel_id) do
    with {:ok, channel} <- get_channel(scope, channel_id),
         :ok <- ensure_role(channel.role, ~w(owner admin)) do
      now = DateTime.utc_now()

      {:ok,
       Repo.all(
         from i in Invite,
           where: i.channel_id == ^channel.id and is_nil(i.revoked_at) and i.expires_at > ^now,
           order_by: [desc: i.id],
           # Room invites carry their room so the UI can label them (#42).
           preload: [:room]
       )}
    end
  end

  @doc "Revokes an invite link (admin+ of its channel)."
  def revoke_invite(%Scope{} = scope, invite_id) do
    with id when is_integer(id) <- Ids.normalize(invite_id),
         %Invite{} = invite <- Repo.get(Invite, id),
         {:ok, channel} <- get_channel(scope, invite.channel_id),
         :ok <- ensure_role(channel.role, ~w(owner admin)) do
      Repo.update_all(from(i in Invite, where: i.id == ^invite.id),
        set: [revoked_at: now()]
      )

      :ok
    else
      nil -> {:error, :not_found}
      :error -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  @doc """
  Revoke every still-live channel/room invite a user minted (#305 review P2). Called by the web
  layer when an account is deactivated or permanently erased — an unrevoked private-room invite
  token keeps granting access indefinitely regardless of its creator's state, so offboarding must
  kill them alongside the account's registration invites. Unscoped (a system action, not a
  member operation); returns the count revoked.
  """
  def revoke_invites_by(user_id) when is_integer(user_id) do
    {n, _} =
      Repo.update_all(
        from(i in Invite, where: i.created_by_id == ^user_id and is_nil(i.revoked_at)),
        set: [revoked_at: now()]
      )

    n
  end

  @doc """
  Joins a channel by invite token (any authenticated user). The invite row is
  locked `FOR UPDATE` so two people racing on the last use cannot both
  succeed; membership + room materialization commit in the same transaction.
  Idempotent for existing members (no use consumed). Returns `{:ok, channel}`
  or `{:error, :invalid | :expired | :revoked | :exhausted}`.
  """
  def join_by_token(%Scope{user: user}, raw_token) when is_binary(raw_token) do
    hashed = Accounts.hash_token(raw_token)

    result =
      Repo.transact(fn ->
        case lock_invite(hashed) do
          nil -> {:error, :invalid}
          invite -> redeem_invite(invite, user.id)
        end
      end)

    with {:ok, {channel_id, room_id, status}} <- result do
      if status == :joined do
        broadcast_user(user.id, :channels_changed)
        broadcast_channel(channel_id, {:members_changed, channel_id})
      end

      case Repo.get(Channel, channel_id) do
        # The channel vanished between commit and read — treat as a dead link.
        nil -> {:error, :invalid}
        channel -> {:ok, %{channel | role: role_of(channel_id, user.id) || "member"}, room_id}
      end
    end
  rescue
    # Mirror approve_pending's rescue (#375/R023): the channel/room GC'd between lock_invite and
    # the join_channel_tx / join_room writes surfaces as an FK-violation Postgrex.Error (their
    # `on_conflict: :nothing` catches unique conflicts, NOT FK). The transaction rolls back and
    # re-raises; map it to a dead-link `:invalid` (join_by_token's own contract, vs approve's
    # `:not_found`) so the redemption is non-crashing — the controller's catch-all renders a flash
    # instead of a 500. The invite's FOR UPDATE lock makes this window tiny, but the symmetry holds.
    Postgrex.Error -> {:error, :invalid}
  end

  # Inside the locking transaction: validate, join the channel (general) and,
  # for a room invite, the room — both idempotent. A use is consumed only when
  # the redemption joined something new (channel or room).
  defp redeem_invite(invite, user_id) do
    with :ok <- validate_invite(invite) do
      channel_new = join_channel_tx(invite.channel_id, user_id)
      room_new = redeem_room(invite.room_id, user_id)
      newly = channel_new or room_new
      if newly, do: bump_used_count(invite)
      {:ok, {invite.channel_id, invite.room_id, if(newly, do: :joined, else: :already)}}
    end
  end

  defp redeem_room(nil, _user_id), do: false

  defp redeem_room(room_id, user_id) do
    if Chat.room_member?(room_id, user_id) do
      false
    else
      :ok = Chat.join_room(room_id, user_id)
      true
    end
  end

  defp lock_invite(hashed) do
    Repo.one(from i in Invite, where: i.hashed_token == ^hashed, lock: "FOR UPDATE")
  end

  defp validate_invite(invite) do
    now = DateTime.utc_now()

    cond do
      invite.revoked_at -> {:error, :revoked}
      DateTime.compare(invite.expires_at, now) != :gt -> {:error, :expired}
      invite.max_uses && invite.used_count >= invite.max_uses -> {:error, :exhausted}
      true -> :ok
    end
  end

  defp bump_used_count(invite) do
    Repo.update_all(from(i in Invite, where: i.id == ^invite.id),
      inc: [used_count: 1]
    )
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  ## Roles

  @doc "The scoped user's role in the channel (`owner | admin | member`), or `nil`."
  def member_role(%Scope{user: user}, channel_id) do
    case Ids.normalize(channel_id) do
      id when is_integer(id) ->
        Repo.one(
          from m in Membership,
            where: m.channel_id == ^id and m.user_id == ^user.id,
            select: m.role
        )

      _ ->
        nil
    end
  end

  @doc "Whether the scoped user can manage the channel (owner or admin)."
  def admin?(%Scope{} = scope, channel_id), do: member_role(scope, channel_id) in ~w(owner admin)

  @doc "Whether the scoped user owns the channel."
  def owner?(%Scope{} = scope, channel_id), do: member_role(scope, channel_id) == "owner"

  defp ensure_role(role, allowed) do
    if role in allowed, do: :ok, else: {:error, :forbidden}
  end

  ## PubSub

  @doc "Subscribe to a channel's events. Authorize with `get_channel/2` first."
  def subscribe_channel(channel_id),
    do: Phoenix.PubSub.subscribe(@pubsub, channel_topic(channel_id))

  @doc "Unsubscribe from a channel's events."
  def unsubscribe_channel(channel_id),
    do: Phoenix.PubSub.unsubscribe(@pubsub, channel_topic(channel_id))

  @doc "Subscribe to the scoped user's channel-rail updates (`:channels_changed`)."
  def subscribe_user(%Scope{user: user}),
    do: Phoenix.PubSub.subscribe(@pubsub, user_topic(user.id))

  defp broadcast_channel(channel_id, message),
    do: Phoenix.PubSub.broadcast(@pubsub, channel_topic(channel_id), message)

  defp broadcast_user(user_id, message),
    do: Phoenix.PubSub.broadcast(@pubsub, user_topic(user_id), message)

  defp notify_members(channel_id, message) do
    channel_id
    |> member_ids()
    |> Enum.each(&broadcast_user(&1, message))
  end

  defp channel_topic(channel_id), do: "channel:#{channel_id}"
  defp user_topic(user_id), do: "user:#{user_id}:channels"

  ## Internals

  defp member_ids(channel_id) do
    Repo.all(from m in Membership, where: m.channel_id == ^channel_id, select: m.user_id)
  end

  defp insert_membership(channel_id, user_id, role) do
    %Membership{}
    |> Membership.changeset(%{channel_id: channel_id, user_id: user_id, role: role})
    |> Repo.insert()
  end
end
