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

  alias Eden.Accounts.Scope
  alias Eden.Channels.{Channel, Membership}
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
           # Every channel starts usable: a default room (Mattermost's Town Square).
           {:ok, _room} <- Chat.create_room(channel.id, %{"name" => "general"}, [user.id]) do
        {:ok, channel}
      end
    end)
  end

  @doc "Channels the scoped user belongs to (creation order), each with the virtual `role` filled."
  def list_channels(%Scope{user: user}) do
    from(c in Channel,
      join: m in Membership,
      on: m.channel_id == c.id and m.user_id == ^user.id,
      order_by: [asc: c.id],
      select: {c, m.role}
    )
    |> Repo.all()
    |> Enum.map(fn {channel, role} -> %{channel | role: role} end)
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
  def create_room(%Scope{} = scope, channel_id, attrs) do
    with {:ok, channel} <- get_channel(scope, channel_id),
         :ok <- ensure_role(channel.role, ~w(owner admin)),
         {:ok, room} <- Chat.create_room(channel.id, attrs, member_ids(channel.id)) do
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

  @doc "Reorders a channel's rooms (admin+)."
  def reorder_rooms(%Scope{} = scope, channel_id, ordered_ids) do
    with {:ok, channel} <- get_channel(scope, channel_id),
         :ok <- ensure_role(channel.role, ~w(owner admin)) do
      :ok = Chat.reorder_rooms(channel.id, ordered_ids)
      broadcast_channel(channel.id, :rooms_reordered)
      :ok
    end
  end

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
