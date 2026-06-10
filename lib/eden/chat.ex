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

  alias Eden.Accounts.{Scope, User}

  alias Eden.Chat.{
    Attachment,
    Conversation,
    Folder,
    FolderMembership,
    FolderPrefs,
    Membership,
    Message,
    MessageDeletion,
    ThumbnailWorker
  }

  alias Eden.Repo
  alias Eden.Storage

  @pubsub Eden.PubSub
  @default_page 50
  # Per-kind upload caps (bytes). The client-side cap is the largest of these;
  # the server enforces the precise per-kind limit on every upload.
  @max_image_bytes 8 * 1024 * 1024
  @max_video_bytes 50 * 1024 * 1024
  @max_file_bytes 25 * 1024 * 1024
  @max_audio_bytes 25 * 1024 * 1024

  # Thumbnails: longest edge in pixels (never upscaled) and JPEG quality.
  @thumbnail_max 800
  @thumbnail_quality 80
  # Reject decompression bombs before decoding: cap the source's *header* pixel
  # count, read from the lazy image without decoding. Generous enough for modern
  # high-MP phone cameras (~16000×12000), tight enough to stop absurd PNG bombs.
  @max_source_pixels 192_000_000

  # Hard ceiling on a single ffmpeg/ffprobe run, so a crafted or corrupt video
  # can't pin a media worker (and starve the :media queue) indefinitely.
  @media_cmd_timeout_ms 20_000

  @doc "Largest accepted upload size in bytes — the client-side ceiling (the server enforces the per-kind cap)."
  def max_attachment_bytes, do: @max_video_bytes

  @doc "Accepted upload size in bytes for a given attachment kind."
  def max_attachment_bytes("image"), do: @max_image_bytes
  def max_attachment_bytes("video"), do: @max_video_bytes
  def max_attachment_bytes("audio"), do: @max_audio_bytes
  def max_attachment_bytes("file"), do: @max_file_bytes

  ## Conversations

  @doc """
  Conversations the scoped user belongs to, most-recent first, with members
  preloaded and the virtual `unread_count` / `last_message_body` filled in.

  Pass a `folder_id` to filter to a custom folder (the folder must belong to the
  user); `nil` is the virtual "All Chats" and shows everything.
  """
  def list_conversations(scope, folder_id \\ nil)

  def list_conversations(%Scope{user: user}, folder_id) do
    conversations =
      Conversation
      |> join(:inner, [c], m in Membership,
        on: m.conversation_id == c.id and m.user_id == ^user.id and is_nil(m.left_at)
      )
      |> filter_by_folder(folder_id, user.id)
      |> order_by([c], desc_nulls_last: c.last_message_at, desc: c.id)
      |> preload(memberships: :user)
      |> Repo.all()

    ids = Enum.map(conversations, & &1.id)
    previews = last_message_previews(user, ids)
    unread = unread_counts(user, ids)
    muted = muted_conversation_ids(user, ids)

    Enum.map(conversations, fn conversation ->
      %{
        conversation
        | unread_count: Map.get(unread, conversation.id, 0),
          muted: conversation.id in muted
      }
      |> apply_preview(previews[conversation.id])
    end)
  end

  # Conversations the user muted — directly (memberships.muted_at) or by muting
  # a folder the chat lives in. Muted-anywhere wins: it stops contributing to
  # every badge, and the row renders de-emphasized. Returns a plain id list
  # (sidebar-sized; also sidesteps dialyzer's opaque-MapSet false positive).
  defp muted_conversation_ids(_user, []), do: []

  defp muted_conversation_ids(user, ids) do
    direct =
      from m in Membership,
        where: m.user_id == ^user.id and m.conversation_id in ^ids and not is_nil(m.muted_at),
        select: m.conversation_id

    via_folder = muted_via_folder_query(user) |> where([fm], fm.conversation_id in ^ids)

    Enum.uniq(Repo.all(direct) ++ Repo.all(via_folder))
  end

  defp filter_by_folder(query, nil, _user_id), do: query

  defp filter_by_folder(query, folder_id, user_id) do
    # Join the folder explicitly on user_id too, so a folder id that isn't the
    # caller's filters to nothing rather than leaking another user's grouping.
    query
    |> join(:inner, [c], fm in FolderMembership, on: fm.conversation_id == c.id)
    |> join(:inner, [c, _m, fm], f in Folder,
      on: f.id == fm.folder_id and f.id == ^folder_id and f.user_id == ^user_id
    )
  end

  # The conversation's preview is the latest message the user can still see — one
  # they haven't "deleted for me" — so a hidden last message falls back to the one
  # before it. A "deleted for both" tombstone is shown as such.
  defp last_message_previews(_user, []), do: %{}

  defp last_message_previews(user, ids) do
    from(m in Message,
      left_join: a in assoc(m, :attachment),
      left_join: d in MessageDeletion,
      on: d.message_id == m.id and d.user_id == ^user.id,
      where: m.conversation_id in ^ids and is_nil(d.id) and is_nil(m.deleted_at),
      distinct: m.conversation_id,
      order_by: [asc: m.conversation_id, desc: m.id],
      select: {m.conversation_id, %{body: m.body, kind: a.kind}}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp apply_preview(conversation, nil),
    do: %{conversation | last_message_body: nil, last_message_kind: nil}

  defp apply_preview(conversation, preview),
    do: %{conversation | last_message_body: preview.body, last_message_kind: preview.kind}

  defp unread_counts(_user, []), do: %{}

  defp unread_counts(user, ids) do
    from(m in Message,
      join: mem in Membership,
      on: mem.conversation_id == m.conversation_id and mem.user_id == ^user.id,
      # Don't count tombstones or messages this user deleted for themselves.
      left_join: d in MessageDeletion,
      on: d.message_id == m.id and d.user_id == ^user.id,
      where:
        m.conversation_id in ^ids and m.sender_id != ^user.id and
          is_nil(m.deleted_at) and is_nil(d.id) and
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

  @doc "Like get_conversation/2 but with the virtual unread_count / last_message_body / muted filled in."
  def get_conversation_summary(%Scope{user: user} = scope, id) do
    with {:ok, conversation} <- get_conversation(scope, id) do
      conversation = %{
        conversation
        | unread_count: Map.get(unread_counts(user, [id]), id, 0),
          muted: id in muted_conversation_ids(user, [id])
      }

      {:ok, apply_preview(conversation, last_message_previews(user, [id])[id])}
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

  @doc """
  "Deletes" a conversation for the scoped user: hides it from their list
  (`left_at`). It re-surfaces on new activity. When the last member has left, the
  conversation is garbage-collected — messages and attachment blobs included
  (blobs shared with a forward elsewhere are spared). Broadcasts to the user's
  own sessions. `{:error, :not_found}` if not a member / unknown id.
  """
  def delete_conversation(%Scope{user: user} = scope, conversation_id) do
    with id when is_integer(id) <- safe_id(conversation_id),
         true <- member?(scope, id),
         {:ok, orphan_keys} <- leave_and_maybe_gc(user, id) do
      # Side effect (irreversible) only after the DB change commits.
      delete_unreferenced_blobs(orphan_keys)
      Phoenix.PubSub.broadcast(@pubsub, user_topic(user.id), {:conversation_left, id})
      :ok
    else
      false -> {:error, :not_found}
      :error -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  # Mark the actor as left and, if nobody is left, garbage-collect the
  # conversation — atomically, so a concurrent deliver can't slip a message (and
  # clear left_at) between the "is anyone left?" check and the hard delete.
  # Returns the blob keys to delete after the transaction commits.
  defp leave_and_maybe_gc(user, conversation_id) do
    Repo.transact(fn ->
      Repo.update_all(
        from(m in Membership,
          where: m.conversation_id == ^conversation_id and m.user_id == ^user.id
        ),
        set: [left_at: now()]
      )

      {:ok, if(all_members_left?(conversation_id), do: gc_collect(conversation_id), else: [])}
    end)
  end

  defp all_members_left?(conversation_id) do
    not Repo.exists?(
      from m in Membership, where: m.conversation_id == ^conversation_id and is_nil(m.left_at)
    )
  end

  # In-transaction GC: collect the conversation's blob keys, then hard-delete it.
  # The DB cascades messages, memberships, attachments and message_deletions.
  defp gc_collect(conversation_id) do
    keys =
      Repo.all(
        from a in Attachment,
          join: m in Message,
          on: m.id == a.message_id,
          where: m.conversation_id == ^conversation_id,
          select: [a.storage_key, a.thumbnail_key]
      )
      |> List.flatten()
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Repo.delete_all(from c in Conversation, where: c.id == ^conversation_id)
    keys
  end

  ## Folders

  @doc """
  The scoped user's custom folders, ordered for the tab carousel, each with its
  `unread_count` (across the folder's non-left conversations) filled in. "All
  Chats" is virtual and not part of this list.
  """
  def list_folders(%Scope{user: user}) do
    folders =
      Repo.all(
        from f in Folder, where: f.user_id == ^user.id, order_by: [asc: f.position, asc: f.id]
      )

    # Most users have no folders; skip the (heavier) unread query entirely then —
    # this runs on every :conversation_activity ping.
    if folders == [] do
      []
    else
      unread = folder_unread_counts(user)
      Enum.map(folders, &%{&1 | unread_count: Map.get(unread, &1.id, 0)})
    end
  end

  # Per-folder unread totals — same rule as unread_counts/2, grouped by folder
  # (a chat in several folders counts toward each). Left conversations are
  # skipped, and so are muted ones: muted directly (memberships.muted_at) or
  # living in ANY muted folder — a muted chat stops contributing to every badge
  # (a muted folder's own badge therefore naturally drops to zero).
  defp folder_unread_counts(user) do
    from(f in Folder,
      join: fm in FolderMembership,
      on: fm.folder_id == f.id,
      join: mem in Membership,
      on:
        mem.conversation_id == fm.conversation_id and mem.user_id == ^user.id and
          is_nil(mem.left_at) and is_nil(mem.muted_at),
      join: msg in Message,
      on: msg.conversation_id == fm.conversation_id,
      left_join: d in MessageDeletion,
      on: d.message_id == msg.id and d.user_id == ^user.id,
      where: f.user_id == ^user.id,
      where: fm.conversation_id not in subquery(muted_via_folder_query(user)),
      where: msg.sender_id != ^user.id and is_nil(msg.deleted_at) and is_nil(d.id),
      where: is_nil(mem.last_read_at) or msg.inserted_at > mem.last_read_at,
      group_by: f.id,
      select: {f.id, count(msg.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  # Conversations sitting in any of the user's muted folders.
  defp muted_via_folder_query(user) do
    from fm in FolderMembership,
      join: f in Folder,
      on: f.id == fm.folder_id,
      where: f.user_id == ^user.id and not is_nil(f.muted_at),
      select: fm.conversation_id
  end

  # A generous sanity cap — Telegram allows about this many. Keeps a runaway
  # client from flooding the tab carousel (and every list_folders query).
  @max_folders 20

  @doc "Most folders a user can have (`create_folder/2` returns `{:error, :limit}` beyond it)."
  def max_folders, do: @max_folders

  @doc "Creates a folder for the scoped user (appended after existing ones)."
  def create_folder(%Scope{user: user}, attrs) do
    count = Repo.aggregate(from(f in Folder, where: f.user_id == ^user.id), :count)

    if count >= @max_folders do
      {:error, :limit}
    else
      result =
        %Folder{user_id: user.id, position: next_folder_position(user)}
        |> Folder.changeset(attrs)
        |> Repo.insert()

      with {:ok, _folder} <- result, do: broadcast_folders(user.id)
      result
    end
  end

  defp next_folder_position(user) do
    Repo.one(
      from f in Folder, where: f.user_id == ^user.id, select: coalesce(max(f.position), -1)
    ) +
      1
  end

  @doc "Renames one of the scoped user's folders. `{:error, :not_found}` if not theirs."
  def rename_folder(%Scope{user: user} = scope, folder_id, name) do
    with %Folder{} = folder <- get_folder(scope, folder_id),
         {:ok, folder} <- folder |> Folder.changeset(%{"name" => name}) |> Repo.update() do
      broadcast_folders(user.id)
      {:ok, folder}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @doc "Deletes one of the scoped user's folders (its memberships cascade; the chats stay)."
  def delete_folder(%Scope{user: user} = scope, folder_id) do
    case get_folder(scope, folder_id) do
      %Folder{} = folder ->
        Repo.delete(folder)
        broadcast_folders(user.id)
        :ok

      nil ->
        {:error, :not_found}
    end
  end

  @doc """
  Reorders the scoped user's folders to match `ordered_ids` (ids not owned by the
  user are ignored). Positions are reassigned 0..n by list order, in one tx. The
  list may contain the `"all"` sentinel — the virtual "All Chats" tab — whose
  index in the list is persisted as the user's `all_chats_position`.
  """
  def reorder_folders(%Scope{user: user}, ordered_ids) do
    owned = MapSet.new(Repo.all(from f in Folder, where: f.user_id == ^user.id, select: f.id))

    entries =
      ordered_ids
      |> Enum.map(fn
        "all" -> :all
        id -> safe_id(id)
      end)
      |> Enum.filter(&(&1 == :all or MapSet.member?(owned, &1)))

    all_pos = Enum.find_index(entries, &(&1 == :all))
    ids = Enum.reject(entries, &(&1 == :all))

    {:ok, _} =
      Repo.transact(fn ->
        ids
        |> Enum.with_index()
        |> Enum.each(fn {id, pos} ->
          Repo.update_all(from(f in Folder, where: f.id == ^id), set: [position: pos])
        end)

        if all_pos, do: put_all_chats_position(user.id, all_pos)
        {:ok, :ok}
      end)

    broadcast_folders(user.id)
    :ok
  end

  @doc "Position of the virtual \"All Chats\" tab among the user's folders (0 = first)."
  def all_chats_position(%Scope{user: user}) do
    Repo.one(from p in FolderPrefs, where: p.user_id == ^user.id, select: p.all_chats_position) ||
      0
  end

  defp put_all_chats_position(user_id, position) do
    Repo.insert!(%FolderPrefs{user_id: user_id, all_chats_position: position},
      on_conflict: [set: [all_chats_position: position, updated_at: now()]],
      conflict_target: :user_id
    )
  end

  ## Mute

  @doc """
  Mutes / unmutes a conversation for the scoped user (their membership's
  `muted_at`). Muting only affects badge emphasis — eden has no push or sound.
  Returns `{:ok, :muted | :unmuted}` or `{:error, :not_found}`.
  """
  def toggle_conversation_mute(%Scope{user: user}, conversation_id) do
    with id when is_integer(id) <- safe_id(conversation_id),
         %Membership{} = membership <-
           Repo.get_by(Membership, conversation_id: id, user_id: user.id) do
      muted_at = if membership.muted_at, do: nil, else: now()

      # update_all: a no-op (not a StaleEntryError) if the membership vanished
      # concurrently — e.g. the conversation was GC'd mid-click.
      Repo.update_all(from(m in Membership, where: m.id == ^membership.id),
        set: [muted_at: muted_at]
      )

      broadcast_folders(user.id)
      {:ok, if(muted_at, do: :muted, else: :unmuted)}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Mutes / unmutes one of the scoped user's folders (`chat_folders.muted_at`):
  every chat in it stops contributing to badges. Un-muting the folder does not
  un-mute chats that were muted directly. Returns `{:ok, :muted | :unmuted}` or
  `{:error, :not_found}`.
  """
  def toggle_folder_mute(%Scope{user: user} = scope, folder_id) do
    case get_folder(scope, folder_id) do
      %Folder{} = folder ->
        muted_at = if folder.muted_at, do: nil, else: now()

        # update_all: a no-op (not a StaleEntryError) if the folder was deleted
        # concurrently in Settings.
        Repo.update_all(from(f in Folder, where: f.id == ^folder.id), set: [muted_at: muted_at])

        broadcast_folders(user.id)
        {:ok, if(muted_at, do: :muted, else: :unmuted)}

      nil ->
        {:error, :not_found}
    end
  end

  ## Search

  @search_limit 20
  @search_min_chars 2

  @doc """
  Searches the scoped user's chats: conversations by participant display name /
  username (or group title) and messages by body. Everything is scoped through
  the user's memberships — nothing outside their conversations can match.

  Plain `ILIKE '%term%'` substring matching, right-sized for this scale; the
  upgrade path (Postgres FTS / pg_trgm) is documented in issue #12. Returns
  `%{conversations: [...], messages: [...]}` (each capped at #{@search_limit});
  a blank or single-character query returns empty lists.
  """
  def search(%Scope{user: user}, query) do
    term = query |> to_string() |> String.trim()

    if String.length(term) < @search_min_chars do
      %{conversations: [], messages: []}
    else
      pattern = "%" <> escape_like(term) <> "%"

      %{
        conversations: search_conversations(user, pattern),
        messages: search_messages(user, pattern)
      }
    end
  end

  # %, _ and \ are LIKE metacharacters; escape them so they match literally.
  defp escape_like(term), do: String.replace(term, ~r/[\\%_]/, fn ch -> "\\" <> ch end)

  defp search_conversations(user, pattern) do
    from(c in Conversation,
      join: my in Membership,
      on: my.conversation_id == c.id and my.user_id == ^user.id and is_nil(my.left_at),
      join: m in Membership,
      on: m.conversation_id == c.id,
      join: u in User,
      on: u.id == m.user_id,
      where:
        ilike(c.title, ^pattern) or
          (u.id != ^user.id and (ilike(u.display_name, ^pattern) or ilike(u.username, ^pattern))),
      distinct: c.id,
      limit: @search_limit,
      preload: [memberships: :user]
    )
    |> Repo.all()
    |> Enum.sort_by(&(&1.last_message_at || ~U[1970-01-01 00:00:00Z]), {:desc, DateTime})
  end

  defp search_messages(user, pattern) do
    from(m in Message,
      join: mem in Membership,
      on:
        mem.conversation_id == m.conversation_id and mem.user_id == ^user.id and
          is_nil(mem.left_at),
      left_join: d in MessageDeletion,
      on: d.message_id == m.id and d.user_id == ^user.id,
      where: ilike(m.body, ^pattern) and is_nil(m.deleted_at) and is_nil(d.id),
      order_by: [desc: m.id],
      limit: @search_limit,
      preload: [:sender, conversation: [memberships: :user]]
    )
    |> Repo.all()
  end

  @doc """
  Toggles a conversation's membership in one of the scoped user's folders. Both
  the folder (must be the user's) and the conversation (must be a member) are
  authorized. Returns `{:ok, :added | :removed}` or `{:error, :not_found}`.
  """
  def toggle_conversation_folder(%Scope{user: user} = scope, conversation_id, folder_id) do
    with cid when is_integer(cid) <- safe_id(conversation_id),
         true <- member?(scope, cid),
         %Folder{id: fid} <- get_folder(scope, folder_id),
         {:ok, result} <- do_toggle_folder(fid, cid) do
      broadcast_folders(user.id)
      {:ok, result}
    else
      _ -> {:error, :not_found}
    end
  end

  # Concurrency-safe toggle: delete_all is a no-op when another session already
  # removed the row (Repo.delete would raise StaleEntryError), and
  # on_conflict: :nothing absorbs a duplicate insert. An insert that fails for a
  # real reason (e.g. the folder was deleted mid-flight) surfaces as an error
  # instead of a false {:ok, :added}.
  defp do_toggle_folder(folder_id, conversation_id) do
    existing =
      Repo.one(
        from fm in FolderMembership,
          where: fm.folder_id == ^folder_id and fm.conversation_id == ^conversation_id
      )

    if existing do
      Repo.delete_all(from fm in FolderMembership, where: fm.id == ^existing.id)
      {:ok, :removed}
    else
      %FolderMembership{}
      |> FolderMembership.changeset(%{folder_id: folder_id, conversation_id: conversation_id})
      |> Repo.insert(on_conflict: :nothing)
      |> case do
        {:ok, _} -> {:ok, :added}
        {:error, _} -> {:error, :conflict}
      end
    end
  end

  @doc "Ids of the scoped user's folders the conversation is filed in (for the picker)."
  def conversation_folder_ids(%Scope{user: user}, conversation_id) do
    case safe_id(conversation_id) do
      cid when is_integer(cid) ->
        Repo.all(
          from fm in FolderMembership,
            join: f in Folder,
            on: f.id == fm.folder_id,
            where: f.user_id == ^user.id and fm.conversation_id == ^cid,
            select: fm.folder_id
        )

      _ ->
        []
    end
  end

  defp get_folder(%Scope{user: user}, folder_id) do
    case safe_id(folder_id) do
      id when is_integer(id) ->
        Repo.one(from f in Folder, where: f.id == ^id and f.user_id == ^user.id)

      _ ->
        nil
    end
  end

  defp broadcast_folders(user_id),
    do: Phoenix.PubSub.broadcast(@pubsub, user_topic(user_id), :folders_changed)

  ## Messages

  @doc """
  Messages in a conversation, oldest-first, with the sender preloaded. Paginates
  backwards: pass `before:` (a message id) to load the page before it, `limit:`
  to size the page (default #{@default_page}). `{:error, :not_found}` if the user
  is not a member.
  """
  def list_messages(%Scope{user: user} = scope, conversation_id, opts \\ []) do
    if member?(scope, conversation_id) do
      limit = Keyword.get(opts, :limit, @default_page)

      messages =
        Message
        |> where([m], m.conversation_id == ^conversation_id)
        # Drop "deleted for everyone" rows entirely, and ones this user hid.
        |> where([m], is_nil(m.deleted_at))
        |> join(:left, [m], d in MessageDeletion,
          on: d.message_id == m.id and d.user_id == ^user.id
        )
        |> where([_m, d], is_nil(d.id))
        |> before_cursor(opts[:before])
        |> order_by([m], desc: m.id)
        |> limit(^limit)
        |> preload([:sender, :attachment, forwarded_from: :sender])
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
        {:error, changeset} -> resolve_duplicate(changeset, user.id)
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  Posts a message with an attachment. The file's `kind` (image | video | file)
  is decided by its magic bytes — never the client content-type — and arbitrary
  files are accepted as `file` with a safe inferred type and sanitized name. The
  blob is stored via the storage adapter and the message + attachment inserted
  atomically. `source` is a map with `:path` (a local temp file) and optional
  `:filename`, `:body` caption and `:client_id`.

  Returns `{:ok, message}` (attachment preloaded) or `{:error, reason}` where
  reason is `:not_found | :too_large` or a changeset.
  """
  def create_attachment_message(%Scope{user: user} = scope, conversation_id, source) do
    with true <- member?(scope, conversation_id),
         {:ok, kind, content_type, ext} <- classify(source.path, source[:filename]),
         {:ok, byte_size} <- check_size(source.path, kind),
         key = Storage.build_key("attachments", ext),
         :ok <- Storage.put(key, source.path) do
      {width, height} = media_dimensions(kind, source.path)

      attrs = %{
        kind: kind,
        storage_key: key,
        content_type: content_type,
        byte_size: byte_size,
        filename: source[:filename],
        width: width,
        height: height
      }

      persist_attachment(user, conversation_id, source, attrs)
    else
      false -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_attachment(user, conversation_id, source, %{kind: kind, storage_key: key} = attrs) do
    message_attrs = %{"body" => Map.get(source, :body, ""), "client_id" => source[:client_id]}

    case insert_attachment_message(user, conversation_id, message_attrs, attrs) do
      {:ok, message} ->
        message = deliver(conversation_id, message)
        if needs_media_processing?(kind), do: enqueue_thumbnail(message.attachment)
        {:ok, message}

      {:error, changeset} ->
        # The blob we just stored is unneeded whether this is a hard error or a
        # duplicate resend (the original already has its own attachment).
        Storage.delete(key)
        resolve_duplicate(changeset, user.id)
    end
  end

  # Original pixel dimensions for an image (from the header, lazily). Video
  # dimensions are read by the media worker (libvips can't decode video), so
  # they start nil here.
  defp media_dimensions("image", path), do: image_dimensions(path)
  defp media_dimensions(_kind, _path), do: {nil, nil}

  ## Message management (delete, forward)

  @doc """
  Hides a message from the scoped user only ("delete for me"). Idempotent; the
  message stays visible to everyone else. Broadcasts to the user's other sessions
  so they hide it too. `{:error, :not_found}` if not a member / unknown id.
  """
  def delete_message_for_me(%Scope{user: user} = scope, message_id) do
    with {:ok, message} <- fetch_message(scope, message_id),
         {:ok, _deletion} <-
           %MessageDeletion{}
           |> Ecto.Changeset.change(message_id: message.id, user_id: user.id)
           |> Repo.insert(on_conflict: :nothing, conflict_target: [:message_id, :user_id]) do
      Phoenix.PubSub.broadcast(
        @pubsub,
        user_topic(user.id),
        {:message_hidden, message.conversation_id, message.id}
      )

      :ok
    end
  end

  @doc """
  Deletes a message for everyone ("delete for both") — sender only. Soft-deletes
  the row (tombstone: `deleted_at` set, body cleared, attachment removed),
  deletes the attachment's blobs unless another attachment still references them
  (a forward shares the blob), and broadcasts the tombstone. `{:error, :not_found}`
  for unknown/non-member, `{:error, :forbidden}` if not the sender.
  """
  def delete_message_for_both(%Scope{user: user} = scope, message_id) do
    with {:ok, message} <- fetch_message(scope, message_id),
         :ok <- ensure_sender(message, user.id),
         {:ok, {tombstone, candidate_keys}} <- soft_delete(message) do
      # Storage.delete is irreversible, so it runs only after the tombstone
      # commits, re-checking references (the attachment row is gone) to close the
      # window where a concurrent forward grabbed the same blob.
      delete_unreferenced_blobs(candidate_keys)

      broadcast(message.conversation_id, {:message_deleted, tombstone})
      notify_members(message.conversation_id)
      :ok
    end
  end

  @doc """
  Forwards a message into another conversation the scoped user belongs to: a new
  message copying the body and (re-referencing) the attachment, attributed to the
  forwarder. The copied attachment points at the same blob; serving stays
  authorized by the target conversation's membership. `{:error, :not_found |
  :deleted}`.
  """
  def forward_message(%Scope{user: user} = scope, message_id, target_conversation_id) do
    with {:ok, source} <- fetch_message(scope, message_id),
         :ok <- ensure_not_deleted(source),
         target_id when is_integer(target_id) <- safe_id(target_conversation_id),
         :ok <- ensure_member(scope, target_id) do
      do_forward(user, target_id, Repo.preload(source, :attachment))
    else
      :error -> {:error, :not_found}
      error -> error
    end
  end

  defp do_forward(user, target_conversation_id, source) do
    case insert_forward_tx(user, target_conversation_id, source) do
      {:ok, message} -> {:ok, deliver(target_conversation_id, message)}
      error -> error
    end
  end

  defp insert_forward_tx(user, target_conversation_id, source) do
    Repo.transact(fn ->
      with {:ok, message} <- insert_forward(user, target_conversation_id, source),
           :ok <- copy_attachment(message.id, source.attachment) do
        {:ok, message}
      end
    end)
  end

  # Fetches a message in a conversation the scoped user belongs to (authorization).
  defp fetch_message(%Scope{user: user}, message_id) do
    with id when is_integer(id) <- safe_id(message_id),
         %Message{} = message <-
           Repo.one(
             from m in Message,
               join: mem in Membership,
               on: mem.conversation_id == m.conversation_id and mem.user_id == ^user.id,
               where: m.id == ^id
           ) do
      {:ok, message}
    else
      _ -> {:error, :not_found}
    end
  end

  defp ensure_sender(%Message{sender_id: sender_id}, user_id) when sender_id == user_id, do: :ok
  defp ensure_sender(_message, _user_id), do: {:error, :forbidden}

  defp ensure_not_deleted(message),
    do: if(Message.deleted?(message), do: {:error, :deleted}, else: :ok)

  defp ensure_member(scope, conversation_id),
    do: if(member?(scope, conversation_id), do: :ok, else: {:error, :not_found})

  # Tombstone the message and delete its attachment row inside one transaction,
  # returning the blob keys safe to delete afterwards (no side effects in the txn).
  defp soft_delete(message) do
    Repo.transact(fn ->
      message = Repo.preload(message, :attachment)
      orphan_keys = unshared_blob_keys(message.attachment)
      if message.attachment, do: Repo.delete(message.attachment)

      with {:ok, tombstone} <-
             message
             |> Ecto.Changeset.change(deleted_at: now(), body: "")
             |> Repo.update() do
        {:ok, {Repo.preload(tombstone, [:sender, :attachment], force: true), orphan_keys}}
      end
    end)
  end

  # Blob keys that no OTHER attachment references — safe to delete once this
  # attachment's row is gone. (Forwards re-reference the same storage_key.)
  defp unshared_blob_keys(nil), do: []

  defp unshared_blob_keys(%Attachment{} = attachment) do
    [attachment.storage_key, attachment.thumbnail_key]
    |> Enum.reject(fn key -> is_nil(key) or blob_shared?(key, attachment.id) end)
  end

  defp blob_shared?(key, exclude_id) do
    Repo.exists?(
      from a in Attachment,
        where: a.id != ^exclude_id and (a.storage_key == ^key or a.thumbnail_key == ^key)
    )
  end

  # Delete each blob no remaining attachment references — the one place every
  # delete path (message delete-for-both, conversation GC) funnels through, so the
  # "spare a blob a forward still shares" invariant can't drift. Runs post-commit,
  # when the deleting rows are already gone; one query, not one per key.
  defp delete_unreferenced_blobs([]), do: :ok

  defp delete_unreferenced_blobs(keys) do
    referenced =
      Repo.all(
        from a in Attachment,
          where: a.storage_key in ^keys or a.thumbnail_key in ^keys,
          select: [a.storage_key, a.thumbnail_key]
      )
      |> List.flatten()
      |> MapSet.new()

    keys
    |> Enum.reject(&MapSet.member?(referenced, &1))
    |> Enum.each(&Storage.delete/1)

    :ok
  end

  defp insert_forward(user, target_conversation_id, source) do
    # Forwarding a forward keeps the original author as the attribution root.
    %Message{
      conversation_id: target_conversation_id,
      sender_id: user.id,
      forwarded_from_id: source.forwarded_from_id || source.id
    }
    |> Message.photo_changeset(%{"body" => source.body || ""})
    |> Repo.insert()
  end

  defp copy_attachment(_message_id, nil), do: :ok

  defp copy_attachment(message_id, %Attachment{} = source) do
    attrs =
      Map.take(source, [
        :kind,
        :storage_key,
        :content_type,
        :byte_size,
        :filename,
        :width,
        :height,
        :duration,
        :thumbnail_key
      ])

    %Attachment{message_id: message_id}
    |> Attachment.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, attachment} ->
        # If we forwarded before the source's preview existed, generate one for
        # the copy (it owns its own thumbnail blob).
        if is_nil(attachment.thumbnail_key) and needs_media_processing?(attachment.kind),
          do: enqueue_thumbnail(attachment)

        :ok

      {:error, changeset} ->
        {:error, changeset}
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
  Produces the attachment's preview off the request path, records it, then
  broadcasts the refreshed message so open clients pick it up. For an image this
  is a downscaled, metadata-stripped JPEG thumbnail; for a video, a poster frame
  (via ffmpeg) plus its duration and dimensions (via ffprobe). Idempotent — a
  no-op once a preview (`thumbnail_key`) exists. Invoked by
  `Eden.Chat.ThumbnailWorker`; returns `:ok` or `{:error, reason}`.
  """
  def generate_thumbnail(%Attachment{thumbnail_key: key}) when is_binary(key), do: :ok

  def generate_thumbnail(%Attachment{kind: "video"} = attachment),
    do: generate_video_preview(attachment)

  def generate_thumbnail(%Attachment{} = attachment) do
    with {:ok, bytes} <- Storage.read(attachment.storage_key),
         {:ok, jpeg} <- make_thumbnail(bytes) do
      store_thumbnail(attachment, jpeg)
    end
  end

  @doc "Whether the scoped user belongs to the conversation."
  def member?(%Scope{user: user}, conversation_id) do
    Repo.exists?(
      from m in Membership, where: m.conversation_id == ^conversation_id and m.user_id == ^user.id
    )
  end

  @doc """
  Fetches another user the scoped user shares at least one conversation with.
  This is the authorization boundary for viewing a profile: you may see a user
  only when you already share a conversation with them. Returns `{:ok, %User{}}`
  (profile fields included) or `{:error, :not_found}` for an unknown, unshared,
  or non-numeric id. Note: a user always shares conversations with themselves.
  """
  def get_shared_user(%Scope{user: user}, other_id) do
    with id when is_integer(id) <- safe_id(other_id),
         true <- shares_conversation?(user.id, id),
         %User{} = other <- Repo.get(User, id) do
      {:ok, other}
    else
      _ -> {:error, :not_found}
    end
  end

  defp shares_conversation?(user_id, other_id) do
    Repo.exists?(
      from m1 in Membership,
        join: m2 in Membership,
        on: m2.conversation_id == m1.conversation_id,
        where: m1.user_id == ^user_id and m2.user_id == ^other_id
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

  # Tell every active member's chat process that this conversation changed
  # (reorder / unread / preview in the sidebar), without leaking message contents.
  # Members who left are skipped — a left group member must not be pulled back in
  # (a 1:1 leaver has already had `left_at` cleared by resurface_direct/1).
  defp notify_members(conversation_id) do
    member_ids =
      Repo.all(
        from m in Membership,
          where: m.conversation_id == ^conversation_id and is_nil(m.left_at),
          select: m.user_id
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

  # Like normalize_id/1 but never raises — for ids that arrive straight from a
  # client event, where a non-numeric value should mean "not found", not a crash.
  defp safe_id(id) when is_integer(id), do: id

  defp safe_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> :error
    end
  end

  defp safe_id(_id), do: :error

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # Touch the conversation, preload, and fan out the new message.
  defp deliver(conversation_id, message) do
    touch_conversation(conversation_id, message.inserted_at)
    resurface_direct(conversation_id)
    message = Repo.preload(message, [:sender, :attachment])
    broadcast(conversation_id, {:new_message, message})
    notify_members(conversation_id)
    message
  end

  # New activity un-hides a deleted 1:1 (messaging someone back re-opens the
  # thread). Leaving a *group* is permanent, so group memberships keep `left_at`.
  defp resurface_direct(conversation_id) do
    Repo.update_all(
      from(m in Membership,
        join: c in Conversation,
        on: c.id == m.conversation_id,
        where:
          m.conversation_id == ^conversation_id and not is_nil(m.left_at) and c.is_group == false
      ),
      set: [left_at: nil]
    )
  end

  defp insert_attachment_message(user, conversation_id, message_attrs, attachment_attrs) do
    Repo.transact(fn ->
      with {:ok, message} <-
             %Message{conversation_id: conversation_id, sender_id: user.id}
             |> Message.photo_changeset(message_attrs)
             |> Repo.insert(),
           {:ok, _attachment} <-
             %Attachment{message_id: message.id}
             |> Attachment.changeset(attachment_attrs)
             |> Repo.insert() do
        {:ok, message}
      end
    end)
  end

  # A failed insert whose only problem is the (sender, client_id) unique index is
  # a safe resend after a reconnect: return the already-stored message instead of
  # erroring, and don't re-broadcast (the original send already did).
  defp resolve_duplicate(changeset, sender_id) do
    with true <- duplicate_client_id?(changeset),
         client_id when is_binary(client_id) <- Ecto.Changeset.get_field(changeset, :client_id),
         %Message{} = message <- fetch_by_client_id(sender_id, client_id) do
      {:ok, message}
    else
      _ -> {:error, changeset}
    end
  end

  defp duplicate_client_id?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:client_id, {_msg, opts}} -> opts[:constraint] == :unique
      _ -> false
    end)
  end

  defp fetch_by_client_id(sender_id, client_id) do
    Repo.one(
      from m in Message,
        where: m.sender_id == ^sender_id and m.client_id == ^client_id,
        preload: [:sender, :attachment]
    )
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
         :ok <- guard_dimensions(Image.width(image), Image.height(image)),
         {:ok, thumb} <-
           Vix.Vips.Operation.thumbnail_buffer(bytes, @thumbnail_max, size: :VIPS_SIZE_DOWN),
         {:ok, jpeg} <-
           Image.write(thumb, :memory,
             suffix: ".jpg",
             quality: @thumbnail_quality,
             strip_metadata: true
           ) do
      {:ok, jpeg}
    else
      # A bad/oversized image is a permanent failure (tagged so the worker cancels
      # rather than retries); transient errors live in generate_thumbnail instead.
      {:error, reason} -> {:error, {:unprocessable, reason}}
    end
  rescue
    e ->
      Logger.error("thumbnail generation crashed: #{Exception.message(e)}")
      {:error, {:unprocessable, Exception.message(e)}}
  end

  defp guard_dimensions(width, height) when width * height <= @max_source_pixels, do: :ok
  defp guard_dimensions(_width, _height), do: {:error, :too_large}

  defp store_thumbnail(attachment, jpeg) do
    thumb_key = Storage.build_key("thumbnails", "jpg")

    with :ok <- Storage.put_binary(thumb_key, jpeg),
         {:ok, _attachment} <- update_thumbnail(attachment, thumb_key) do
      broadcast_thumbnail(attachment.message_id)
      :ok
    else
      error ->
        # Don't leak the thumbnail blob if the DB update failed mid-way.
        Storage.delete(thumb_key)
        error
    end
  end

  defp update_thumbnail(attachment, thumb_key) do
    attachment
    |> Attachment.changeset(%{thumbnail_key: thumb_key})
    |> Repo.update()
  end

  # Best-effort original dimensions from the header (lazy — no full decode). Never
  # raises out: an unreadable file yields {nil, nil} so it can't fail an upload.
  defp image_dimensions(path) do
    case Image.open(path) do
      {:ok, image} -> {Image.width(image), Image.height(image)}
      {:error, _} -> {nil, nil}
    end
  rescue
    _ -> {nil, nil}
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

  # Classify an upload by its magic bytes — never the client content-type. Known
  # image/video signatures set those kinds; everything else is accepted as a
  # generic `file` with a safe inferred type and an extension from its (already
  # sanitized) name. Returns `{:ok, kind, content_type, ext}` or `{:error, _}`.
  # `path` is a server-assigned upload temp file, not a user-supplied path.
  # sobelow_skip ["Traversal.FileModule"]
  defp classify(path, filename) do
    case File.open(path, [:read, :binary], &IO.binread(&1, 16)) do
      {:ok, header} when is_binary(header) ->
        {kind, content_type, ext} = sniff(header, filename)
        {:ok, kind, content_type, ext}

      {:ok, _eof} ->
        {:ok, "file", "application/octet-stream", file_ext(filename) || "bin"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sniff(<<0x89, "PNG\r\n", 0x1A, "\n", _::binary>>, _f), do: {"image", "image/png", "png"}
  defp sniff(<<0xFF, 0xD8, 0xFF, _::binary>>, _f), do: {"image", "image/jpeg", "jpg"}
  defp sniff(<<"GIF87a", _::binary>>, _f), do: {"image", "image/gif", "gif"}
  defp sniff(<<"GIF89a", _::binary>>, _f), do: {"image", "image/gif", "gif"}

  defp sniff(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>, _f),
    do: {"image", "image/webp", "webp"}

  # ISO base media (mp4 / m4v / mov): the "ftyp" box sits at offset 4.
  defp sniff(<<_::binary-size(4), "ftyp", _::binary>>, _f), do: {"video", "video/mp4", "mp4"}
  # Matroska / WebM: the EBML header.
  defp sniff(<<0x1A, 0x45, 0xDF, 0xA3, _::binary>>, _f), do: {"video", "video/webm", "webm"}
  # Known document types — still served as generic downloads, type just informs the client.
  defp sniff(<<"%PDF-", _::binary>>, _f), do: {"file", "application/pdf", "pdf"}

  defp sniff(<<"PK", 0x03, 0x04, _::binary>>, f),
    do: {"file", "application/zip", file_ext(f) || "zip"}

  # Anything else is a generic file: octet-stream + nosniff + attachment disposition.
  defp sniff(_other, f), do: {"file", "application/octet-stream", file_ext(f) || "bin"}

  # Lowercased, key-safe extension (no dot) from a filename, or nil.
  defp file_ext(nil), do: nil

  defp file_ext(name) when is_binary(name) do
    case name |> Path.extname() |> String.trim_leading(".") |> String.downcase() do
      "" -> nil
      ext -> ext |> String.replace(~r/[^a-z0-9]/, "") |> nil_if_empty()
    end
  end

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(s), do: s

  defp check_size(path, kind) do
    max = max_attachment_bytes(kind)

    case File.stat(path) do
      {:ok, %{size: size}} when size > 0 and size <= max -> {:ok, size}
      {:ok, %{size: 0}} -> {:error, :empty}
      {:ok, _stat} -> {:error, :too_large}
      {:error, reason} -> {:error, reason}
    end
  end

  # Which kinds get async media processing (thumbnail for images, poster +
  # duration for video). Files/audio carry no generated preview.
  defp needs_media_processing?("image"), do: true
  defp needs_media_processing?("video"), do: true
  defp needs_media_processing?(_kind), do: false

  ## Video media (ffmpeg/ffprobe, shelled out by the media worker)

  # Extract a poster frame (ffmpeg) + read duration/dimensions (ffprobe), downscale
  # the frame with libvips (reusing the image path), and store it like a thumbnail.
  # A missing ffmpeg or an unreadable file is a permanent failure (tagged so the
  # worker cancels rather than retrying forever); storage/DB hiccups stay transient.
  defp generate_video_preview(%Attachment{} = attachment) do
    with_local_source(attachment.storage_key, fn input ->
      with {:ok, meta} <- ffprobe_meta(input) do
        # The poster is best-effort: a valid video we just can't grab a frame from
        # (e.g. audio-only in an mp4 container) still records its duration/size.
        store_video_preview(attachment, poster_frame(input), meta)
      end
    end)
  end

  defp poster_frame(input) do
    with {:ok, frame} <- ffmpeg_poster_frame(input),
         {:ok, jpeg} <- make_thumbnail(frame) do
      jpeg
    else
      _ -> nil
    end
  end

  # Give ffmpeg/ffprobe a real file path: use the stored blob's local path when the
  # adapter is disk-backed, otherwise download it to a temp file (cleaned up after).
  # The temp path is app-generated (System.tmp_dir! + a unique integer), not user
  # input, so the traversal warnings on write/rm are false positives.
  # sobelow_skip ["Traversal.FileModule"]
  defp with_local_source(storage_key, fun) do
    case Storage.local_path(storage_key) do
      {:ok, path} ->
        fun.(path)

      :error ->
        with {:ok, bytes} <- Storage.read(storage_key) do
          tmp = Path.join(System.tmp_dir!(), "media-src-#{System.unique_integer([:positive])}")
          File.write!(tmp, bytes)

          try do
            fun.(tmp)
          after
            File.rm(tmp)
          end
        end
    end
  end

  defp ffprobe_meta(input) do
    args = [
      "-v",
      "error",
      "-select_streams",
      "v:0",
      "-show_entries",
      "stream=width,height:format=duration",
      "-of",
      "json",
      input
    ]

    with {:ok, out} <- run_media_cmd("ffprobe", args) do
      parse_probe(out)
    end
  end

  defp parse_probe(json) do
    case Jason.decode(json) do
      {:ok, data} ->
        stream = data |> Map.get("streams", []) |> List.first() || %{}
        format = Map.get(data, "format", %{})

        {:ok,
         drop_nil(%{
           width: stream["width"],
           height: stream["height"],
           duration: parse_duration(format["duration"])
         })}

      {:error, _} ->
        {:error, {:unprocessable, :ffprobe_output}}
    end
  end

  defp parse_duration(secs) when is_binary(secs) do
    case Float.parse(secs) do
      {value, _} when value > 0 -> round(value * 1000)
      _ -> nil
    end
  end

  defp parse_duration(_), do: nil

  defp drop_nil(map), do: for({k, v} <- map, not is_nil(v), into: %{}, do: {k, v})

  # sobelow_skip ["Traversal.FileModule"]
  defp ffmpeg_poster_frame(input) do
    out = Path.join(System.tmp_dir!(), "poster-#{System.unique_integer([:positive])}.jpg")

    args = [
      "-nostdin",
      "-v",
      "error",
      "-y",
      "-i",
      input,
      "-map",
      "0:v:0",
      "-vf",
      "thumbnail",
      "-frames:v",
      "1",
      "-f",
      "image2",
      out
    ]

    result =
      with {:ok, _} <- run_media_cmd("ffmpeg", args), do: read_frame(out)

    # Best-effort cleanup of the extracted frame; the poster is stored separately.
    File.rm(out)
    result
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_frame(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, {:unprocessable, reason}}
    end
  end

  defp run_media_cmd(bin, args) do
    case System.find_executable(bin) do
      nil -> {:error, {:unprocessable, :ffmpeg_unavailable}}
      path -> run_with_timeout(bin, path, args)
    end
  end

  # Run the (synchronous, non-cancellable) System.cmd inside a Task so we can
  # bound it: on timeout we abandon the task, freeing the worker. brutal_kill
  # closes the port, which terminates the child process on our deployments.
  # `bin` is a fixed literal resolved via find_executable and args is an argv
  # list (no shell), so there is no injection surface — the sobelow warning is
  # a false positive.
  # sobelow_skip ["CI.System"]
  defp run_with_timeout(bin, path, args) do
    task = Task.async(fn -> System.cmd(path, args, stderr_to_stdout: true) end)

    case Task.yield(task, @media_cmd_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, 0}} ->
        {:ok, out}

      {:ok, {out, code}} ->
        {:error, {:unprocessable, "#{bin} exit #{code}: #{String.slice(out, 0, 200)}"}}

      nil ->
        {:error, {:unprocessable, :media_timeout}}

      {:exit, reason} ->
        {:error, {:unprocessable, {:media_crash, reason}}}
    end
  end

  defp store_video_preview(attachment, poster_jpeg, meta) when is_binary(poster_jpeg) do
    poster_key = Storage.build_key("thumbnails", "jpg")

    with :ok <- Storage.put_binary(poster_key, poster_jpeg),
         {:ok, _attachment} <-
           update_attachment(attachment, Map.put(meta, :thumbnail_key, poster_key)) do
      broadcast_thumbnail(attachment.message_id)
      :ok
    else
      error ->
        Storage.delete(poster_key)
        error
    end
  end

  # No poster, but ffprobe gave us metadata — persist it so the UI still knows the
  # duration/dimensions (and that this is a real video).
  defp store_video_preview(attachment, nil, meta) when map_size(meta) > 0 do
    with {:ok, _attachment} <- update_attachment(attachment, meta) do
      broadcast_thumbnail(attachment.message_id)
      :ok
    end
  end

  defp store_video_preview(_attachment, nil, _meta),
    do: {:error, {:unprocessable, :no_video_data}}

  defp update_attachment(attachment, attrs) do
    attachment |> Attachment.changeset(attrs) |> Repo.update()
  end
end
