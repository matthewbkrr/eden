defmodule Eden.Chat do
  @moduledoc """
  The Chat context: conversations (1:1 and group), memberships, and messages.

  Every function takes a `%Scope{}` and is authorized by membership — a user can
  only see or post to conversations they belong to (broken-access-control by
  construction). Realtime delivery is via `Phoenix.PubSub` on per-conversation
  topics; subscribe only after `get_conversation/2` has authorized access.
  """
  import Ecto.Query, warn: false
  require Logger

  alias Eden.Accounts.Scope
  alias Eden.Chat.{Attachment, Conversation, Membership, Message, ThumbnailWorker}
  alias Eden.Repo
  alias Eden.Storage

  @pubsub Eden.PubSub
  @default_page 50
  @max_attachment_bytes 8 * 1024 * 1024

  # Thumbnails: longest edge in pixels (never upscaled) and JPEG quality.
  @thumbnail_max 800
  @thumbnail_quality 80
  # Reject decompression bombs before decoding: cap the source's *header*
  # pixel dimensions (~100 MP), checked from the lazy image without decoding.
  @max_source_pixels 100_000_000

  @doc "Maximum accepted attachment size in bytes (single source of truth for UI + server)."
  def max_attachment_bytes, do: @max_attachment_bytes

  ## Conversations

  @doc """
  Conversations the scoped user belongs to, most-recent first, with members
  preloaded and the virtual `unread_count` / `last_message_body` filled in.
  """
  def list_conversations(%Scope{user: user}) do
    conversations =
      Conversation
      |> join(:inner, [c], m in Membership,
        on: m.conversation_id == c.id and m.user_id == ^user.id
      )
      |> order_by([c], desc_nulls_last: c.last_message_at, desc: c.id)
      |> preload(memberships: :user)
      |> Repo.all()

    ids = Enum.map(conversations, & &1.id)
    previews = last_message_bodies(ids)
    unread = unread_counts(user, ids)

    Enum.map(conversations, fn conversation ->
      %{
        conversation
        | last_message_body: previews[conversation.id],
          unread_count: Map.get(unread, conversation.id, 0)
      }
    end)
  end

  defp last_message_bodies([]), do: %{}

  defp last_message_bodies(ids) do
    from(m in Message,
      where: m.conversation_id in ^ids,
      distinct: m.conversation_id,
      order_by: [asc: m.conversation_id, desc: m.id],
      select: {m.conversation_id, m.body}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp unread_counts(_user, []), do: %{}

  defp unread_counts(user, ids) do
    from(m in Message,
      join: mem in Membership,
      on: mem.conversation_id == m.conversation_id and mem.user_id == ^user.id,
      where:
        m.conversation_id in ^ids and m.sender_id != ^user.id and
          (is_nil(mem.last_read_at) or m.inserted_at > mem.last_read_at),
      group_by: m.conversation_id,
      select: {m.conversation_id, count(m.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc "Fetches a conversation the scoped user belongs to (members preloaded), or `{:error, :not_found}`."
  def get_conversation(%Scope{user: user}, id) do
    query =
      from c in Conversation,
        join: m in Membership,
        on: m.conversation_id == c.id and m.user_id == ^user.id,
        where: c.id == ^id,
        preload: [memberships: :user]

    case Repo.one(query) do
      nil -> {:error, :not_found}
      conversation -> {:ok, conversation}
    end
  end

  @doc "Like get_conversation/2 but with the virtual unread_count / last_message_body filled in."
  def get_conversation_summary(%Scope{user: user} = scope, id) do
    with {:ok, conversation} <- get_conversation(scope, id) do
      {:ok,
       %{
         conversation
         | last_message_body: last_message_bodies([id])[id],
           unread_count: Map.get(unread_counts(user, [id]), id, 0)
       }}
    end
  end

  @doc """
  Starts (or, for a 1:1, reuses) a conversation between the scoped user and the
  given other user ids. Pass `group: true` (or 2+ others) for a group; `title:`
  names a group. Returns `{:ok, conversation}` (members preloaded).
  """
  def create_conversation(%Scope{user: creator}, other_ids, opts \\ []) do
    other_ids = other_ids |> Enum.map(&normalize_id/1) |> Enum.uniq() |> List.delete(creator.id)
    group? = Keyword.get(opts, :group, length(other_ids) > 1)

    cond do
      other_ids == [] -> {:error, :no_members}
      not group? and length(other_ids) == 1 -> find_or_create_direct(creator, hd(other_ids))
      true -> insert_conversation(creator, other_ids, %{is_group: true, title: opts[:title]})
    end
  end

  ## Messages

  @doc """
  Messages in a conversation, oldest-first, with the sender preloaded. Paginates
  backwards: pass `before:` (a message id) to load the page before it, `limit:`
  to size the page (default #{@default_page}). `{:error, :not_found}` if the user
  is not a member.
  """
  def list_messages(%Scope{} = scope, conversation_id, opts \\ []) do
    if member?(scope, conversation_id) do
      limit = Keyword.get(opts, :limit, @default_page)

      messages =
        Message
        |> where([m], m.conversation_id == ^conversation_id)
        |> before_cursor(opts[:before])
        |> order_by([m], desc: m.id)
        |> limit(^limit)
        |> preload([:sender, :attachment])
        |> Repo.all()
        |> Enum.reverse()

      {:ok, messages}
    else
      {:error, :not_found}
    end
  end

  @doc """
  Posts a message from the scoped user. `sender_id`/`conversation_id` are set
  programmatically (never cast). Updates the conversation sort key and broadcasts
  `{:new_message, message}`. `{:error, :not_found}` if not a member.
  """
  def create_message(%Scope{user: user} = scope, conversation_id, attrs) do
    if member?(scope, conversation_id) do
      %Message{conversation_id: conversation_id, sender_id: user.id}
      |> Message.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, message} -> {:ok, deliver(conversation_id, message)}
        {:error, changeset} -> {:error, changeset}
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  Posts a photo message: validates the file is a supported image by its magic
  bytes (never trusting the client content-type), stores it via the storage
  adapter, and inserts the message + attachment atomically. `source` is a map
  with `:path` (a local temp file) and an optional `:body` caption.

  Returns `{:ok, message}` (attachment preloaded) or `{:error, reason}` where
  reason is `:not_found | :unsupported_type | :too_large` or a changeset.
  """
  def create_photo_message(%Scope{user: user} = scope, conversation_id, source) do
    with true <- member?(scope, conversation_id),
         {:ok, content_type, ext} <- detect_image(source.path),
         {:ok, byte_size} <- check_size(source.path),
         key = Storage.build_key("attachments", ext),
         :ok <- Storage.put(key, source.path) do
      attrs = %{storage_key: key, content_type: content_type, byte_size: byte_size}

      case insert_photo_message(user, conversation_id, Map.get(source, :body, ""), attrs) do
        {:ok, message} ->
          message = deliver(conversation_id, message)
          enqueue_thumbnail(message.attachment)
          {:ok, message}

        {:error, changeset} ->
          Storage.delete(key)
          {:error, changeset}
      end
    else
      false -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Marks the conversation read up to now for the scoped user, broadcasting a read receipt."
  def mark_read(%Scope{user: user}, conversation_id) do
    read_at = now()

    from(m in Membership, where: m.conversation_id == ^conversation_id and m.user_id == ^user.id)
    |> Repo.update_all(set: [last_read_at: read_at])

    broadcast(conversation_id, {:read, user.id, read_at})
    :ok
  end

  @doc """
  Fetches an attachment by id, but only if the scoped user belongs to the
  attachment's conversation. Authorizes file serving by membership.
  """
  def fetch_attachment(%Scope{user: user}, id) do
    query =
      from a in Attachment,
        join: m in Message,
        on: m.id == a.message_id,
        join: mem in Membership,
        on: mem.conversation_id == m.conversation_id and mem.user_id == ^user.id,
        where: a.id == ^id

    case Repo.one(query) do
      nil -> {:error, :not_found}
      attachment -> {:ok, attachment}
    end
  end

  @doc """
  Generates and stores a downscaled, metadata-stripped JPEG thumbnail for the
  attachment, records its key and the original dimensions, then broadcasts the
  refreshed message so open clients swap the full image for the thumbnail.
  Invoked by `Eden.Chat.ThumbnailWorker`; returns `:ok` or `{:error, reason}`.
  """
  def generate_thumbnail(%Attachment{} = attachment) do
    with {:ok, bytes} <- Storage.read(attachment.storage_key),
         {:ok, jpeg, width, height} <- make_thumbnail(bytes),
         thumb_key = Storage.build_key("thumbnails", "jpg"),
         :ok <- Storage.put_binary(thumb_key, jpeg),
         {:ok, _attachment} <- update_thumbnail(attachment, thumb_key, width, height) do
      broadcast_thumbnail(attachment.message_id)
      :ok
    end
  end

  @doc "Whether the scoped user belongs to the conversation."
  def member?(%Scope{user: user}, conversation_id) do
    Repo.exists?(
      from m in Membership, where: m.conversation_id == ^conversation_id and m.user_id == ^user.id
    )
  end

  ## PubSub

  @doc "Subscribe the calling process to a conversation's messages. Authorize first."
  def subscribe(conversation_id), do: Phoenix.PubSub.subscribe(@pubsub, topic(conversation_id))

  @doc "Unsubscribe from a conversation's messages."
  def unsubscribe(conversation_id),
    do: Phoenix.PubSub.unsubscribe(@pubsub, topic(conversation_id))

  @doc "Subscribe to the scoped user's chat activity (any of their conversations changed)."
  def subscribe_user(%Scope{user: user}),
    do: Phoenix.PubSub.subscribe(@pubsub, user_topic(user.id))

  defp broadcast(conversation_id, message),
    do: Phoenix.PubSub.broadcast(@pubsub, topic(conversation_id), message)

  # Tell every member's chat process that this conversation changed (reorder /
  # unread / preview in the sidebar), without leaking message contents.
  defp notify_members(conversation_id) do
    member_ids =
      Repo.all(
        from m in Membership, where: m.conversation_id == ^conversation_id, select: m.user_id
      )

    for user_id <- member_ids do
      Phoenix.PubSub.broadcast(
        @pubsub,
        user_topic(user_id),
        {:conversation_activity, conversation_id}
      )
    end
  end

  defp topic(conversation_id), do: "conversation:#{conversation_id}"
  defp user_topic(user_id), do: "user:#{user_id}:chat"

  ## Internals

  defp find_or_create_direct(creator, other_id) do
    case existing_direct(creator.id, other_id) do
      nil -> insert_conversation(creator, [other_id], %{is_group: false})
      conversation -> {:ok, Repo.preload(conversation, memberships: :user)}
    end
  end

  defp existing_direct(uid1, uid2) do
    from(c in Conversation,
      where: c.is_group == false,
      join: m1 in Membership,
      on: m1.conversation_id == c.id and m1.user_id == ^uid1,
      join: m2 in Membership,
      on: m2.conversation_id == c.id and m2.user_id == ^uid2,
      limit: 1
    )
    |> Repo.one()
  end

  defp insert_conversation(creator, other_ids, conv_attrs) do
    Repo.transact(fn ->
      with {:ok, conversation} <-
             %Conversation{} |> Conversation.changeset(conv_attrs) |> Repo.insert(),
           :ok <- add_member(conversation, creator.id, "owner"),
           :ok <- add_members(conversation, other_ids) do
        {:ok, Repo.preload(conversation, memberships: :user)}
      end
    end)
  end

  defp add_members(conversation, user_ids) do
    Enum.reduce_while(user_ids, :ok, fn user_id, :ok ->
      case add_member(conversation, user_id, "member") do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp add_member(conversation, user_id, role) do
    %Membership{conversation_id: conversation.id}
    |> Membership.changeset(%{user_id: user_id, role: role})
    |> Repo.insert()
    |> case do
      {:ok, _membership} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp touch_conversation(conversation_id, at) do
    from(c in Conversation, where: c.id == ^conversation_id)
    |> Repo.update_all(set: [last_message_at: at])
  end

  defp before_cursor(query, nil), do: query
  defp before_cursor(query, before_id), do: where(query, [m], m.id < ^before_id)

  defp normalize_id(id) when is_integer(id), do: id
  defp normalize_id(id) when is_binary(id), do: String.to_integer(id)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # Touch the conversation, preload, and fan out the new message.
  defp deliver(conversation_id, message) do
    touch_conversation(conversation_id, message.inserted_at)
    message = Repo.preload(message, [:sender, :attachment])
    broadcast(conversation_id, {:new_message, message})
    notify_members(conversation_id)
    message
  end

  defp insert_photo_message(user, conversation_id, body, attachment_attrs) do
    Repo.transact(fn ->
      with {:ok, message} <-
             %Message{conversation_id: conversation_id, sender_id: user.id}
             |> Message.photo_changeset(%{"body" => body})
             |> Repo.insert(),
           {:ok, _attachment} <-
             %Attachment{message_id: message.id}
             |> Attachment.changeset(attachment_attrs)
             |> Repo.insert() do
        {:ok, message}
      end
    end)
  end

  defp enqueue_thumbnail(%Attachment{id: id}) do
    case %{attachment_id: id} |> ThumbnailWorker.new() |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("thumbnail enqueue failed for attachment #{id}: #{inspect(reason)}")
        :ok
    end
  end

  # Shrink to fit @thumbnail_max (never upscaling) and re-encode as JPEG with
  # metadata stripped (drops EXIF, incl. GPS). The resize runs on the raw buffer
  # via `thumbnail_buffer/3`, which shrinks *on load* — it never materialises the
  # full-resolution bitmap, so a small upload that decodes to huge dimensions
  # can't blow up memory. The header is read lazily first to record the original
  # dimensions and to reject decompression bombs. (JPEG is intentional: photos
  # don't need alpha; PNG transparency and GIF animation are not preserved.)
  defp make_thumbnail(bytes) do
    with {:ok, image} <- Image.from_binary(bytes),
         width = Image.width(image),
         height = Image.height(image),
         :ok <- guard_dimensions(width, height),
         {:ok, thumb} <-
           Vix.Vips.Operation.thumbnail_buffer(bytes, @thumbnail_max, size: :VIPS_SIZE_DOWN),
         {:ok, jpeg} <-
           Image.write(thumb, :memory,
             suffix: ".jpg",
             quality: @thumbnail_quality,
             strip_metadata: true
           ) do
      {:ok, jpeg, width, height}
    else
      # A bad/oversized image is a permanent failure (tagged so the worker cancels
      # rather than retries); transient errors live in generate_thumbnail instead.
      {:error, reason} -> {:error, {:unprocessable, reason}}
    end
  rescue
    e -> {:error, {:unprocessable, Exception.message(e)}}
  end

  defp guard_dimensions(width, height) when width * height <= @max_source_pixels, do: :ok
  defp guard_dimensions(_width, _height), do: {:error, :too_large}

  defp update_thumbnail(attachment, thumb_key, width, height) do
    attachment
    |> Attachment.changeset(%{thumbnail_key: thumb_key, width: width, height: height})
    |> Repo.update()
  end

  # Re-broadcast the message (attachment now carries a thumbnail_key) so open
  # conversations swap the full image for the lighter thumbnail in place. The
  # message may be gone if it was deleted while the thumbnail was generating.
  defp broadcast_thumbnail(message_id) do
    case Repo.get(Message, message_id) do
      nil ->
        :ok

      message ->
        message = Repo.preload(message, [:sender, :attachment])
        broadcast(message.conversation_id, {:thumbnail_ready, message})
    end
  end

  # Identify an image by its magic bytes — never trust the client content-type.
  # `path` is a server-assigned upload temp file, not a user-supplied path.
  # sobelow_skip ["Traversal.FileModule"]
  defp detect_image(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, 16)) do
      {:ok, <<0x89, "PNG\r\n", 0x1A, "\n", _::binary>>} -> {:ok, "image/png", "png"}
      {:ok, <<0xFF, 0xD8, 0xFF, _::binary>>} -> {:ok, "image/jpeg", "jpg"}
      {:ok, <<"GIF87a", _::binary>>} -> {:ok, "image/gif", "gif"}
      {:ok, <<"GIF89a", _::binary>>} -> {:ok, "image/gif", "gif"}
      {:ok, <<"RIFF", _::binary-size(4), "WEBP", _::binary>>} -> {:ok, "image/webp", "webp"}
      {:ok, _other} -> {:error, :unsupported_type}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size <= @max_attachment_bytes -> {:ok, size}
      {:ok, _stat} -> {:error, :too_large}
      {:error, reason} -> {:error, reason}
    end
  end
end
