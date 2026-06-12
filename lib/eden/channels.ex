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
  alias Eden.Repo

  @pubsub Eden.PubSub

  # Sanity cap on channels a single user can create (like folders): keeps a
  # runaway client from flooding everyone's rail.
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

    from(c in Channel,
      join: m in Membership,
      on: m.channel_id == c.id and m.user_id == ^user.id,
      order_by: [asc: c.id],
      select: {c, m.role, m.muted_at}
    )
    |> Repo.all()
    |> Enum.map(fn {channel, role, muted_at} ->
      %{
        channel
        | role: role,
          muted: not is_nil(muted_at),
          unread_count: Map.get(unread, channel.id, 0)
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
  Deletes a channel. Owner only. Member rails refresh via `:channels_changed`;
  sessions inside the channel get `{:channel_deleted, id}` on the channel
  topic. (Rooms cascade by FK; their attachment-blob GC arrives with #29.)
  """
  def delete_channel(%Scope{} = scope, channel_id) do
    with {:ok, channel} <- get_channel(scope, channel_id),
         :ok <- ensure_role(channel.role, ~w(owner)) do
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
          broadcast_channel(channel.id, {:channel_deleted, channel.id})
          Enum.each(member_ids, &broadcast_user(&1, :channels_changed))
          :ok

        {:error, _stale} ->
          {:error, :not_found}
      end
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

  @doc "Renames a room (admin+ of its channel)."
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
         {:ok, channel} <- get_channel(scope, room.channel_id),
         :ok <- ensure_role(channel.role, ~w(owner admin)) do
      :ok = Chat.hard_delete_conversation(room.id)
      broadcast_channel(channel.id, {:room_deleted, room.id})
      :ok
    else
      nil -> {:error, :not_found}
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
        nil ->
          {:ok, _} =
            Chat.create_system_message(room.id, %{
              "action" => "join_request",
              "requester_id" => user.id,
              "requester_name" => user.display_name,
              "status" => "pending"
            })

          {:ok, :requested}

        _existing ->
          {:ok, :already}
      end
    else
      nil -> {:error, :not_found}
      %{} -> {:error, :not_private}
      true -> {:error, :member}
      error -> error
    end
  end

  @doc """
  Approves a pending join request (admin+ of the room's channel): adds the
  requester to the room and flips the request to accepted. Idempotent on an
  already-accepted request. `{:error, :not_found | :forbidden}`.
  """
  def approve_room_join(%Scope{} = scope, message_id) do
    with %{meta: %{"requester_id" => req_id} = meta} = msg <- Chat.get_system_message(message_id),
         %{} = room <- Chat.get_room(msg.conversation_id),
         {:ok, channel} <- get_channel(scope, room.channel_id),
         :ok <- ensure_role(channel.role, ~w(owner admin)) do
      if meta["status"] == "pending" do
        :ok = Chat.join_room(room.id, req_id)
        {:ok, _} = Chat.resolve_join_request(msg, "accepted")
        broadcast_user(req_id, :channels_changed)
        broadcast_channel(channel.id, {:members_changed, channel.id})
      end

      :ok
    else
      nil -> {:error, :not_found}
      error -> error
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
            where: m.channel_id == ^channel.id,
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
      # Intersect with real users: a phantom id would raise an FK violation
      # inside insert_all (on_conflict only absorbs unique conflicts).
      ids = Repo.all(from u in User, where: u.id in ^ids, select: u.id)

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
      raw = Accounts.build_token()

      expires_at =
        Keyword.get_lazy(opts, :expires_at, fn ->
          DateTime.utc_now() |> DateTime.add(@invite_ttl_days, :day) |> DateTime.truncate(:second)
        end)

      %Invite{
        channel_id: channel.id,
        created_by_id: user.id,
        hashed_token: Accounts.hash_token(raw)
      }
      |> Invite.create_changeset(%{expires_at: expires_at, max_uses: opts[:max_uses]})
      |> Repo.insert()
      |> case do
        {:ok, invite} -> {:ok, invite, raw}
        error -> error
      end
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
           order_by: [desc: i.id]
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

    with {:ok, {channel_id, status}} <- result do
      if status == :joined do
        broadcast_user(user.id, :channels_changed)
        broadcast_channel(channel_id, {:members_changed, channel_id})
      end

      case Repo.get(Channel, channel_id) do
        # The channel vanished between commit and read — treat as a dead link.
        nil -> {:error, :invalid}
        channel -> {:ok, %{channel | role: role_of(channel_id, user.id) || "member"}}
      end
    end
  end

  # Inside the locking transaction: validate, join (idempotent), count the use.
  defp redeem_invite(invite, user_id) do
    with :ok <- validate_invite(invite) do
      if join_channel_tx(invite.channel_id, user_id) do
        bump_used_count(invite)
        {:ok, {invite.channel_id, :joined}}
      else
        {:ok, {invite.channel_id, :already}}
      end
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
