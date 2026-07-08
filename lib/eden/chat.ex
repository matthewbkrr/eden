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

  alias Eden.Accounts
  alias Eden.Accounts.{Scope, User}
  alias Eden.Channels

  alias Eden.Chat.{
    Attachment,
    Conversation,
    Folder,
    FolderMembership,
    FolderPrefs,
    Membership,
    Message,
    MessageDeletion,
    MessageReaction,
    ThreadMembership,
    ThumbnailWorker
  }

  alias Eden.Ids
  alias Eden.Images
  alias Eden.Notifications
  alias Eden.Repo
  alias Eden.Storage

  @pubsub Eden.PubSub
  @default_page 50
  # Upper bound for a "jump to message" window load (#permalink/jump-to-root): when the
  # target sits far above the latest message, we still cap how many rows we render so a
  # deep jump in a long history can't load thousands of messages into the stream at once.
  @jump_window 300
  # Associations preloaded with every main-stream message (shared by list_messages/3 and
  # list_messages_around/3 so a window load renders identically to a page load).
  @message_preloads [
    :sender,
    :attachments,
    reactions: :user,
    reply_to: [:sender, :attachments],
    forwarded_from: :sender
  ]
  # Per-kind upload caps (bytes). The client-side cap is the largest of these;
  # the server enforces the precise per-kind limit on every upload.
  @max_image_bytes 8 * 1024 * 1024
  @max_video_bytes 50 * 1024 * 1024
  @max_file_bytes 25 * 1024 * 1024
  @max_audio_bytes 25 * 1024 * 1024

  # Albums (#58): most attachments a single message may carry (Telegram caps at
  # 10 per media group; we mirror it). Each still obeys its own per-kind cap.
  @max_album_entries 10

  # Most media a SINGLE pick may stage in one go (#193). A pick beyond @max_album_entries
  # is split server-side into albums of @max_album_entries (Telegram-style), so the upload
  # config must accept up to this many at once. Bounded so one selection can't be absurd.
  @max_staged_entries 50

  # Thumbnails: longest edge in pixels (never upscaled) and JPEG quality.
  @thumbnail_max 800
  @thumbnail_quality 80
  # HEIC originals are transcoded to JPEG (#123) at this longest-edge cap (matching
  # the #97 client compression) and quality — never upscaled.
  @heic_max 1920
  @heic_quality 85
  # Reject decompression bombs before decoding: cap the source's *header* pixel
  # count, read from the lazy image without decoding. 48 MP (≈6928²) clears any real
  # photo/screenshot yet bounds a PNG/WebP bomb's full decode — the worker thumbnails
  # at :media concurrency 5, so an unbounded header (a few-MB file declaring ~190 MP)
  # would decode to ~576 MB ×5 → OOM on the single-VPS prod (#231). PNG has no
  # shrink-on-load, so the header guard is the only line of defence for that format.
  @max_source_pixels 48_000_000

  # Hard ceiling on a single ffmpeg/ffprobe run, so a crafted or corrupt video
  # can't pin a media worker (and starve the :media queue) indefinitely.
  @media_cmd_timeout_ms 20_000

  # LiveView chunks uploads over the socket and SERIALIZES them (client pushes a chunk, waits for the
  # server's `ok`, reads the next), so upload time ≈ (bytes / chunk) × RTT — bandwidth barely matters.
  # 1MB (vs the 64KB LiveView default) cuts round-trips ~16× on a high-latency cross-border link: a
  # 1MB file is one round-trip, a 5MB photo five. Larger would coarsen the progress ring and push the
  # per-chunk transfer past @upload_chunk_timeout / the 90s watchdog on a slow uplink, so this is the
  # practical sweet spot (chunk_timeout is set to give 1MB headroom). `upload_max_frame_size/0`
  # (endpoint.ex) derives the WS frame cap from this, so bumping it here keeps them in lockstep.
  @upload_chunk_size 1_000_000

  # #289: notification-chime presets. Each is a synthesized tone pattern played
  # client-side (window.edSound.play), so there are no audio assets to ship; the
  # closed set guards the client-supplied name. The head is the default.
  @notify_sound_names ~w(chime ping pop glass block)
  @default_sound "chime"

  @doc "Largest accepted upload size in bytes — the client-side ceiling (the server enforces the per-kind cap)."
  def max_attachment_bytes, do: @max_video_bytes

  @doc "Most attachments a single message (album) may carry."
  def max_album_entries, do: @max_album_entries

  @doc "Most media one pick may stage at once (#193); split server-side into albums of #{@max_album_entries}."
  def max_staged_entries, do: @max_staged_entries

  @doc "Per-chunk upload size (bytes) for every `allow_upload`. Bigger = fewer serialized round-trips on a high-latency link (uploads are RTT-bound, not bandwidth-bound)."
  def upload_chunk_size, do: @upload_chunk_size

  @doc "`max_frame_size` for the /live WebSocket. DERIVED from `upload_chunk_size` (must exceed one chunk + framing overhead) so bumping the chunk can never silently trip Bandit's :max_frame_size_exceeded — 4× is ample headroom."
  def upload_max_frame_size, do: @upload_chunk_size * 4

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
      # Channel rooms live in their channel's sidebar, not the DM list.
      |> where([c], is_nil(c.channel_id))
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
      # Album preview keys off the first attachment (position 0) — its kind picks
      # the icon/label; the count drives "N photos" pluralization in the web layer.
      left_join: a in assoc(m, :attachments),
      on: a.message_id == m.id and a.position == 0,
      left_join: d in MessageDeletion,
      on: d.message_id == m.id and d.user_id == ^user.id,
      # Thread replies never become the sidebar preview (they live in threads), and a
      # system notice (#165 member added/removed) must not become it either — it has an
      # empty body, which would blank the preview to "No messages yet" for an active group.
      where:
        m.conversation_id in ^ids and is_nil(d.id) and is_nil(m.deleted_at) and
          is_nil(m.root_id) and m.kind != "system",
      distinct: m.conversation_id,
      order_by: [asc: m.conversation_id, desc: m.id],
      select:
        {m.conversation_id,
         %{
           body: m.body,
           kind: a.kind,
           attachment_count:
             fragment("(SELECT count(*) FROM attachments WHERE message_id = ?)", m.id)
         }}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp apply_preview(conversation, nil),
    do: %{conversation | last_message_body: nil, last_message_kind: nil}

  defp apply_preview(conversation, preview),
    do: %{
      conversation
      | last_message_body: preview.body,
        last_message_kind: preview.kind,
        last_message_attachment_count: preview.attachment_count
    }

  @doc """
  Aggregate unread per channel for the rail badge: `%{channel_id => count}`
  summing the scoped user's joined-room unreads. Directly-muted rooms
  (`memberships.muted_at`) drop out — same rule as folder badges; channel-level
  mute is applied by the caller (`Eden.Channels.list_channels/1`). Replies and
  tombstones never count (mirrors `unread_counts/2`).
  """
  def channel_unread_counts(%Scope{user: user}) do
    # Conditions split across several `where:` (Ecto ANDs them) rather than one
    # compound expression — keeps cyclomatic complexity in check.
    from(m in Message,
      join: mem in Membership,
      on: mem.conversation_id == m.conversation_id and mem.user_id == ^user.id,
      join: c in Conversation,
      on: c.id == m.conversation_id,
      left_join: d in MessageDeletion,
      on: d.message_id == m.id and d.user_id == ^user.id,
      where: not is_nil(c.channel_id),
      where: is_nil(mem.left_at) and is_nil(mem.muted_at),
      where: m.sender_id != ^user.id,
      where: is_nil(m.deleted_at) and is_nil(d.id) and is_nil(m.root_id),
      where: is_nil(mem.last_read_at) or m.inserted_at > mem.last_read_at,
      group_by: c.channel_id,
      select: {c.channel_id, count(m.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp unread_counts(_user, []), do: %{}

  defp unread_counts(user, ids) do
    from(m in Message,
      join: mem in Membership,
      on: mem.conversation_id == m.conversation_id and mem.user_id == ^user.id,
      # Don't count tombstones or messages this user deleted for themselves.
      left_join: d in MessageDeletion,
      on: d.message_id == m.id and d.user_id == ^user.id,
      # Thread replies are excluded from unread badges in v1 (per-thread
      # unreads are the CRT follow-up) — the thread footer carries the count.
      where:
        m.conversation_id in ^ids and m.sender_id != ^user.id and
          is_nil(m.deleted_at) and is_nil(d.id) and is_nil(m.root_id) and
          (is_nil(mem.last_read_at) or m.inserted_at > mem.last_read_at),
      group_by: m.conversation_id,
      select: {m.conversation_id, count(m.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Total unread across the user's non-muted DM/group conversations — the messenger
  rail badge (mirrors the per-channel rail badge). Rooms are excluded (they have
  their own channel badges). Sums `unread_counts/2` (sender ≠ me, not a tombstone,
  not deleted-for-me, not a reply, after my last read) over the user's active
  non-room chats, the mute filter folded into the id query so a chat muted directly
  (`memberships.muted_at`) or via ANY muted folder never counts — matching the
  `muted_conversation_ids/2` invariant. Two queries (was three).
  """
  def messenger_unread_total(%Scope{user: user}) do
    ids = unmuted_messenger_ids(user)
    unread_counts(user, ids) |> Map.values() |> Enum.sum()
  end

  # Active, non-room memberships, minus chats muted directly or via a muted folder.
  defp unmuted_messenger_ids(user) do
    muted_folder_convs = muted_via_folder_query(user)

    Repo.all(
      from m in Membership,
        join: c in Conversation,
        on: c.id == m.conversation_id,
        where:
          m.user_id == ^user.id and is_nil(m.left_at) and is_nil(c.channel_id) and
            is_nil(m.muted_at) and m.conversation_id not in subquery(muted_folder_convs),
        select: m.conversation_id
    )
  end

  @doc "Fetches a conversation the scoped user belongs to (members preloaded), or `{:error, :not_found}`."
  def get_conversation(%Scope{user: user}, id) do
    query =
      from c in Conversation,
        join: m in Membership,
        on:
          m.conversation_id == c.id and m.user_id == ^user.id and
            (is_nil(m.left_at) or not (c.is_group and is_nil(c.channel_id))),
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
    other_ids =
      other_ids
      |> Enum.map(&normalize_id/1)
      |> Enum.uniq()
      |> List.delete(creator.id)
      |> reachable_user_ids()

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
         # Rooms aren't individually deletable per-user — leaving happens at the
         # channel level; room deletion is an admin action (Channels context).
         false <- room?(id),
         # A group owner can't leave while others remain — they must transfer
         # ownership first (#165), else the group would be left ownerless. Alone,
         # leaving is fine (it GCs the group).
         :ok <- ensure_not_group_owner(id, user.id),
         {:ok, orphan_keys} <- leave_and_maybe_gc(user.id, id) do
      # Side effect (irreversible) only after the DB change commits.
      delete_unreferenced_blobs(orphan_keys)
      Phoenix.PubSub.broadcast(@pubsub, user_topic(user.id), {:conversation_left, id})
      :ok
    else
      # `true` is room?/1 saying "this is a room"; `false` is a failed member?.
      result when result in [true, false, :error] -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  # Mark the actor as left and, if nobody is left, garbage-collect the
  # conversation — atomically, so a concurrent deliver can't slip a message (and
  # clear left_at) between the "is anyone left?" check and the hard delete.
  # Returns the blob keys to delete after the transaction commits.
  defp leave_and_maybe_gc(user_id, conversation_id) do
    Repo.transact(fn ->
      Repo.update_all(
        from(m in Membership,
          where: m.conversation_id == ^conversation_id and m.user_id == ^user_id
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

  ## Group roles & member management (#165)
  #
  # owner > admin > member. Mirrors the Eden.Channels role pattern, scoped to
  # GROUP conversations (is_group, no channel_id). Every function takes a
  # `%Scope{}` and is authorized by the actor's membership role; a non-member or
  # non-group yields `:not_found` (existence not leaked), an under-privileged
  # actor `:forbidden`.

  @doc "The scoped user's role in a group (`owner | admin | member`), or `nil` if not a member."
  def group_role(%Scope{user: user}, conversation_id) do
    case safe_id(conversation_id) do
      id when is_integer(id) -> group_role_of(id, user.id)
      _ -> nil
    end
  end

  @doc """
  Removes a member from a group: marks them left (the group is GC'd if they were
  the last) and pings their sessions with `{:removed_from_conversation, id}` so
  they navigate away and the group disappears for them (Telegram-style). Owners
  may remove admins/members, admins only members; nobody removes the owner or
  themselves.
  """
  def remove_group_member(%Scope{user: actor}, conversation_id, user_id) do
    with id when is_integer(id) <- safe_id(conversation_id),
         true <- group?(id),
         actor_role when is_binary(actor_role) <- group_role_of(id, actor.id),
         :ok <- ensure_role(actor_role, ~w(owner admin)),
         target_id when is_integer(target_id) <- safe_id(user_id),
         false <- target_id == actor.id,
         target_role when is_binary(target_role) <- group_role_of(id, target_id),
         :ok <- ensure_removable(actor_role, target_role) do
      name = Repo.one(from u in User, where: u.id == ^target_id, select: u.display_name)
      {:ok, orphan_keys} = leave_and_maybe_gc(target_id, id)
      delete_unreferenced_blobs(orphan_keys)
      # The remover always stays a member, so the conversation isn't GC'd here — the
      # "removed" notice always lands. Store user_id so a later account deletion can scrub
      # the denormalized name (#305 review).
      create_system_message(id, %{
        "action" => "member_removed",
        "name" => name,
        "user_id" => target_id
      })

      Phoenix.PubSub.broadcast(@pubsub, user_topic(target_id), {:removed_from_conversation, id})
      notify_members(id)
      broadcast(id, {:group_members_changed, id})
      :ok
    else
      true -> {:error, :self}
      false -> {:error, :not_found}
      nil -> {:error, :not_found}
      :error -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  @doc "Promotes/demotes a member between `admin` and `member`. Owner only; never the owner row."
  def set_group_member_role(%Scope{user: actor}, conversation_id, user_id, role)
      when role in ["admin", "member"] do
    with id when is_integer(id) <- safe_id(conversation_id),
         true <- group?(id),
         actor_role when is_binary(actor_role) <- group_role_of(id, actor.id),
         :ok <- ensure_role(actor_role, ~w(owner)),
         target_id when is_integer(target_id) <- safe_id(user_id),
         false <- target_id == actor.id,
         target_role when is_binary(target_role) <- group_role_of(id, target_id),
         :ok <- ensure_role(target_role, ~w(admin member)) do
      update_group_role(id, target_id, role)
      notify_members(id)
      broadcast(id, {:group_members_changed, id})
      :ok
    else
      true -> {:error, :self}
      false -> {:error, :not_found}
      nil -> {:error, :not_found}
      :error -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  # A hand-crafted role (e.g. "owner") is a clean error, not a FunctionClauseError
  # bubbling through the LiveView.
  def set_group_member_role(_scope, _conversation_id, _user_id, _role),
    do: {:error, :invalid_role}

  @doc """
  Hands a group to another member: they become `owner`, the current owner becomes
  `admin` (one transaction). Unblocks the previous owner's leave.
  """
  def transfer_group_ownership(%Scope{user: actor}, conversation_id, user_id) do
    with id when is_integer(id) <- safe_id(conversation_id),
         true <- group?(id),
         actor_role when is_binary(actor_role) <- group_role_of(id, actor.id),
         :ok <- ensure_role(actor_role, ~w(owner)),
         target_id when is_integer(target_id) <- safe_id(user_id),
         false <- target_id == actor.id,
         target_role when is_binary(target_role) <- group_role_of(id, target_id),
         :ok <- transfer_group_tx(id, actor.id, target_id) do
      notify_members(id)
      broadcast(id, {:group_members_changed, id})
      :ok
    else
      true -> {:error, :self}
      false -> {:error, :not_found}
      nil -> {:error, :not_found}
      :error -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  @doc """
  Adds eden users to a group (owner/admin only), re-activating anyone previously
  removed or who left. Posts a "added" system notice per added user and refreshes
  everyone's roster live. Returns `{:ok, [%User{}]}` of the users actually added.
  """
  def add_group_members(%Scope{user: actor}, conversation_id, user_ids) do
    with id when is_integer(id) <- safe_id(conversation_id),
         true <- group?(id),
         actor_role when is_binary(actor_role) <- group_role_of(id, actor.id),
         :ok <- ensure_role(actor_role, ~w(owner admin)) do
      ids = user_ids |> Enum.map(&safe_id/1) |> Enum.filter(&is_integer/1)
      # Real, non-deleted users who aren't already active members (a left/removed member is
      # re-activated). Excluding `deleted_at` keeps an anonymized account (#303) from being
      # re-added via a forged id — deletion is terminal.
      already = active_member_ids(id)

      candidates =
        Repo.all(
          from u in User, where: u.id in ^ids and u.id not in ^already and is_nil(u.deleted_at)
        )

      added =
        Enum.map(candidates, fn u ->
          add_group_membership(id, u.id)
          # Store user_id alongside the denormalized name so a future account deletion can
          # scrub the name from this system message (#305 review).
          create_system_message(id, %{
            "action" => "member_added",
            "name" => u.display_name,
            "user_id" => u.id
          })

          u
        end)

      if added != [] do
        notify_members(id)
        broadcast(id, {:group_members_changed, id})
      end

      {:ok, added}
    else
      false -> {:error, :not_found}
      nil -> {:error, :not_found}
      :error -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  @doc """
  Cross-context cleanup for a permanently-deleted account (#303, #305 review), called by
  the web layer after `Accounts.delete_user_permanently/2` succeeds (contexts don't reach
  into each other). Scrubs the person's display name from the **denormalized** copies in
  system-message `meta` — the knock requester name and the member add/remove notices — so
  anonymization reaches shared history, and deletes their private folders/prefs (no
  shared-history value). Idempotent; safe on a user with nothing to scrub.

  Member add/remove notices written before the `user_id` seam (#305) landed carry no id and
  can't be targeted — those keep the original name (a bounded, documented gap).
  """
  def scrub_deleted_user_content(user_id) when is_integer(user_id) do
    sentinel = Accounts.deleted_display_name()

    scrub_meta_name(user_id, "requester_id", ["requester_name"], sentinel)
    scrub_meta_name(user_id, "user_id", ["name"], sentinel)

    Repo.delete_all(from(f in Folder, where: f.user_id == ^user_id))
    Repo.delete_all(from(p in FolderPrefs, where: p.user_id == ^user_id))
    :ok
  end

  # Overwrite `path` (a jsonb text[] path, e.g. ["name"]) with the sentinel in every system
  # message whose `id_key` in meta points at this user. `update:` fragment references the
  # row's own meta; the path is a fixed literal list (never user input).
  defp scrub_meta_name(user_id, id_key, path, sentinel) do
    from(m in Message,
      where:
        m.kind == "system" and
          fragment("(?->>?)::bigint", m.meta, ^id_key) == ^user_id,
      update: [
        set: [meta: fragment("jsonb_set(?, ?, to_jsonb(?::text))", m.meta, ^path, ^sentinel)]
      ]
    )
    |> Repo.update_all([])
  end

  @doc """
  Renames a group (#165, owner/admin only). A blank title reverts to the auto name
  built from members. Broadcasts so the header / sidebar / panel update live.
  """
  def rename_group(%Scope{user: actor}, conversation_id, title) do
    with id when is_integer(id) <- safe_id(conversation_id),
         true <- group?(id),
         actor_role when is_binary(actor_role) <- group_role_of(id, actor.id),
         :ok <- ensure_role(actor_role, ~w(owner admin)),
         %Conversation{} = conv <- Repo.get(Conversation, id),
         {:ok, renamed} <-
           conv |> Conversation.title_changeset(%{"title" => title}) |> Repo.update() do
      broadcast(id, {:conversation_renamed, renamed})
      notify_members(id)
      {:ok, renamed}
    else
      false -> {:error, :not_found}
      nil -> {:error, :not_found}
      :error -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  @doc """
  Sets a group's photo (#178, owner/admin only). Processes the upload into a square
  JPEG (metadata stripped) via the user/channel avatar pipeline, stores it through the
  Storage adapter, swaps `avatar_key`, and deletes the previous blob. Broadcasts so the
  header / panel / sidebar update live (mirrors `rename_group/3`). Returns
  `{:ok, conversation}` or `{:error, :not_found | :forbidden | :too_large | :unprocessable | reason}`.
  """
  def set_group_avatar(%Scope{user: actor}, conversation_id, source_path) do
    with id when is_integer(id) <- safe_id(conversation_id),
         true <- group?(id),
         actor_role when is_binary(actor_role) <- group_role_of(id, actor.id),
         :ok <- ensure_role(actor_role, ~w(owner admin)),
         %Conversation{} = conv <- Repo.get(Conversation, id),
         {:ok, jpeg} <- Images.square_avatar(source_path) do
      store_and_swap_group_avatar(conv, jpeg)
    else
      false -> {:error, :not_found}
      nil -> {:error, :not_found}
      :error -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp store_and_swap_group_avatar(conv, jpeg) do
    key = Storage.build_key("avatars", "jpg")

    with :ok <- Storage.put_binary(key, jpeg),
         {:ok, updated} <- conv |> Ecto.Changeset.change(avatar_key: key) |> Repo.update() do
      # Best-effort cleanup of the replaced blob (don't fail the update on it).
      if conv.avatar_key, do: Storage.delete(conv.avatar_key)
      broadcast_avatar_change(conv.id, updated)
      {:ok, updated}
    else
      error ->
        # The blob was written but the row update failed (e.g. the group was GC'd
        # mid-flight) — reclaim the orphan.
        Storage.delete(key)
        error
    end
  end

  @doc "Removes a group's photo (#178, owner/admin only) and its blob. `{:ok, conversation}`."
  def remove_group_avatar(%Scope{user: actor}, conversation_id) do
    with id when is_integer(id) <- safe_id(conversation_id),
         true <- group?(id),
         actor_role when is_binary(actor_role) <- group_role_of(id, actor.id),
         :ok <- ensure_role(actor_role, ~w(owner admin)),
         %Conversation{avatar_key: key} = conv <- Repo.get(Conversation, id),
         {:ok, updated} <- conv |> Ecto.Changeset.change(avatar_key: nil) |> Repo.update() do
      if key, do: Storage.delete(key)
      broadcast_avatar_change(conv.id, updated)
      {:ok, updated}
    else
      false -> {:error, :not_found}
      nil -> {:error, :not_found}
      :error -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  # #178: tell every member's session the photo changed, WITHOUT a reorder. Unlike a new
  # message (notify_members → {:conversation_activity}, which bumps the chat to the top), an
  # avatar change isn't activity — so we ping each member's user topic directly and their
  # session refreshes the sidebar in place (natural order), updating the avatar without a bump.
  defp broadcast_avatar_change(conversation_id, conversation) do
    for user_id <- active_member_ids(conversation_id) do
      Phoenix.PubSub.broadcast(
        @pubsub,
        user_topic(user_id),
        {:conversation_avatar_changed, conversation}
      )
    end
  end

  @doc """
  The group's avatar Storage key for the scoped user — only when they're an active
  member and the group has one (authorizes serving, #178). `nil` otherwise, so a
  non-member can't probe existence.
  """
  def group_avatar_key(%Scope{user: user}, conversation_id) do
    case safe_id(conversation_id) do
      id when is_integer(id) ->
        Repo.one(
          from c in Conversation,
            join: m in Membership,
            on: m.conversation_id == c.id and m.user_id == ^user.id and is_nil(m.left_at),
            where: c.id == ^id and not is_nil(c.avatar_key),
            select: c.avatar_key
        )

      _ ->
        nil
    end
  end

  defp active_member_ids(conversation_id) do
    Repo.all(
      from m in Membership,
        where: m.conversation_id == ^conversation_id and is_nil(m.left_at),
        select: m.user_id
    )
  end

  # Insert a fresh membership or, if one exists (a left/removed member), re-activate it.
  defp add_group_membership(conversation_id, user_id) do
    Repo.insert(
      %Membership{conversation_id: conversation_id, user_id: user_id, role: "member"},
      on_conflict: [set: [left_at: nil, role: "member"]],
      conflict_target: [:conversation_id, :user_id]
    )
  end

  # Owners out-rank admins; admins out-rank members. Nobody removes an owner.
  defp ensure_removable("owner", target) when target in ~w(admin member), do: :ok
  defp ensure_removable("admin", "member"), do: :ok
  defp ensure_removable(_actor, _target), do: {:error, :forbidden}

  defp ensure_role(role, allowed) when is_binary(role) do
    if role in allowed, do: :ok, else: {:error, :forbidden}
  end

  # A group owner can't leave while OTHER members remain (transfer first); alone,
  # leaving is allowed and GCs the group.
  defp ensure_not_group_owner(conversation_id, user_id) do
    if group?(conversation_id) and group_role_of(conversation_id, user_id) == "owner" and
         other_members_exist?(conversation_id, user_id) do
      {:error, :owner}
    else
      :ok
    end
  end

  defp other_members_exist?(conversation_id, user_id) do
    Repo.exists?(
      from m in Membership,
        where:
          m.conversation_id == ^conversation_id and m.user_id != ^user_id and is_nil(m.left_at)
    )
  end

  defp group?(conversation_id) do
    Repo.exists?(
      from c in Conversation,
        where: c.id == ^conversation_id and c.is_group == true and is_nil(c.channel_id)
    )
  end

  defp group_role_of(conversation_id, user_id) do
    Repo.one(
      from m in Membership,
        where:
          m.conversation_id == ^conversation_id and m.user_id == ^user_id and is_nil(m.left_at),
        select: m.role
    )
  end

  defp update_group_role(conversation_id, user_id, role) do
    Repo.update_all(
      from(m in Membership,
        where:
          m.conversation_id == ^conversation_id and m.user_id == ^user_id and is_nil(m.left_at)
      ),
      set: [role: role]
    )
  end

  # The promotion is count-checked: if the target left between the read and the
  # write, rolling back keeps the group from ending up ownerless.
  defp transfer_group_tx(conversation_id, actor_id, target_id) do
    Repo.transact(fn ->
      case update_group_role(conversation_id, target_id, "owner") do
        {1, _} ->
          update_group_role(conversation_id, actor_id, "admin")
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

  ## Rooms (channel-bound conversations)
  #
  # A room IS a conversation with a `channel_id`, so all message machinery
  # (attachments + their authorization, unread, mute, realtime, permalinks)
  # applies unchanged. These are data operations called by `Eden.Channels`
  # AFTER it has authorized the actor's channel role — the web layer never
  # calls them directly. Memberships are materialized (Mattermost's
  # ChannelMembers shape): channel join/leave fans out to every room.

  @doc """
  Rooms of a channel the scoped user belongs to, ordered for the sidebar, with
  unread badges and the muted flag filled (the user's room membership IS the
  authorization — a non-member of the channel simply gets `[]`).
  """
  def list_rooms(%Scope{user: user}, channel_id) do
    rooms =
      from(c in Conversation,
        join: m in Membership,
        on: m.conversation_id == c.id and m.user_id == ^user.id,
        where: c.channel_id == ^channel_id,
        # Favorites float to the top (a per-user view over the canonical
        # position order, which still rules within each group).
        order_by: [desc: not is_nil(m.favorited_at), asc: c.position, asc: c.id],
        select: {c, not is_nil(m.favorited_at)}
      )
      |> Repo.all()

    ids = Enum.map(rooms, fn {room, _favorite} -> room.id end)
    unread = unread_counts(user, ids)
    muted = muted_conversation_ids(user, ids)

    Enum.map(rooms, fn {room, favorite} ->
      %{
        room
        | unread_count: Map.get(unread, room.id, 0),
          muted: room.id in muted,
          favorite: favorite
      }
    end)
  end

  @doc """
  Toggles the scoped user's favorite on a room (#42): favorited rooms float
  into the sidebar's Favorites block. `{:ok, :favorited | :unfavorited}` or
  `{:error, :not_found}`; the user's sessions refresh via `:folders_changed`.
  """
  def toggle_room_favorite(%Scope{user: user}, room_id) do
    with id when is_integer(id) <- safe_id(room_id),
         %Membership{} = membership <-
           Repo.get_by(Membership, conversation_id: id, user_id: user.id) do
      favorited_at = if membership.favorited_at, do: nil, else: now()

      # update_all: a no-op (not a StaleEntryError) if the membership vanished
      # concurrently (e.g. removed from the room mid-click).
      Repo.update_all(from(m in Membership, where: m.id == ^membership.id),
        set: [favorited_at: favorited_at]
      )

      broadcast_folders(user.id)
      {:ok, if(favorited_at, do: :favorited, else: :unfavorited)}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "A changeset for room forms (create / rename)."
  def change_room(room \\ %Conversation{}, attrs \\ %{}),
    do: Conversation.room_changeset(room, attrs)

  @doc """
  Resolves what following a link into a room should do (#41 access matrix),
  given the facts `%{room_member?: boolean, visibility: "open" | "private"}`:

    * `:member`    — already in the room → just open it;
    * `:open_join` — open room, not a member → auto-join, then open;
    * `:knock`     — private room, not a member → show the knock window.

  Pure and room-only. **Channel membership is orthogonal**: the caller (PR-B's
  web layer) first ensures channel membership (an idempotent join to
  `general` — channels are never closed), then acts on this room verdict. So a
  non-channel-member following an open-room link joins the channel AND the room
  (`:open_join`), and following a private-room link joins the channel then
  knocks (`:knock`).
  """
  def resolve_room_access(%{room_member?: true}), do: :member
  def resolve_room_access(%{room_member?: false, visibility: "open"}), do: :open_join
  def resolve_room_access(%{room_member?: false, visibility: "private"}), do: :knock
  # Deny-by-default: an unexpected/nil visibility (data corruption) must not
  # crash the access path nor silently grant entry — treat it as private.
  def resolve_room_access(%{room_member?: false}), do: :knock

  @doc "Fetches a room (a conversation with a channel) by id — trusted callers only."
  def get_room(room_id) do
    case Ids.normalize(room_id) do
      id when is_integer(id) ->
        Repo.one(from c in Conversation, where: c.id == ^id and not is_nil(c.channel_id))

      _ ->
        nil
    end
  end

  @doc """
  Creates a room in a channel and materializes memberships for the given user
  ids (their `last_read_at` starts now — no unread storm). `opts[:is_general]`
  marks the Town Square. Trusted caller: `Eden.Channels` authorizes the actor
  first, and now seeds only the creator (others join open rooms via link or are
  added to private ones — #41).
  """
  def create_room(channel_id, attrs, member_ids, opts \\ []) do
    Repo.transact(fn ->
      changeset =
        %Conversation{
          channel_id: channel_id,
          is_group: true,
          is_general: Keyword.get(opts, :is_general, false),
          position: next_room_position(channel_id)
        }
        |> Conversation.room_changeset(attrs)

      with {:ok, room} <- Repo.insert(changeset) do
        {_count, _} = Repo.insert_all(Membership, room_membership_entries([room.id], member_ids))
        {:ok, room}
      end
    end)
  end

  @doc "Renames a room (stale rows become `:not_found`, not a crash)."
  def update_room(%Conversation{} = room, attrs) do
    room
    |> Conversation.room_changeset(attrs)
    |> Repo.update(stale_error_field: :id)
    |> case do
      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if Keyword.has_key?(errors, :id),
          do: {:error, :not_found},
          else: {:error, changeset}

      result ->
        result
    end
  end

  @doc "Reorders a channel's rooms to match `ordered_ids` (foreign ids ignored)."
  def reorder_rooms(channel_id, ordered_ids) do
    owned =
      MapSet.new(
        Repo.all(from c in Conversation, where: c.channel_id == ^channel_id, select: c.id)
      )

    ids =
      ordered_ids
      |> Enum.map(&Ids.normalize/1)
      |> Enum.filter(&MapSet.member?(owned, &1))

    {:ok, _} =
      Repo.transact(fn ->
        ids
        |> Enum.with_index()
        |> Enum.each(fn {id, pos} ->
          Repo.update_all(from(c in Conversation, where: c.id == ^id), set: [position: pos])
        end)

        {:ok, :ok}
      end)

    :ok
  end

  @doc """
  Hard-deletes a conversation (admin room deletion): the DB cascades messages/
  memberships/attachments, and orphaned blobs are removed forward-safely —
  the same GC path as the last-member leave.
  """
  def hard_delete_conversation(conversation_id) do
    {:ok, keys} = Repo.transact(fn -> {:ok, gc_collect(conversation_id)} end)
    delete_unreferenced_blobs(keys)
    :ok
  end

  @doc """
  Materializes the user into the channel's `general` room only (#41: joining a
  channel grants Town Square; other rooms are earned per room). Idempotent.
  """
  def join_general(channel_id, user_id) do
    case general_room_id(channel_id) do
      nil -> :ok
      room_id -> join_room(room_id, user_id)
    end
  end

  @doc "Materializes the user into a single room (idempotent). Trusted caller."
  def join_room(room_id, user_id) do
    {_count, _} =
      Repo.insert_all(Membership, room_membership_entries([room_id], [user_id]),
        on_conflict: :nothing
      )

    :ok
  end

  @doc "Whether the user is a member of the room."
  def room_member?(room_id, user_id) do
    Repo.exists?(
      from m in Membership, where: m.conversation_id == ^room_id and m.user_id == ^user_id
    )
  end

  @doc "Member user ids of a room (trusted caller — e.g. the admin add-picker)."
  def room_member_ids(room_id) do
    Repo.all(from m in Membership, where: m.conversation_id == ^room_id, select: m.user_id)
  end

  @doc """
  Inserts a system message (no human sender; payload in `meta`) into a
  conversation and broadcasts it like any message. System messages don't touch
  the sort key, don't resurface 1:1s, and never count as unread (sender_id nil).
  Trusted caller (e.g. `Eden.Channels` after authorizing).
  """
  def create_system_message(conversation_id, meta) when is_map(meta) do
    # Insert through a changeset carrying the FK constraint so a conversation deleted
    # concurrently (room GC / channel delete) surfaces as `{:error, changeset}`, not a
    # raised `Ecto.ConstraintError` from a bare struct insert (#258).
    %Message{}
    |> Ecto.Changeset.change(
      conversation_id: conversation_id,
      kind: "system",
      body: "",
      meta: meta
    )
    |> Ecto.Changeset.foreign_key_constraint(:conversation_id)
    |> Repo.insert()
    |> case do
      {:ok, message} ->
        broadcast(conversation_id, {:new_message, message})
        {:ok, message}

      error ->
        error
    end
  end

  @doc """
  The pending join-request system message for `(room, requester)`, or nil — the
  dedup source for the knock flow (one outstanding request per pair).
  """
  def pending_join_request(room_id, requester_id) do
    Repo.one(
      from m in Message,
        where:
          m.conversation_id == ^room_id and m.kind == "system" and
            fragment("? ->> 'action'", m.meta) == "join_request" and
            fragment("? ->> 'status'", m.meta) == "pending" and
            fragment("(? ->> 'requester_id')::bigint", m.meta) == ^requester_id,
        limit: 1
    )
  end

  @doc "Marks a join-request system message resolved (e.g. \"accepted\") and rebroadcasts it."
  def resolve_join_request(%Message{} = message, status) do
    meta = Map.put(message.meta, "status", status)

    message
    |> Ecto.Changeset.change(meta: meta)
    |> Repo.update(stale_error_field: :id)
    |> case do
      {:ok, updated} ->
        broadcast(updated.conversation_id, {:new_message, updated})
        {:ok, updated}

      # The room (and this system message) was deleted concurrently — nothing to resolve,
      # a tagged error instead of a StaleEntryError crash (#258).
      {:error, _} ->
        {:error, :not_found}
    end
  end

  @doc "Fetches a system message by id (trusted caller; authorize via its conversation)."
  def get_system_message(message_id) do
    case Ids.normalize(message_id) do
      id when is_integer(id) ->
        Repo.one(from m in Message, where: m.id == ^id and m.kind == "system")

      _ ->
        nil
    end
  end

  defp general_room_id(channel_id) do
    Repo.one(
      from c in Conversation,
        where: c.channel_id == ^channel_id and c.is_general == true,
        select: c.id
    )
  end

  @doc """
  The room to open when the scoped user enters each channel (#81). Given a
  `%{channel_id => last_room_id | nil}` map (from `channel_memberships`), returns
  `%{channel_id => entry_room_id}`: the last room if the user is still a member of
  it (so a deleted/left/lost-access room can't strand them), otherwise the
  channel's general room. One query each for the user's joined rooms and the
  general rooms — no per-channel round-trips.
  """
  def entry_room_ids(%Scope{user: user}, last_by_channel) when is_map(last_by_channel) do
    channel_ids = Map.keys(last_by_channel)

    if channel_ids == [] do
      %{}
    else
      generals =
        Repo.all(
          from c in Conversation,
            where: c.channel_id in ^channel_ids and c.is_general == true,
            select: {c.channel_id, c.id}
        )
        |> Map.new()

      joined =
        Repo.all(
          from c in Conversation,
            join: mem in Membership,
            on: mem.conversation_id == c.id and mem.user_id == ^user.id,
            where: c.channel_id in ^channel_ids,
            select: c.id
        )
        |> MapSet.new()

      Map.new(channel_ids, fn channel_id ->
        last = last_by_channel[channel_id]
        valid? = last && MapSet.member?(joined, last)
        {channel_id, (valid? && last) || Map.get(generals, channel_id)}
      end)
    end
  end

  @doc "Removes the user's memberships from every room of the channel."
  def leave_rooms(channel_id, user_id) do
    {_count, _} =
      Repo.delete_all(
        from m in Membership,
          join: c in Conversation,
          on: c.id == m.conversation_id,
          where: c.channel_id == ^channel_id and m.user_id == ^user_id
      )

    :ok
  end

  @doc "Blob keys of every attachment in a channel's rooms (collect BEFORE the cascade delete)."
  def channel_room_blob_keys(channel_id) do
    Repo.all(
      from a in Attachment,
        join: m in Message,
        on: m.id == a.message_id,
        join: c in Conversation,
        on: c.id == m.conversation_id,
        where: c.channel_id == ^channel_id,
        select: [a.storage_key, a.thumbnail_key]
    )
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp room_membership_entries(room_ids, user_ids) do
    now = now()

    for room_id <- room_ids, user_id <- user_ids do
      %{
        conversation_id: room_id,
        user_id: user_id,
        role: "member",
        last_read_at: now,
        inserted_at: now,
        updated_at: now
      }
    end
  end

  defp next_room_position(channel_id) do
    Repo.one(
      from c in Conversation,
        where: c.channel_id == ^channel_id,
        select: coalesce(max(c.position), -1)
    ) + 1
  end

  defp room?(conversation_id) do
    Repo.exists?(
      from c in Conversation, where: c.id == ^conversation_id and not is_nil(c.channel_id)
    )
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
      # Thread replies never count as unread (consistent with unread_counts/2
      # and the channel aggregate) — a DM can carry threads too since #31.
      where: is_nil(msg.root_id),
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
  # Trigram word-similarity threshold for fuzzy message search (#56). Set
  # transaction-locally per fuzzy query (see run_search/2) so matching never
  # depends on the server's unpinned default (0.6, instance/provider-tunable).
  # Measured word_similarity: real single-char typos cluster at ~0.61–0.70
  # ("rendezous"↔"rendezvous" 0.615, "докуметация"↔"документацию" 0.53), while
  # unrelated prefix-sharing words sit lower ("помощь"↔"помещение" 0.43). 0.5 sits
  # in that gap — it catches typos the strict 0.6 default would miss by a hair,
  # yet rejects the 0.43 noise that 0.4 would let through.
  @fuzzy_threshold 0.5

  @doc "Shortest query `search/2` will run (shorter ones return empty results)."
  def search_min_chars, do: @search_min_chars

  @doc """
  Searches the scoped user's chats: conversations by participant display name /
  username (or group title) and messages by body. Everything is scoped through
  the user's memberships — nothing outside their conversations can match.

  Message bodies use a **trigram-indexed** match (#56): indexed `ILIKE '%term%'`
  substring plus typo-tolerant word-similarity for longer, metacharacter-free
  terms (see `body_match/1`). Conversation names/titles stay plain `ILIKE` (a
  small set). Returns `%{conversations: [...], messages: [...]}` (each capped at
  #{@search_limit}); a blank or single-character query returns empty lists.
  """
  def search(%Scope{user: user}, query) do
    term = query |> to_string() |> String.trim()

    if String.length(term) < @search_min_chars do
      %{conversations: [], messages: []}
    else
      %{
        conversations: search_conversations(user, like_pattern(term)),
        messages: search_messages(user, term)
      }
    end
  end

  @doc """
  Searches message bodies in the corporate layer (#43), scoped to
  `{:channel, channel_id}` (across that channel's rooms the user is a member
  of) or `{:room, room_id}` (one room). Same guards as `search/2` (min
  #{@search_min_chars} chars, the trigram-indexed body match, capped at
  #{@search_limit}); tombstoned/per-user-hidden messages never match. Replies are
  EXCLUDED (`is_nil(root_id)`, #189) — the main-stream search stays in the main
  stream; thread replies are searched separately via `search_thread/3`. Results
  preload sender + conversation (for the room-name breadcrumb).
  """
  def search_rooms(%Scope{user: user}, search_scope, query) do
    term = query |> to_string() |> String.trim()

    if String.length(term) < @search_min_chars do
      []
    else
      room_search_base(user, term)
      |> room_search_scope(search_scope)
      |> order_by(^search_order(term))
      |> run_search(term)
    end
  end

  defp room_search_base(user, term) do
    from(m in Message,
      join: mem in Membership,
      # Room memberships are delete-based today (leave_rooms hard-deletes), so
      # left_at is always nil here — the filter keeps parity with
      # search_messages/2 and stays correct should rooms ever go soft-leave.
      on:
        mem.conversation_id == m.conversation_id and mem.user_id == ^user.id and
          is_nil(mem.left_at),
      join: c in Conversation,
      on: c.id == m.conversation_id,
      where: not is_nil(c.channel_id),
      # Only real messages — join-request system rows (kind "system") carry an
      # empty body and a meta payload, never something a user means to find.
      where: m.kind == "user",
      # Main-stream only (#189): thread replies (root_id set) are searched separately
      # via search_thread/3 — they don't belong in the room's main-stream results.
      where: is_nil(m.root_id),
      limit: @search_limit,
      preload: [:sender, :conversation]
    )
    # Tombstone + delete-for-me visibility (#233): the single authority, shared
    # with the main stream. Added before room_search_scope so its [m, mem, c]
    # positional bindings are unaffected (the :deletion join is named).
    |> exclude_invisible(user)
    |> where(^body_match(term))
  end

  @doc """
  Searches the replies of one thread (#189), scoped to `root_id` — the counterpart
  to `search_rooms/3`'s now main-stream-only search. Same guards (min
  #{@search_min_chars} chars, the trigram body match, capped at #{@search_limit});
  tombstoned/per-user-hidden replies never match. Only the thread's replies are
  searched (the root is always pinned at the top of the panel). Scoped through the
  user's membership of the root's conversation, so a foreign/unknown root yields
  nothing. Preloads sender for the result row.
  """
  def search_thread(%Scope{user: user}, root_id, query) do
    term = query |> to_string() |> String.trim()

    with id when is_integer(id) <- Ids.normalize(root_id),
         true <- String.length(term) >= @search_min_chars do
      thread_search_base(user, id, term)
      |> order_by(^search_order(term))
      |> run_search(term)
    else
      _ -> []
    end
  end

  defp thread_search_base(user, root_id, term) do
    from(m in Message,
      join: mem in Membership,
      on:
        mem.conversation_id == m.conversation_id and mem.user_id == ^user.id and
          is_nil(mem.left_at),
      where: m.root_id == ^root_id,
      where: m.kind == "user",
      limit: @search_limit,
      preload: [:sender]
    )
    # Tombstone + delete-for-me visibility (#233), shared with the main stream.
    |> exclude_invisible(user)
    |> where(^body_match(term))
  end

  defp room_search_scope(query, {:channel, channel_id}) do
    case Ids.normalize(channel_id) do
      id when is_integer(id) -> where(query, [m, mem, c], c.channel_id == ^id)
      _ -> where(query, [m], false)
    end
  end

  defp room_search_scope(query, {:room, room_id}) do
    case Ids.normalize(room_id) do
      id when is_integer(id) -> where(query, [m], m.conversation_id == ^id)
      _ -> where(query, [m], false)
    end
  end

  # %, _ and \ are LIKE metacharacters; escape them so they match literally.
  defp escape_like(term), do: String.replace(term, ~r/[\\%_]/, fn ch -> "\\" <> ch end)

  defp search_conversations(user, pattern) do
    # No SQL limit: DISTINCT ON orders by c.id, so a limit there would cap by
    # conversation age, dropping the most recent matches. A user belongs to a
    # few dozen conversations at most — sort by recency in memory, then cap.
    from(c in Conversation,
      join: my in Membership,
      on: my.conversation_id == c.id and my.user_id == ^user.id and is_nil(my.left_at),
      join: m in Membership,
      on: m.conversation_id == c.id,
      join: u in User,
      on: u.id == m.user_id,
      # Channel rooms are excluded until search learns to present and route
      # them (#32) — a room surfacing as a "chat" would deep-link wrongly.
      where: is_nil(c.channel_id),
      where:
        ilike(c.title, ^pattern) or
          (u.id != ^user.id and (ilike(u.display_name, ^pattern) or ilike(u.username, ^pattern))),
      distinct: c.id,
      preload: [memberships: :user]
    )
    |> Repo.all()
    |> Enum.sort_by(&(&1.last_message_at || ~U[1970-01-01 00:00:00Z]), {:desc, DateTime})
    |> Enum.take(@search_limit)
  end

  defp search_messages(user, term) do
    from(m in Message,
      join: mem in Membership,
      on:
        mem.conversation_id == m.conversation_id and mem.user_id == ^user.id and
          is_nil(mem.left_at),
      join: c in Conversation,
      on: c.id == m.conversation_id,
      # Room messages join search with #32 (need channel-aware presentation).
      where: is_nil(c.channel_id),
      limit: @search_limit,
      preload: [:sender, conversation: [memberships: :user]]
    )
    # Tombstone + delete-for-me visibility (#233), shared with the main stream.
    |> exclude_invisible(user)
    |> where(^body_match(term))
    |> order_by(^search_order(term))
    |> run_search(term)
  end

  # The message-body match, shared by DM (#12) and room (#43) search and served by
  # the `messages_body_trgm_idx` GIN trigram index (#56):
  #
  #   * `ILIKE '%term%'` — exact substring (the index serves it for 3+ char terms;
  #     a 2-char term, the allowed minimum, has no full trigram and scans),
  #     escaped so `%`/`_` match literally.
  #   * `term <% body` — trigram word-similarity, for typo tolerance. Also a
  #     trigram-index operator, so the OR stays index-served (a BitmapOr of two
  #     index scans, not a sequential scan). Its threshold is pinned per query in
  #     run_search/2.
  #
  # Fuzzy only kicks in for word-like terms of a useful length: short or
  # metacharacter-bearing terms stay pure substring, so literal `%`/`_` searches
  # keep their exact semantics and tiny terms don't drag in noise.
  defp body_match(term) do
    pattern = like_pattern(term)

    if fuzzy_term?(term) do
      dynamic([m], ilike(m.body, ^pattern) or fragment("? <% ?", ^term, m.body))
    else
      dynamic([m], ilike(m.body, ^pattern))
    end
  end

  # Closest match first for a typo search (an exact substring scores ~1.0, so it
  # still floats to the top); plain recency for exact-substring searches, where a
  # similarity sort would be meaningless.
  defp search_order(term) do
    if fuzzy_term?(term) do
      [
        desc: dynamic([m], fragment("word_similarity(?, ?)", ^term, m.body)),
        desc: dynamic([m], m.id)
      ]
    else
      [desc: dynamic([m], m.id)]
    end
  end

  # Runs a message-search query. Fuzzy queries pin the trigram word-similarity
  # threshold transaction-locally (via set_config/3, parameterized — no SQL
  # interpolation) so matching never depends on the server's unpinned default.
  # Non-fuzzy queries skip the transaction entirely.
  defp run_search(query, term) do
    if fuzzy_term?(term) do
      {:ok, rows} =
        Repo.transaction(fn ->
          Repo.query!(
            "SELECT set_config('pg_trgm.word_similarity_threshold', $1, true)",
            [to_string(@fuzzy_threshold)]
          )

          Repo.all(query)
        end)

      rows
    else
      Repo.all(query)
    end
  end

  defp fuzzy_term?(term),
    do: String.length(term) >= 4 and not String.contains?(term, ["%", "_", "\\"])

  # The escaped `%term%` LIKE pattern, shared by message + conversation search.
  defp like_pattern(term), do: "%" <> escape_like(term) <> "%"

  @doc """
  Toggles a conversation's membership in one of the scoped user's folders. Both
  the folder (must be the user's) and the conversation (must be a member) are
  authorized. Returns `{:ok, :added | :removed}` or `{:error, :not_found}`.
  """
  def toggle_conversation_folder(%Scope{user: user} = scope, conversation_id, folder_id) do
    with cid when is_integer(cid) <- safe_id(conversation_id),
         true <- member?(scope, cid),
         # Rooms are not sidebar conversations — they can't enter folders (the
         # UI never offers it; this guards the context so a room's unread can't
         # leak into a folder badge).
         false <- room?(cid),
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
    if has_access?(scope, conversation_id) do
      limit = Keyword.get(opts, :limit, @default_page)

      messages =
        visible_messages(user, conversation_id)
        |> before_cursor(opts[:before])
        |> order_by([m], desc: m.id)
        |> limit(^limit)
        |> preload(^@message_preloads)
        |> Repo.all()
        |> Enum.reverse()

      {:ok, messages}
    else
      {:error, :not_found}
    end
  end

  @doc """
  Loads a window of main-stream messages that **includes** `anchor_id`, for a
  "jump to message" (permalink / jump-to-root). The default `list_messages/3` only
  loads the newest page, so a target older than that page is never rendered and the
  client can't scroll to it (the symptom: jump/highlight works on small chats but
  fails on long ones). This anchors the window so the target is always present.

  The window is newest-anchored — it loads every message from the anchor down to the
  latest (so the stream bottom stays the real latest and live-update keeps working),
  with a floor of `#{@default_page}` rows for context. Only when the anchor sits more
  than `#{@jump_window}` messages above the latest does it fall back to an
  anchor-anchored window (`#{@jump_window}` rows starting at the anchor) to bound the
  render; in that rare case the stream bottom isn't the latest.

  Returns `{:ok, messages, has_more?}` where `has_more?` says whether older messages
  exist before the window (drives the "load older" affordance). `{:error, :not_found}`
  if the user is not a member.
  """
  def list_messages_around(%Scope{user: user} = scope, conversation_id, anchor_id) do
    # safe_id first: anchor_id can be a raw URL/event string ("abc"), which would
    # otherwise raise Ecto.Query.CastError on the m.id comparisons below.
    with id when is_integer(id) <- safe_id(anchor_id),
         true <- has_access?(scope, conversation_id) do
      base = visible_messages(user, conversation_id)
      at_or_after = base |> where([m], m.id >= ^id) |> Repo.aggregate(:count)
      limit = at_or_after |> max(@default_page) |> min(@jump_window)

      query =
        if at_or_after <= @jump_window do
          # Common case: the anchor is within @jump_window of the latest. Load the
          # `limit` newest rows (which include the anchor) so the bottom is the latest.
          base |> order_by([m], desc: m.id) |> limit(^limit)
        else
          # Deep jump: load @jump_window rows starting AT the anchor instead, so the
          # anchor is guaranteed present even though the bottom won't be the latest.
          base
          |> where([m], m.id >= ^id)
          |> order_by([m], asc: m.id)
          |> limit(^@jump_window)
        end

      messages = query |> preload(^@message_preloads) |> Repo.all()

      # Newest-anchored loads come back desc — normalize to oldest-first like list_messages/3.
      messages = if at_or_after <= @jump_window, do: Enum.reverse(messages), else: messages

      has_more =
        case messages do
          [oldest | _] -> Repo.exists?(where(base, [m], m.id < ^oldest.id))
          [] -> false
        end

      {:ok, messages, has_more}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  True when `message_id` is a live, visible main-stream message of `conversation_id`
  for the scoped user (exists, not a thread reply, not hard-deleted, not hidden by
  this user). Used to decide whether a "jump to message" should load a window around
  it — a deleted/foreign id falls through to the normal "message unavailable" path.
  """
  def main_stream_message?(%Scope{user: user} = scope, conversation_id, message_id) do
    # safe_id first: message_id can be a raw URL/event string; an un-cast "abc" in the
    # m.id comparison would raise Ecto.Query.CastError and crash the LiveView.
    case safe_id(message_id) do
      id when is_integer(id) ->
        has_access?(scope, conversation_id) and
          Repo.exists?(visible_messages(user, conversation_id) |> where([m], m.id == ^id))

      _ ->
        false
    end
  end

  @doc """
  The visible rows of one file group (TG-attachments), oldest→newest, preloaded — used to re-fuse
  the merged bubble after a member is deleted/hidden. Scoped like the main stream (drops tombstones
  and the user's hidden rows via `visible_messages`), so a deleted member falls out and the
  survivors reshape. `nil`/non-binary group_id returns [].
  """
  def list_group_messages(%Scope{user: user}, conversation_id, group_id)
      when is_binary(group_id) do
    visible_messages(user, conversation_id)
    |> where([m], m.group_id == ^group_id)
    |> order_by([m], asc: m.id)
    |> preload(^@message_preloads)
    |> Repo.all()
  end

  def list_group_messages(_scope, _conversation_id, _group_id), do: []

  @doc """
  Of `client_ids`, the ones that ALREADY have a message from the scoped user in `conversation_id`
  (TG-attachments resume, phase E) — so a reloaded send skips re-uploading what already landed.
  Backs the idempotent resume alongside the `(sender_id, client_id)` unique index.
  """
  def sent_client_ids(%Scope{user: user}, conversation_id, client_ids) when is_list(client_ids) do
    cids = Enum.filter(client_ids, &is_binary/1)

    if cids == [] do
      []
    else
      Repo.all(
        from(m in Message,
          where:
            m.conversation_id == ^conversation_id and m.sender_id == ^user.id and
              m.client_id in ^cids,
          select: m.client_id
        )
      )
    end
  end

  @doc """
  True when a `group_id` is safe for the scoped user to (re)use in `conversation_id` — i.e. no
  message in that group was sent by anyone else (phase E resume ownership check, so a client can't
  smuggle a resumed row into another user's group). An empty/all-mine group is owned.
  """
  def group_owned_by?(%Scope{user: user}, conversation_id, group_id) when is_binary(group_id) do
    not Repo.exists?(
      from(m in Message,
        where:
          m.conversation_id == ^conversation_id and m.group_id == ^group_id and
            m.sender_id != ^user.id
      )
    )
  end

  def group_owned_by?(_scope, _conversation_id, _group_id), do: false

  # Shared base query for a conversation's main-stream messages visible to `user`:
  # excludes thread replies, plus the per-user invisibility centralized in
  # exclude_invisible/2.
  defp visible_messages(user, conversation_id) do
    Message
    |> where([m], m.conversation_id == ^conversation_id)
    # Replies live only inside their thread panel, never the main stream.
    |> where([m], is_nil(m.root_id))
    |> exclude_invisible(user)
  end

  # The single authority for per-user message *content* visibility (#233): drops
  # "deleted for everyone" tombstones and rows this user hid (delete-for-me).
  # Every main-stream listing / search query pipes through this so a new query
  # can't silently forget a filter and surface a hidden/deleted message. Uses a
  # named binding (`:deletion`) so it composes onto any query with `Message` as
  # the first binding, regardless of what else is joined. Membership /
  # authorization scoping stays the caller's job — it legitimately varies
  # (per-conversation vs cross-conversation search), so it isn't folded in here.
  defp exclude_invisible(query, user) do
    query
    |> where([m], is_nil(m.deleted_at))
    |> join(:left, [m], d in MessageDeletion,
      as: :deletion,
      on: d.message_id == m.id and d.user_id == ^user.id
    )
    |> where([deletion: d], is_nil(d.id))
  end

  @doc """
  Lists a conversation's attachments of one `kind` (`image | video | file | audio`) for the
  per-dialog media gallery (#136), newest first, paginated by attachment id.

  Honors the same visibility rules as `list_messages/3`: membership-gated, with thread
  replies and deleted / per-user-hidden messages excluded. `opts[:before]` is an attachment-id
  cursor (rows strictly older than it); `opts[:limit]` sizes the page (default #{@default_page}).
  Returns `{:error, :not_found}` when the scoped user isn't a member.
  """
  def list_conversation_media(%Scope{user: user} = scope, conversation_id, kind, opts \\ [])
      when kind in ~w(image video file audio) do
    if has_access?(scope, conversation_id) do
      limit = Keyword.get(opts, :limit, @default_page)

      attachments =
        Attachment
        |> join(:inner, [a], m in Message, on: m.id == a.message_id)
        |> where([a, m], m.conversation_id == ^conversation_id)
        # Mirror list_messages visibility: no thread replies, no tombstones.
        |> where([_a, m], is_nil(m.root_id) and is_nil(m.deleted_at))
        |> join(:left, [a, m], d in MessageDeletion,
          on: d.message_id == m.id and d.user_id == ^user.id
        )
        |> where([_a, _m, d], is_nil(d.id))
        |> where([a], a.kind == ^kind)
        |> media_before(opts[:before])
        # Attachment ids are monotonic with message creation, so this is newest-media-first
        # and keeps the cursor stable even within an album.
        |> order_by([a], desc: a.id)
        |> limit(^limit)
        |> Repo.all()

      {:ok, attachments}
    else
      {:error, :not_found}
    end
  end

  defp media_before(query, nil), do: query
  defp media_before(query, before_id), do: where(query, [a], a.id < ^before_id)

  @doc """
  Posts a message from the scoped user. `sender_id`/`conversation_id` are set
  programmatically (never cast). Updates the conversation sort key and broadcasts
  `{:new_message, message}`. `{:error, :not_found}` if not a member.
  """
  def create_message(%Scope{user: user} = scope, conversation_id, attrs) do
    if has_access?(scope, conversation_id) do
      reply_to_id =
        valid_reply_to_id(attrs["reply_to_id"] || attrs[:reply_to_id], conversation_id, user.id)

      %Message{conversation_id: conversation_id, sender_id: user.id, reply_to_id: reply_to_id}
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

  # A quote-reply target (#71): keep `raw` only if it references a message that is
  # in THIS conversation, not tombstoned, and not hidden-for-this-user — otherwise
  # drop it (the quoted message may have been deleted between compose and send, or
  # the id is forged / from another conversation). Set programmatically, so a
  # forged reply_to_id never crosses a conversation boundary.
  defp valid_reply_to_id(raw, conversation_id, user_id) do
    with id when is_integer(id) <- safe_id(raw),
         true <- reply_target_visible?(id, conversation_id, user_id) do
      id
    else
      _ -> nil
    end
  end

  defp reply_target_visible?(id, conversation_id, user_id) do
    Repo.exists?(
      from m in Message,
        left_join: d in MessageDeletion,
        on: d.message_id == m.id and d.user_id == ^user_id,
        where:
          m.id == ^id and m.conversation_id == ^conversation_id and is_nil(m.deleted_at) and
            is_nil(d.id)
    )
  end

  @doc """
  Loads a message the scoped user may quote — a member of its conversation, and
  the message is visible to them (not tombstoned, not hidden-for-them, same as
  the send-path `valid_reply_to_id/3`) — preloaded with its sender + attachments
  for the quote-reply composer tray (#71). Returns the message or `nil`.
  """
  def get_message(%Scope{user: user} = scope, message_id) do
    with {:ok, message} <- fetch_message(scope, message_id),
         true <- reply_target_visible?(message.id, message.conversation_id, user.id) do
      Repo.preload(message, [:sender, :attachments])
    else
      _ -> nil
    end
  end

  @doc """
  Fetches the given messages the scoped user can see (membership-scoped, not tombstoned, not
  hidden-for-me), ordered oldest-first — for multi-select actions (copy/forward/delete). Unknown
  or unauthorized ids are simply absent from the result. `sender`/`attachments` preloaded.
  """
  def get_messages(%Scope{user: user}, ids) when is_list(ids) do
    ids = ids |> Enum.map(&safe_id/1) |> Enum.filter(&is_integer/1)

    from(m in Message,
      join: mem in Membership,
      on: mem.conversation_id == m.conversation_id and mem.user_id == ^user.id,
      left_join: d in MessageDeletion,
      on: d.message_id == m.id and d.user_id == ^user.id,
      where: m.id in ^ids and is_nil(m.deleted_at) and is_nil(d.id),
      order_by: [asc: m.id],
      preload: [:sender, :attachments]
    )
    |> Repo.all()
  end

  @doc """
  Posts a message carrying one attachment — a thin wrapper over
  `create_album_message/4` for a single source (kept for callers/tests that send
  one file). `source` is a map with `:path` and optional `:filename`, `:body`,
  `:client_id`.
  """
  def create_attachment_message(%Scope{} = scope, conversation_id, source) do
    create_album_message(scope, conversation_id, [Map.delete(source, :body)], %{
      body: Map.get(source, :body, ""),
      client_id: source[:client_id]
    })
  end

  @doc """
  Sends a composer selection (#58): photos/videos group into ONE **album**
  message; every non-media file becomes **its own** message (a file never joins
  an album — #58 rule). The caption (`opts.body`) rides the album, or — when the
  selection is files only — the first file. Returns `{:ok, [message]}` (send
  order) or `{:error, reason}` — every source is classified and size-checked
  **up front**, so a bad/oversized file fails the whole batch before anything is
  stored or sent (no misleading partial send). `sources` are maps with `:path`
  and optional `:filename`.
  """
  def create_attachments(%Scope{} = scope, conversation_id, sources, opts \\ %{}) do
    # Tag every source with the per-send "Original" preference (#122) so it rides down to
    # store_attachment_blob without threading opts through each layer; default = compress.
    # `as_file` (#122) is the "Send as file" choice: keep the image uncompressed and render
    # it as a downloadable document instead of an inline photo.
    sources =
      Enum.map(sources, fn source ->
        source
        |> Map.put(:original, opts[:original] == true)
        |> Map.put(:as_file, opts[:as_file] == true)
      end)

    with true <- has_access?(scope, conversation_id),
         {:ok, classified} <- preflight(sources) do
      {media, files} =
        Enum.split_with(classified, fn {_source, kind} -> kind in ~w(image video) end)

      steps =
        attachment_steps(
          sources_of(media),
          sources_of(files),
          Map.get(opts, :body, ""),
          opts[:client_id],
          opts[:group_id]
        )

      send_attachment_steps(scope, conversation_id, steps, opts[:reply_to_id], opts[:root_id])
    else
      false -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp sources_of(classified), do: Enum.map(classified, &elem(&1, 0))

  # Classify + size-check every source before any storage/DB write, so a bad
  # file fails the batch atomically (the common failure modes — too-large, bad
  # type — never produce a half-sent album). Server-side magic-byte
  # classification; the client content-type is advisory. The kind is reused to
  # split media (album) from files; the actual store re-classifies (a cheap
  # header read) since create_album_message/4 is also a standalone entry point.
  defp preflight(sources) do
    sources
    |> Enum.reduce_while({:ok, []}, fn source, {:ok, acc} ->
      with {:ok, kind, _type, _ext} <- classify(source.path, source[:filename]),
           {:ok, _bytes} <- check_size(source.path, kind) do
        {:cont, {:ok, [{source, kind} | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  # Plan the messages: one album for media (caption attached), one message per
  # file. With files only, the caption rides the first file; the rest are plain.
  # Each step carries its own optimistic client_id (#149): the media album gets
  # the album-level id (`album_cid`), each file message its OWN id — minted per
  # file and carried on the source map by upload ref (`:client_id`) — so the
  # in-stream optimistic card swaps per file, not just for the first message.
  #
  # A step is `{sources, body, client_id, group_id}`. `group_id` (TG-attachments) is
  # stamped on FILE steps only (photo albums stay one-message-N-attachments, so their
  # steps carry `nil`), tying the send's file rows into one visual bubble downstream.
  defp attachment_steps([], [], _body, _album_cid, _group_id), do: []

  defp attachment_steps([], [first | rest], body, _album_cid, group_id),
    do: [
      {[first], body, source_cid(first), group_id}
      | Enum.map(rest, &{[&1], "", source_cid(&1), group_id})
    ]

  # Media past @max_album_entries is split into a SEQUENCE of albums (#193, Telegram-style):
  # the caption + the optimistic client_id (and the reply, via send_attachment_steps) ride the
  # FIRST album; the rest are plain and stream in. `List.wrap` keeps the single-album case
  # (the common one) identical, so the client protocol is unchanged.
  defp attachment_steps(media, files, body, album_cid, group_id) do
    cids = List.wrap(album_cid)

    album_steps =
      media
      |> Enum.chunk_every(@max_album_entries)
      |> Enum.with_index()
      |> Enum.map(fn {chunk, i} ->
        {chunk, if(i == 0, do: body, else: ""), Enum.at(cids, i), nil}
      end)

    album_steps ++ Enum.map(files, &{[&1], "", source_cid(&1), group_id})
  end

  defp source_cid(%{client_id: cid}), do: cid
  defp source_cid(_source), do: nil

  # A quote-reply with attachments rides only the FIRST sent message (the album,
  # or the first file); the rest are plain. The client_id is per-step (#149).
  #
  # NOTE on atomicity: each step commits in its OWN create_album_message transaction, so a
  # failure on the N-th step does NOT roll back steps 1..N-1 — those are already persisted and
  # broadcast. This is a deliberate trade (same as a multi-file send): preflight has already
  # rejected the common failures (bad type / too large) atomically up front, so only an
  # infrastructure error (storage/DB) reaches here, and the committed albums' real rows still
  # swap their optimistic twins. If partial-success ever needs surfacing, return the sent
  # messages alongside the error instead of a bare {:error, reason}.
  defp send_attachment_steps(scope, conversation_id, steps, reply_to_id, root_id) do
    steps
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {{srcs, body, cid, group_id}, i}, {:ok, acc} ->
      # reply_to belongs to the first message (the album with the caption, or the
      # first file), not the trailing per-file messages.
      reply = if i == 0, do: reply_to_id, else: nil
      step_opts = %{body: body, reply_to_id: reply, client_id: cid, group_id: group_id}

      # A root_id (TG-attachments in room threads, phase F) makes each step a thread REPLY under the
      # root — files still group by group_id, the album is one reply — instead of a main-stream message.
      result =
        if root_id,
          do: create_album_reply(scope, root_id, srcs, step_opts),
          else: create_album_message(scope, conversation_id, srcs, step_opts)

      case result do
        {:ok, message} -> {:cont, {:ok, [message | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, messages} -> {:ok, Enum.reverse(messages)}
      error -> error
    end
  end

  @doc """
  Posts a message with an ordered **album** of attachments (#58). Each source's
  `kind` (image | video | file | audio) is decided by its magic bytes — never the
  client content-type; arbitrary files become `file` with a safe inferred type
  and sanitized name. Every blob is stored via the storage adapter and the
  message + all attachment rows are inserted atomically.

  `sources` is a non-empty list of maps with `:path` (a local temp file) and
  optional `:filename` (capped at #{@max_album_entries}). `opts` carries the
  shared `:body` caption and `:client_id`. If any source fails to classify, is
  too large, or fails to store, nothing is persisted and every blob stored so
  far is rolled back.

  Returns `{:ok, message}` (attachments preloaded, ordered) or `{:error, reason}`
  where reason is `:not_found | :empty | :too_large | :too_many | a changeset`.
  """
  def create_album_message(%Scope{user: user} = scope, conversation_id, sources, opts \\ %{})
      when is_list(sources) do
    with true <- has_access?(scope, conversation_id),
         :ok <- ensure_album_size(sources),
         {:ok, prepared} <- prepare_album(sources) do
      persist_album(user, conversation_id, prepared, opts)
    else
      false -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Like `create_reply/3`, but the reply carries an album of attachments (#104).
  Same thread authorization as `create_reply` (the root must be a non-deleted,
  threaded root the scoped user can see); the album is stored and delivered as a
  thread reply via `deliver_reply`. `sources` mirror `create_album_message`.
  """
  def create_album_reply(%Scope{user: user} = scope, root_id, sources, opts \\ %{})
      when is_list(sources) do
    with {:ok, root} <- fetch_message(scope, root_id),
         :ok <- ensure_not_deleted(root),
         :ok <- ensure_root(root),
         :ok <- ensure_threaded(root.conversation_id),
         :ok <- ensure_album_size(sources),
         {:ok, prepared} <- prepare_album(sources) do
      persist_album(user, root.conversation_id, prepared, Map.put(opts, :root, root))
    end
  end

  defp ensure_album_size([]), do: {:error, :empty}

  defp ensure_album_size(sources) when length(sources) > @max_album_entries,
    do: {:error, :too_many}

  defp ensure_album_size(_sources), do: :ok

  # Classify + size-check + store every source, tagging each with its album
  # position. On the first failure, roll back the blobs stored so far so a
  # partial album never leaks orphaned blobs.
  defp prepare_album(sources) do
    sources
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {source, idx}, {:ok, done} ->
      case prepare_attachment(source, idx) do
        {:ok, attrs} ->
          {:cont, {:ok, [attrs | done]}}

        {:error, reason} ->
          Enum.each(done, &Storage.delete(&1.storage_key))
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, done} -> {:ok, Enum.reverse(done)}
      error -> error
    end
  end

  defp prepare_attachment(source, position) do
    with {:ok, kind, content_type, ext} <- classify(source.path, source[:filename]),
         {:ok, orig_size} <- check_size(source.path, kind),
         {:ok, blob} <- store_attachment_blob(source, kind, content_type, ext, orig_size) do
      {:ok, Map.put(blob, :position, position)}
    end
  end

  # "Send as file" (#122): keep the photo uncompressed (original bytes) and flag it so it
  # renders as a downloadable document with a thumbnail instead of an inline photo. kind
  # stays "image", so the worker still generates the preview thumbnail. Takes precedence
  # over the compress/HEIC/GIF clauses — the sender explicitly asked for the original.
  defp store_attachment_blob(%{as_file: true} = source, "image", content_type, ext, orig_size) do
    with {:ok, blob} <-
           store_attachment_blob(source, "image", content_type, ext, orig_size, :as_is) do
      {:ok, Map.put(blob, :as_file, true)}
    end
  end

  # HEIC/HEIF images (#123): transcode the original to JPEG and store THAT — HEIC
  # shares the mp4 `ftyp` magic and isn't web-renderable outside Safari, so we never
  # keep the original. If the bundled libvips can't read it (no libheif / corrupt),
  # fall back to storing it as an image (kind already `image` — never the broken
  # video the classifier used to produce); the worker just won't thumbnail it.
  defp store_attachment_blob(source, "image", "image/heic", _ext, orig_size) do
    case heic_to_jpeg(source.path) do
      {:ok, jpeg, width, height} ->
        key = Storage.build_key("attachments", "jpg")

        with :ok <- Storage.put_binary(key, jpeg) do
          {:ok,
           %{
             kind: "image",
             storage_key: key,
             content_type: "image/jpeg",
             byte_size: byte_size(jpeg),
             filename: jpeg_filename(source[:filename]),
             width: width,
             height: height
           }}
        end

      {:error, _} ->
        store_attachment_blob(source, "image", "image/heic", "heic", orig_size, :as_is)
    end
  end

  # GIFs are stored as-is (#122): compressing would flatten an animated GIF to a single
  # static JPEG frame, losing the animation.
  defp store_attachment_blob(source, "image", "image/gif", ext, orig_size) do
    store_attachment_blob(source, "image", "image/gif", ext, orig_size, :as_is)
  end

  # Photos (#122): compress for weight (vix → ≤1600px JPEG q82, metadata stripped) and store
  # THAT, unless the sender chose Original. compress_photo returns `:keep` when the re-encode
  # wouldn't meaningfully shrink (or on any libvips hiccup) → store the original as-is, so a
  # send never breaks over compression and already-small images aren't bloated.
  defp store_attachment_blob(%{original: true} = source, "image", content_type, ext, orig_size) do
    store_attachment_blob(source, "image", content_type, ext, orig_size, :as_is)
  end

  defp store_attachment_blob(source, "image", content_type, ext, orig_size) do
    case Images.compress_photo(source.path, orig_size) do
      {:ok, jpeg, width, height} ->
        key = Storage.build_key("attachments", "jpg")

        with :ok <- Storage.put_binary(key, jpeg) do
          {:ok,
           %{
             kind: "image",
             storage_key: key,
             content_type: "image/jpeg",
             byte_size: byte_size(jpeg),
             filename: jpeg_filename(source[:filename]),
             width: width,
             height: height
           }}
        end

      :keep ->
        store_attachment_blob(source, "image", content_type, ext, orig_size, :as_is)
    end
  end

  defp store_attachment_blob(source, kind, content_type, ext, orig_size) do
    store_attachment_blob(source, kind, content_type, ext, orig_size, :as_is)
  end

  defp store_attachment_blob(source, kind, content_type, ext, orig_size, :as_is) do
    key = Storage.build_key("attachments", ext)

    with :ok <- Storage.put(key, source.path) do
      {width, height} = media_dimensions(kind, source)

      {:ok,
       %{
         kind: kind,
         storage_key: key,
         content_type: content_type,
         byte_size: orig_size,
         filename: source[:filename],
         width: width,
         height: height
       }}
    end
  end

  defp jpeg_filename(nil), do: nil
  defp jpeg_filename(name), do: Path.rootname(name) <> ".jpg"

  defp persist_album(user, conversation_id, prepared, opts) do
    message_attrs = %{"body" => Map.get(opts, :body, ""), "client_id" => opts[:client_id]}
    reply_to_id = valid_reply_to_id(opts[:reply_to_id], conversation_id, user.id)
    # opts[:root] is a %Message{} for a thread-reply album (#104); nil for a
    # top-level album. It decides the delivery path (thread vs main stream).
    root = opts[:root]

    case insert_album_message(
           user,
           conversation_id,
           message_attrs,
           prepared,
           reply_to_id,
           root && root.id,
           opts[:group_id]
         ) do
      {:ok, message} ->
        message =
          if root, do: deliver_reply(root, message), else: deliver(conversation_id, message)

        for attachment <- message.attachments,
            needs_media_processing?(attachment.kind),
            do: enqueue_thumbnail(attachment)

        {:ok, message}

      {:error, changeset} ->
        # The blobs we just stored are unneeded whether this is a hard error or a
        # duplicate resend (the original already owns its own attachments).
        Enum.each(prepared, &Storage.delete(&1.storage_key))
        resolve_duplicate(changeset, user.id)
    end
  end

  # Original pixel dimensions for an image — read from the header, LAZILY (no full
  # decode), so it's cheap enough to stay on the request path and still reserve the
  # box (#117) with zero decode.
  defp media_dimensions("image", %{path: path}), do: image_dimensions(path)

  # Video dimensions come from the CLIENT (the optimistic tile already measured
  # `videoWidth/Height` for free) so the just-sent video row reserves its box (#117)
  # WITHOUT a synchronous ffprobe subprocess on the LiveView process (#231). Purely a
  # layout hint; the media worker re-probes and stays authoritative. No hint (a legacy
  # or `create_attachment_message` path) → {nil, nil}, and the worker fills them — the
  # same graceful fallback as before, minus the blocking subprocess at create.
  defp media_dimensions("video", source), do: client_dims(source)

  defp media_dimensions(_kind, _source), do: {nil, nil}

  defp client_dims(%{width: w, height: h})
       when is_integer(w) and w > 0 and is_integer(h) and h > 0,
       do: {w, h}

  defp client_dims(_source), do: {nil, nil}

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
        # group_id rides along so the web layer can re-fuse a merged file bubble (TG-attachments).
        {:message_hidden, message.conversation_id, message.id, message.group_id}
      )

      :ok
    end
  end

  @doc """
  Edits the author's own message text/caption (#164) — author only (mirrors
  `delete_message_for_both/2`). No edit window (Telegram-style). A deleted (tombstone)
  or system message can't be edited; a text-only message can't be blanked (delete it
  instead), but a media caption may. Stamps `edited_at` and broadcasts
  `{:message_edited, message}`. A no-op (unchanged body) returns `{:ok, message}` and
  doesn't mark it edited. `{:error, :not_found | :forbidden | %Ecto.Changeset{}}`.
  """
  def edit_message(%Scope{user: user} = scope, message_id, body) do
    with {:ok, message} <- fetch_message(scope, message_id),
         :ok <- ensure_sender(message, user.id),
         :ok <- ensure_editable(message) do
      message = Repo.preload(message, :attachments)
      changeset = Message.edit_changeset(message, %{body: body})

      cond do
        not changeset.valid? ->
          {:error, changeset}

        not Map.has_key?(changeset.changes, :body) ->
          # Unchanged — don't stamp "edited" or broadcast for an empty edit.
          {:ok, Repo.preload(message, @message_preloads)}

        true ->
          {:ok, edited} =
            changeset |> Ecto.Changeset.put_change(:edited_at, now()) |> Repo.update()

          edited = Repo.preload(edited, @message_preloads)
          broadcast(message.conversation_id, {:message_edited, edited})
          {:ok, edited}
      end
    end
  end

  # A tombstone has no body to edit; a system message is context-authored, not the user's.
  defp ensure_editable(%Message{deleted_at: dt}) when not is_nil(dt), do: {:error, :not_found}
  defp ensure_editable(%Message{kind: "system"}), do: {:error, :forbidden}
  defp ensure_editable(%Message{}), do: :ok

  @doc """
  Replaces a message's album (#164, PR-2) — author only, same rules as `edit_message/3`.
  `kept_ids` are the message's existing attachments to keep (in their current order);
  `new_sources` are freshly uploaded files, appended after. Removed attachments' rows go
  and their blobs are reclaimed forward-safe (a blob a surviving attachment or a forward
  still references is spared). A **text** message (no attachments, so `kept_ids` resolve to
  none) is converted to a media message when `new_sources` are supplied — the composer's
  edit text becomes the caption. The album can't be emptied (delete the message instead) or
  exceed the cap. Caption rides `opts[:body]`. Stamps `edited_at` and broadcasts
  `{:message_edited}`. `{:error, :not_found | :forbidden | :empty | :too_many | :too_large
  | :unprocessable | %Ecto.Changeset{}}`.
  """
  def edit_message_media(
        %Scope{user: user} = scope,
        message_id,
        kept_ids,
        new_sources,
        opts \\ %{}
      )
      when is_list(kept_ids) and is_list(new_sources) do
    kept_ids = kept_ids |> Enum.map(&safe_id/1) |> Enum.filter(&is_integer/1)

    with {:ok, message} <- fetch_message(scope, message_id),
         :ok <- ensure_sender(message, user.id),
         :ok <- ensure_editable(message),
         message = Repo.preload(message, :attachments),
         # No ensure_media_message: a text message (kept resolves to none) converts to media
         # when new_sources are supplied; ensure_edit_album_size still forbids an empty result.
         kept = Enum.filter(message.attachments, &(&1.id in kept_ids)),
         :ok <- ensure_edit_album_size(length(kept) + length(new_sources)),
         {:ok, prepared} <- prepare_album(new_sources) do
      apply_media_edit(message, kept, prepared, opts)
    else
      # Every failing step (fetch_message, ensure_*, prepare_album) returns a tagged
      # {:error, _} — the bare-value clauses were unreachable.
      {:error, _} = error -> error
    end
  end

  # Media-editing is only for a message that already has an album (text uses edit_message/3).
  # The album can't be emptied and can't exceed the cap (kept + new).
  defp ensure_edit_album_size(0), do: {:error, :empty}
  defp ensure_edit_album_size(n) when n > @max_album_entries, do: {:error, :too_many}
  defp ensure_edit_album_size(_), do: :ok

  defp apply_media_edit(message, kept, prepared, opts) do
    removed = Enum.reject(message.attachments, fn a -> Enum.any?(kept, &(&1.id == a.id)) end)
    # Forward-safe: keys no surviving attachment (or a forward) still references.
    orphan_keys = unshared_blob_keys(removed)
    base = length(kept)

    prepared =
      prepared |> Enum.with_index(base) |> Enum.map(fn {a, i} -> Map.put(a, :position, i) end)

    result =
      Repo.transact(fn ->
        Enum.each(removed, &Repo.delete/1)

        kept
        |> Enum.with_index()
        |> Enum.each(fn {a, i} ->
          Repo.update_all(from(x in Attachment, where: x.id == ^a.id), set: [position: i])
        end)

        with :ok <- insert_attachments(message.id, prepared),
             {:ok, updated} <-
               message
               # A media edit always yields ≥1 attachment, so the body is an optional caption
               # (caption_edit_changeset) — even when converting a former text message.
               |> Message.caption_edit_changeset(%{body: Map.get(opts, :body, message.body)})
               |> Ecto.Changeset.put_change(:edited_at, now())
               |> Repo.update() do
          {:ok, Repo.preload(updated, @message_preloads, force: true)}
        end
      end)

    case result do
      {:ok, edited} ->
        # Storage.delete only after the rows commit (blobs are irreversible), re-checking
        # references now the removed rows are gone.
        delete_unreferenced_blobs(orphan_keys)

        for a <- edited.attachments,
            is_nil(a.thumbnail_key),
            needs_media_processing?(a.kind),
            do: enqueue_thumbnail(a)

        broadcast(message.conversation_id, {:message_edited, edited})
        {:ok, edited}

      {:error, reason} ->
        # The transaction rolled back — reclaim the new blobs we stored.
        Enum.each(prepared, &Storage.delete(&1.storage_key))
        {:error, reason}
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
         # A root with replies can't be deleted for everyone in v1 (no
         # tombstone rendering for thread roots yet) — clear error instead.
         :ok <- ensure_no_replies(message),
         {:ok, {tombstone, candidate_keys}} <- soft_delete(message) do
      # Storage.delete is irreversible, so it runs only after the tombstone
      # commits, re-checking references (the attachment row is gone) to close the
      # window where a concurrent forward grabbed the same blob.
      delete_unreferenced_blobs(candidate_keys)

      broadcast(message.conversation_id, {:message_deleted, tombstone})
      sync_thread_after_delete(tombstone)
      notify_members(message.conversation_id)
      :ok
    end
  end

  @doc """
  Multi-select delete-for-me (#multiselect): hides each of `ids` for the scoped user in one
  `insert_all` (unauthorized/already-hidden ids drop out via `get_messages`), then broadcasts a
  hide per affected message. Returns the number hidden.
  """
  def delete_messages_for_me(%Scope{user: user} = scope, ids) when is_list(ids) do
    messages = get_messages(scope, ids)
    rows = Enum.map(messages, &%{message_id: &1.id, user_id: user.id, inserted_at: now()})

    Repo.insert_all(MessageDeletion, rows,
      on_conflict: :nothing,
      conflict_target: [:message_id, :user_id]
    )

    Enum.each(messages, fn m ->
      Phoenix.PubSub.broadcast(
        @pubsub,
        user_topic(user.id),
        {:message_hidden, m.conversation_id, m.id, m.group_id}
      )
    end)

    length(messages)
  end

  @doc """
  Multi-select delete-for-everyone (#multiselect): soft-deletes each of `ids`. Each call
  re-checks authorship (sender only) and refuses a root with replies, so a non-owned or
  undeletable id is skipped — the UI only offers "for everyone" when every selected message is
  the user's own AND none is a root with replies. Returns the number actually deleted.
  """
  def delete_messages_for_both(%Scope{} = scope, ids) when is_list(ids) do
    Enum.count(ids, &(delete_message_for_both(scope, &1) == :ok))
  end

  defp ensure_no_replies(%Message{reply_count: count}) when count > 0,
    do: {:error, :has_replies}

  defp ensure_no_replies(_message), do: :ok

  # Deleting a reply for everyone keeps the root's counter honest (floored at
  # zero against races) and lets open panels/footers refresh.
  defp sync_thread_after_delete(%Message{root_id: nil}), do: :ok

  defp sync_thread_after_delete(%Message{
         root_id: root_id,
         conversation_id: conversation_id,
         inserted_at: reply_at
       }) do
    from(m in Message,
      where: m.id == ^root_id,
      update: [set: [reply_count: fragment("GREATEST(reply_count - 1, 0)")]]
    )
    |> Repo.update_all([])

    # The deleted reply was still unread for any follower who hadn't viewed past
    # it (#57): decrement their count so a removed reply can't leave a phantom
    # unread. `unread_replies > 0` floors it; `last_viewed_at` gates who it counted
    # against (a viewer who read past it already had it cleared to zero on view).
    from(tm in ThreadMembership,
      where:
        tm.root_id == ^root_id and tm.unread_replies > 0 and
          (is_nil(tm.last_viewed_at) or tm.last_viewed_at < ^reply_at)
    )
    |> Repo.update_all(inc: [unread_replies: -1])

    case preloaded_message(root_id) do
      nil -> :ok
      root -> broadcast(conversation_id, {:thread_updated, root})
    end
  end

  ## Threads (flat, Mattermost-style)
  #
  # A reply is a message whose `root_id` points at a non-reply message in the
  # same conversation. Replies never enter the main stream, sidebar previews,
  # or unread badges (v1 — per-thread unreads are the CRT follow-up); the root
  # carries denormalized `reply_count`/`last_reply_at` maintained here.

  @thread_cap 500
  @facepile_cap 5

  @doc """
  Posts a reply into a message's thread. Authorized via the root's
  conversation membership; the flat rule holds (the root may not itself be a
  reply). Counters bump atomically; broadcasts `{:thread_reply, root, reply}`
  on the conversation topic — deliberately NOT `deliver/2`: replies don't
  reorder the sidebar, resurface 1:1s, or count as unread.
  """
  def create_reply(%Scope{user: user} = scope, root_id, attrs) do
    with {:ok, root} <- fetch_message(scope, root_id),
         :ok <- ensure_not_deleted(root),
         :ok <- ensure_root(root),
         :ok <- ensure_threaded(root.conversation_id) do
      # A thread reply may quote another message in the same conversation (#71).
      reply_to_id =
        valid_reply_to_id(
          attrs["reply_to_id"] || attrs[:reply_to_id],
          root.conversation_id,
          user.id
        )

      %Message{
        conversation_id: root.conversation_id,
        sender_id: user.id,
        root_id: root.id,
        reply_to_id: reply_to_id
      }
      |> Message.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, reply} -> {:ok, deliver_reply(root, reply)}
        {:error, changeset} -> resolve_duplicate(changeset, user.id)
      end
    end
  end

  @doc """
  A thread: the root (preloaded) plus its visible replies, oldest first
  (capped at #{@thread_cap}). `{:error, :not_found | :deleted}`.
  """
  def list_thread(%Scope{user: user} = scope, root_id) do
    with {:ok, root} <- fetch_message(scope, root_id),
         :ok <- ensure_not_deleted(root),
         :ok <- ensure_root(root),
         :ok <- ensure_threaded(root.conversation_id) do
      replies =
        Message
        |> where([m], m.root_id == ^root.id and is_nil(m.deleted_at))
        |> join(:left, [m], d in MessageDeletion,
          on: d.message_id == m.id and d.user_id == ^user.id
        )
        |> where([_m, d], is_nil(d.id))
        |> order_by([m], asc: m.id)
        |> limit(@thread_cap)
        |> preload([
          :sender,
          :attachments,
          reactions: :user,
          reply_to: [:sender, :attachments],
          forwarded_from: :sender
        ])
        |> Repo.all()

      {:ok,
       Repo.preload(root, [
         :sender,
         :attachments,
         reactions: :user,
         reply_to: [:sender, :attachments],
         forwarded_from: :sender
       ]), replies}
    end
  end

  @doc """
  Where a message lives: `{:ok, root_id}` if it is a reply, `:none` if it is a
  top-level message — used by permalinks to open the right surface.
  """
  def thread_root_for(%Scope{} = scope, message_id) do
    with {:ok, message} <- fetch_message(scope, message_id) do
      case message.root_id do
        nil -> :none
        root_id -> {:ok, root_id}
      end
    end
  end

  @doc """
  Facepile data: up to #{@facepile_cap} distinct repliers per root (most recent
  first), `%{root_id => [user]}`. Roots must come from an already-authorized
  message list; membership is still re-checked against the conversation.
  """
  def thread_participants(%Scope{} = scope, conversation_id, root_ids) do
    ids = Enum.reject(root_ids, &is_nil/1)

    if ids != [] and member?(scope, conversation_id) do
      rows =
        Repo.all(
          from m in Message,
            where:
              m.root_id in ^ids and m.conversation_id == ^conversation_id and
                is_nil(m.deleted_at),
            group_by: [m.root_id, m.sender_id],
            select: {m.root_id, m.sender_id, max(m.id)}
        )

      user_ids = rows |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
      users = Map.new(Repo.all(from u in User, where: u.id in ^user_ids), &{&1.id, &1})

      rows
      |> Enum.group_by(&elem(&1, 0))
      |> Map.new(fn {root_id, entries} ->
        participants =
          entries
          |> Enum.sort_by(&elem(&1, 2), :desc)
          |> Enum.take(@facepile_cap)
          |> Enum.map(&Map.fetch!(users, elem(&1, 1)))

        {root_id, participants}
      end)
    else
      %{}
    end
  end

  @doc """
  Follow a thread (#57) so its new replies count toward the viewer's unread.
  Idempotent (re-following never resets the count); authorized via the root's
  room membership. `{:error, :not_found | :not_a_root}`.
  """
  def follow_thread(%Scope{user: user} = scope, root_id) do
    with {:ok, root} <- fetch_message(scope, root_id),
         :ok <- ensure_not_deleted(root),
         :ok <- ensure_root(root),
         :ok <- ensure_threaded(root.conversation_id) do
      upsert_thread_membership(user.id, root.id, following: true)
      {:ok, :following}
    end
  end

  @doc """
  Unfollow a thread: keeps the row (so a later reply by someone else won't
  silently re-subscribe you) but stops counting and clears the unread count.
  """
  def unfollow_thread(%Scope{user: user} = scope, root_id) do
    with {:ok, root} <- fetch_message(scope, root_id),
         :ok <- ensure_not_deleted(root),
         :ok <- ensure_root(root),
         :ok <- ensure_threaded(root.conversation_id) do
      upsert_thread_membership(user.id, root.id, following: false, unread_replies: 0)
      {:ok, :unfollowed}
    end
  end

  @doc """
  Marks a thread read for the scoped user: resets its unread count and stamps
  `last_viewed_at`. Viewing does not subscribe you (Mattermost semantics), so a
  non-follower's missing row is left untouched (nothing to reset).
  """
  def mark_thread_read(%Scope{user: user} = scope, root_id) do
    with {:ok, root} <- fetch_message(scope, root_id),
         :ok <- ensure_not_deleted(root),
         :ok <- ensure_root(root),
         :ok <- ensure_threaded(root.conversation_id) do
      from(tm in ThreadMembership, where: tm.user_id == ^user.id and tm.root_id == ^root.id)
      |> Repo.update_all(set: [last_viewed_at: now(), unread_replies: 0])

      # Sync the user's other open sessions (multi-tab): zero this thread's badge.
      Phoenix.PubSub.broadcast(
        @pubsub,
        user_topic(user.id),
        {:thread_read, root.conversation_id, root.id}
      )

      :ok
    end
  end

  @doc """
  The scoped user's follow state for one thread:
  `%{following: boolean, unread: integer}` (defaults when there is no row).
  """
  def thread_follow_state(%Scope{user: user}, root_id) do
    case Repo.one(
           from tm in ThreadMembership,
             where: tm.user_id == ^user.id and tm.root_id == ^root_id,
             select: {tm.following, tm.unread_replies}
         ) do
      {following, unread} -> %{following: following, unread: unread}
      nil -> %{following: false, unread: 0}
    end
  end

  @doc """
  Per-thread unread counts for the scoped user within one room:
  `%{root_id => unread_replies}` over the threads they follow (a count may be 0).
  Seeds the room's Threads badge + per-thread indicators; scoped by membership.
  """
  def thread_unread_counts(%Scope{user: user} = scope, conversation_id) do
    if member?(scope, conversation_id) do
      Repo.all(
        from r in Message,
          join: tm in ThreadMembership,
          on: tm.root_id == r.id and tm.user_id == ^user.id,
          left_join: d in MessageDeletion,
          on: d.message_id == r.id and d.user_id == ^user.id,
          where:
            tm.following == true and r.conversation_id == ^conversation_id and
              is_nil(r.deleted_at) and is_nil(d.id),
          select: {r.id, tm.unread_replies}
      )
      |> Map.new()
    else
      %{}
    end
  end

  @doc """
  The scoped user's followed threads in a room, most-recently active first:
  `[{root_message, unread_replies}]` with the root's sender/attachments preloaded.
  Backs the room's Threads list; tombstoned roots excluded; capped at #{@thread_cap}.
  """
  def list_followed_threads(%Scope{user: user} = scope, conversation_id) do
    if member?(scope, conversation_id) do
      Repo.all(
        from r in Message,
          join: tm in ThreadMembership,
          on: tm.root_id == r.id and tm.user_id == ^user.id,
          left_join: d in MessageDeletion,
          on: d.message_id == r.id and d.user_id == ^user.id,
          where:
            tm.following == true and r.conversation_id == ^conversation_id and
              is_nil(r.deleted_at) and is_nil(d.id),
          # Active threads first; a followed reply-less root (last_reply_at NULL)
          # must sort last, not first (Postgres DESC is NULLS FIRST by default).
          order_by: [desc_nulls_last: r.last_reply_at, desc: r.id],
          limit: @thread_cap,
          preload: [:sender, :attachments],
          select: {r, tm.unread_replies}
      )
    else
      []
    end
  end

  defp ensure_root(%Message{root_id: nil}), do: :ok
  defp ensure_root(_reply), do: {:error, :not_a_root}

  # Threads live only in channel rooms (#26), never in DMs/groups — the personal
  # messenger has no thread UI. A DM root is reported as not-found so a crafted
  # reply/open can't create or surface a thread there.
  defp ensure_threaded(conversation_id) do
    if room?(conversation_id), do: :ok, else: {:error, :not_found}
  end

  # Counter bump + fanout. The root is re-read fresh so every session renders
  # the same footer (count, last reply time). A 0-row bump means the root was
  # hard-deleted underneath us (admin deleted the room mid-send) — everything
  # cascaded, so there is nobody left to notify; skip follow-tracking and the
  # broadcast (track_reply's FK insert would otherwise raise) and don't crash the
  # sender.
  defp deliver_reply(root, reply) do
    {bumped, _} =
      Repo.update_all(from(m in Message, where: m.id == ^root.id),
        inc: [reply_count: 1],
        set: [last_reply_at: reply.inserted_at]
      )

    reply = Repo.preload(reply, @message_preloads)

    with 1 <- bumped,
         %Message{} = fresh_root <- preloaded_message(root.id) do
      # Follow tracking (#57): the replier auto-follows, the root author is pulled
      # in on the first reply, and every other follower gains one unread reply.
      track_reply(root, reply)
      broadcast(root.conversation_id, {:thread_reply, fresh_root, reply})
      notify_new(reply)
    end

    reply
  end

  defp preloaded_message(id) do
    Repo.one(from m in Message, where: m.id == ^id, preload: ^@message_preloads)
  end

  # Follow bookkeeping for a new reply (#57). Sequenced inside one transaction:
  # (1) the replier auto-follows and has seen their own reply (count reset to 0);
  # (2) the root author is pulled in on the first reply — insert-if-missing, so an
  # explicit unfollow is never undone; (3) every OTHER follower gains one unread.
  # The order matters: the replier is reset before the fan-out skips them, and the
  # author's row exists before it's counted.
  defp track_reply(root, reply) do
    Repo.transact(fn ->
      upsert_thread_membership(reply.sender_id, root.id,
        following: true,
        last_viewed_at: reply.inserted_at,
        unread_replies: 0
      )

      if root.sender_id not in [nil, reply.sender_id] do
        ensure_following(root.sender_id, root.id)
      end

      from(tm in ThreadMembership,
        where:
          tm.root_id == ^root.id and tm.following == true and
            tm.user_id != ^reply.sender_id
      )
      |> Repo.update_all(inc: [unread_replies: 1])

      {:ok, :tracked}
    end)
  end

  # Insert-or-update a thread membership. `set` is applied on conflict, so callers
  # control exactly which fields a re-follow / reply touches (e.g. follow_thread
  # sets only :following, preserving any unread count).
  defp upsert_thread_membership(user_id, root_id, set) do
    Repo.insert!(
      %ThreadMembership{
        user_id: user_id,
        root_id: root_id,
        following: Keyword.get(set, :following, true),
        last_viewed_at: Keyword.get(set, :last_viewed_at),
        unread_replies: Keyword.get(set, :unread_replies, 0)
      },
      on_conflict: [set: Keyword.put(set, :updated_at, now())],
      conflict_target: [:user_id, :root_id]
    )
  end

  # Ensure a follow row exists without disturbing an existing one (respects a
  # prior unfollow).
  defp ensure_following(user_id, root_id) do
    Repo.insert!(
      %ThreadMembership{user_id: user_id, root_id: root_id, following: true},
      on_conflict: :nothing,
      conflict_target: [:user_id, :root_id]
    )
  end

  ## Reactions (#67)

  @doc "Every allowed reaction emoji (quick row first) the full picker renders."
  def allowed_reactions, do: MessageReaction.allowed()

  @doc "Max emoji a personal quick-react row may hold."
  def quick_reaction_limit, do: MessageReaction.quick_limit()

  @doc "The default quick-react row (used when a user hasn't customized theirs)."
  def default_quick_reactions, do: MessageReaction.quick()

  @doc "The scoped user's personal quick-react row, or the default set if unset."
  def quick_reactions(%Scope{user: user}) do
    Repo.one(from p in FolderPrefs, where: p.user_id == ^user.id, select: p.quick_reactions)
    |> normalize_quick()
    |> case do
      [] -> MessageReaction.quick()
      list -> list
    end
  end

  @doc """
  Sets the scoped user's quick-react row: keeps only allowed emoji (deduped, order
  preserved) capped at `MessageReaction.quick_limit/0`. An empty result resets to
  the default (stored as `nil`). Returns `{:ok, effective_list}`.
  """
  def set_quick_reactions(%Scope{user: user}, emojis) when is_list(emojis) do
    stored =
      case normalize_quick(emojis) do
        [] -> nil
        list -> list
      end

    Repo.insert!(%FolderPrefs{user_id: user.id, quick_reactions: stored},
      on_conflict: [set: [quick_reactions: stored, updated_at: now()]],
      conflict_target: :user_id
    )

    # `stored` is already normalized, so skip the re-read; nil → the default set.
    {:ok, stored || MessageReaction.quick()}
  end

  @doc """
  The scoped user's double-click reaction emoji (#106): their stored choice when
  it's still an allowed emoji, otherwise the first of their quick-react row.
  Always returns a valid emoji (the quick row falls back to the default set, which
  is non-empty), so callers can use it directly.
  """
  def dbl_click_reaction(%Scope{user: user} = scope) do
    stored =
      Repo.one(from p in FolderPrefs, where: p.user_id == ^user.id, select: p.dbl_click_reaction)

    if is_binary(stored) and stored in MessageReaction.allowed() do
      stored
    else
      hd(quick_reactions(scope))
    end
  end

  @doc """
  Sets the scoped user's double-click reaction (#106). A non-allowed emoji (or
  `nil`) is stored as `nil`, which resolves back to the first quick reaction.
  Returns `{:ok, effective_emoji}`.
  """
  def set_dbl_click_reaction(%Scope{user: user} = scope, emoji) do
    stored = if is_binary(emoji) and emoji in MessageReaction.allowed(), do: emoji, else: nil

    Repo.insert!(%FolderPrefs{user_id: user.id, dbl_click_reaction: stored},
      on_conflict: [set: [dbl_click_reaction: stored, updated_at: now()]],
      conflict_target: :user_id
    )

    {:ok, stored || hd(quick_reactions(scope))}
  end

  @doc """
  The scoped user's notification toggles (#214) as `%{sound: bool, desktop: bool}`.
  Falls back to the defaults (sound on, desktop off) when the user has no prefs row;
  a present row always carries booleans (the columns are NOT NULL), so the `||`
  applies to the whole map, never a per-field default.
  """
  def notification_prefs(%Scope{user: user}) do
    row =
      Repo.one(
        from p in FolderPrefs,
          where: p.user_id == ^user.id,
          select: %{
            sound: p.notify_sound,
            desktop: p.notify_desktop,
            sound_name: p.notify_sound_name
          }
      )

    # A missing row (or a NULL / since-retired preset name) resolves to the
    # default chime, so callers always get a valid, playable preset.
    name =
      if row && row.sound_name in @notify_sound_names, do: row.sound_name, else: @default_sound

    Map.put(row || %{sound: true, desktop: false}, :sound_name, name)
  end

  @doc "The selectable notification-chime presets (#289), in display order."
  def notify_sound_names, do: @notify_sound_names

  @doc "The default chime preset (#289) — used when the user hasn't picked one."
  def default_notify_sound_name, do: @default_sound

  @doc """
  Sets the scoped user's notification-chime preset (#289). The name is validated
  against the closed set (it's client-supplied), so an unknown value is a no-op
  `{:error, :invalid}` rather than a stored dead preset. Returns `{:ok, name}`.
  """
  def set_notify_sound_name(%Scope{user: user}, name) when is_binary(name) do
    if name in @notify_sound_names,
      do: upsert_notify(user.id, :notify_sound_name, name),
      else: {:error, :invalid}
  end

  @doc "Sets the scoped user's sound-notification toggle (#214). Returns `{:ok, on}`."
  def set_notify_sound(%Scope{user: user}, on) when is_boolean(on),
    do: upsert_notify(user.id, :notify_sound, on)

  @doc "Sets the scoped user's desktop-notification toggle (#214). Returns `{:ok, on}`."
  def set_notify_desktop(%Scope{user: user}, on) when is_boolean(on),
    do: upsert_notify(user.id, :notify_desktop, on)

  # One-field upsert: the other notify column keeps its schema default on insert,
  # and on conflict only this field (+ updated_at) is touched — never clobbering
  # quick_reactions / dbl_click_reaction on the shared row.
  defp upsert_notify(user_id, field, on) do
    Repo.insert!(struct(%FolderPrefs{user_id: user_id}, [{field, on}]),
      on_conflict: [set: [{field, on}, {:updated_at, now()}]],
      conflict_target: :user_id
    )

    {:ok, on}
  end

  # Keep only currently-allowed emoji (deduped, order preserved, capped). nil-safe:
  # a NULL column — or a set curated down in a later release — normalizes cleanly,
  # so a now-stale stored emoji silently drops instead of becoming a dead button.
  defp normalize_quick(nil), do: []

  defp normalize_quick(emojis) when is_list(emojis) do
    allowed = MapSet.new(MessageReaction.allowed())

    emojis
    |> Enum.filter(&MapSet.member?(allowed, &1))
    |> Enum.uniq()
    |> Enum.take(MessageReaction.quick_limit())
  end

  @doc """
  Toggles the scoped user's `emoji` reaction on a message (DM or room): adds it
  if absent, removes it if present. Authorized by **active** conversation
  membership (`:not_found` if you never joined or have left it); tombstoned
  messages reject; a non-allowed `emoji` fails the changeset. Broadcasts
  `{:reaction_changed, message}` (reactions reloaded) so every viewer recomputes
  their own chips. Returns `{:ok, message}`.
  """
  def toggle_reaction(%Scope{user: user} = scope, message_id, emoji) do
    with {:ok, message} <- fetch_message(scope, message_id),
         :ok <- ensure_active_member(scope, message.conversation_id),
         :ok <- ensure_not_deleted(message),
         {:ok, _} <- do_toggle_reaction(message.id, user.id, emoji),
         # Re-read after the write; a concurrent delete-for-both may have
         # tombstoned it — don't broadcast (and thereby re-insert) a dead message.
         %Message{deleted_at: nil} = fresh <- preloaded_message(message.id) do
      broadcast(fresh.conversation_id, {:reaction_changed, fresh})
      {:ok, fresh}
    else
      %Message{} -> {:error, :deleted}
      # A concurrent HARD delete (room GC / admin cascade) removes the message row, so the
      # re-read returns nil — surface a tagged error, not a bare nil, which would
      # CaseClauseError the caller's react handler (#258).
      nil -> {:error, :not_found}
      other -> other
    end
  end

  # Active = a membership row with no `left_at`. Unlike the shared `member?`/
  # `fetch_message` (which a left member still passes, by design, for forward/
  # delete paths), reacting from a chat you've left would broadcast to the
  # remaining members — so reactions require live membership.
  defp ensure_active_member(%Scope{user: user}, conversation_id) do
    active? =
      Repo.exists?(
        from m in Membership,
          where:
            m.conversation_id == ^conversation_id and m.user_id == ^user.id and
              is_nil(m.left_at)
      )

    if active?, do: :ok, else: {:error, :not_found}
  end

  # A single get-then-(insert|delete); no transaction needed — events on one
  # session are serialized, and the unique index (not isolation) guards the
  # add-add race, surfacing it as a changeset error we treat as a no-op.
  defp do_toggle_reaction(message_id, user_id, emoji) do
    case Repo.get_by(MessageReaction, message_id: message_id, user_id: user_id, emoji: emoji) do
      %MessageReaction{} = existing ->
        # delete_all (not Repo.delete on the struct) so two tabs un-reacting the same row
        # is a 0-row no-op, not an Ecto.StaleEntryError (#258) — mirrors do_toggle_folder.
        Repo.delete_all(from r in MessageReaction, where: r.id == ^existing.id)
        {:ok, :removed}

      nil ->
        %MessageReaction{message_id: message_id, user_id: user_id}
        |> MessageReaction.changeset(%{"emoji" => emoji})
        |> Repo.insert()
    end
  end

  @doc """
  Forwards a message into another conversation the scoped user belongs to (DM, group, or
  room): a new message copying the body and (re-referencing) the attachments, attributed to
  the original author. When `root_id` is given, the forward lands INSIDE that thread as a
  reply (rooms-only, #26) — the root's counters + follow tracking update like a normal reply,
  and the root's room is the target (its membership authorizes serving). The copied attachment
  points at the same blob. `{:error, :not_found | :deleted | :not_a_root}`.
  """
  def forward_message(scope, message_id, target_conversation_id, root_id \\ nil)

  def forward_message(%Scope{user: user} = scope, message_id, target_conversation_id, nil) do
    with {:ok, source} <- fetch_message(scope, message_id),
         :ok <- ensure_source_access(scope, source),
         :ok <- ensure_not_deleted(source),
         target_id when is_integer(target_id) <- safe_id(target_conversation_id),
         :ok <- ensure_member(scope, target_id) do
      do_forward(user, target_id, Repo.preload(source, :attachments))
    else
      :error -> {:error, :not_found}
      error -> error
    end
  end

  def forward_message(%Scope{user: user} = scope, message_id, _target_conversation_id, root_id) do
    with {:ok, source} <- fetch_message(scope, message_id),
         :ok <- ensure_source_access(scope, source),
         :ok <- ensure_not_deleted(source),
         {:ok, root} <- fetch_message(scope, root_id),
         :ok <- ensure_not_deleted(root),
         :ok <- ensure_root(root),
         :ok <- ensure_threaded(root.conversation_id) do
      do_forward_reply(user, root, Repo.preload(source, :attachments))
    else
      # Every step returns a tagged {:error, _} (no safe_id guard here, unlike the /3 head).
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
           :ok <- copy_attachments(message.id, source.attachments) do
        {:ok, message}
      end
    end)
  end

  # Forward INTO a thread: insert the copy as a reply under `root`, then run the same
  # root-bump + follow tracking + broadcast as create_reply (deliver_reply).
  defp do_forward_reply(user, root, source) do
    result =
      Repo.transact(fn ->
        with {:ok, reply} <- insert_forward_reply(user, root, source),
             :ok <- copy_attachments(reply.id, source.attachments) do
          {:ok, reply}
        end
      end)

    case result do
      {:ok, reply} -> {:ok, deliver_reply(root, reply)}
      error -> error
    end
  end

  defp insert_forward_reply(user, root, source) do
    %Message{
      conversation_id: root.conversation_id,
      sender_id: user.id,
      root_id: root.id,
      forwarded_from_id: source.forwarded_from_id || source.id
    }
    |> Message.photo_changeset(%{"body" => source.body || ""})
    |> Repo.insert()
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

  # Forward TARGET gate: dropping a forward into a conversation broadcasts to its
  # members, so it requires active access (a left group member can't forward INTO the
  # group they left, #255) — not just a lingering membership row.
  defp ensure_member(scope, conversation_id),
    do: if(has_access?(scope, conversation_id), do: :ok, else: {:error, :not_found})

  # Forward SOURCE gate (#255): forwarding copies content OUT, so a left group member
  # must not exfiltrate a group's messages (incl. those posted after they left).
  # fetch_message stays permissive for the other paths (edit/delete-your-own/reply).
  defp ensure_source_access(scope, %Message{conversation_id: cid}),
    do: if(has_access?(scope, cid), do: :ok, else: {:error, :not_found})

  # Tombstone the message and delete its attachment row inside one transaction,
  # returning the blob keys safe to delete afterwards (no side effects in the txn).
  defp soft_delete(message) do
    Repo.transact(fn ->
      message = Repo.preload(message, :attachments)
      orphan_keys = unshared_blob_keys(message.attachments)
      Enum.each(message.attachments, &Repo.delete/1)
      # A tombstone has no reactions — drop them (the row survives, so the FK
      # cascade doesn't fire on a soft delete).
      Repo.delete_all(from(r in MessageReaction, where: r.message_id == ^message.id))

      with {:ok, tombstone} <-
             message
             |> Ecto.Changeset.change(deleted_at: now(), body: "")
             |> Repo.update() do
        {:ok, {Repo.preload(tombstone, [:sender, :attachments], force: true), orphan_keys}}
      end
    end)
  end

  # Blob keys none of these attachments' siblings (or any other attachment)
  # reference — safe to delete once their rows are gone. (Forwards re-reference
  # the same storage_key.) The album's own ids are excluded together so two
  # photos sharing nothing each still get cleaned.
  defp unshared_blob_keys(attachments) do
    ids = Enum.map(attachments, & &1.id)

    attachments
    |> Enum.flat_map(&[&1.storage_key, &1.thumbnail_key])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.reject(&blob_shared_outside?(&1, ids))
  end

  defp blob_shared_outside?(key, exclude_ids) do
    Repo.exists?(
      from a in Attachment,
        where: a.id not in ^exclude_ids and (a.storage_key == ^key or a.thumbnail_key == ^key)
    )
  end

  @doc """
  Deletes each blob no remaining attachment references — the one place every
  delete path (message delete-for-both, conversation GC, channel deletion via
  `Eden.Channels`) funnels through, so the "spare a blob a forward still
  shares" invariant can't drift. Call post-commit, when the deleting rows are
  already gone; one query, not one per key.
  """
  def delete_unreferenced_blobs([]), do: :ok

  def delete_unreferenced_blobs(keys) do
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

  # Re-reference each source attachment into the forwarded message, preserving
  # order. The same storage_key/thumbnail_key are shared (delete spares blobs a
  # forward still references); processing is re-enqueued only for a copy whose
  # source had no preview yet.
  defp copy_attachments(message_id, sources) do
    sources
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {source, idx}, :ok ->
      case copy_attachment(message_id, source, idx) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp copy_attachment(message_id, %Attachment{} = source, position) do
    attrs =
      source
      |> Map.take([
        :kind,
        :storage_key,
        :content_type,
        :byte_size,
        :filename,
        :width,
        :height,
        :duration,
        :thumbnail_key,
        # #122: keep a forwarded "send as file" photo rendering as a document, not inline.
        :as_file
      ])
      |> Map.put(:position, position)

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

  @doc """
  Marks the conversation read up to now for the scoped user. The read receipt is
  broadcast **only when the user is actually a member** — the membership-scoped
  `update_all` touches zero rows for a non-member, so a non-participant who guesses
  a conversation id can't forge a "✓✓ read" receipt into a chat they don't belong to.
  Returns `:ok` either way (a non-member call is a silent no-op, leaking nothing).
  """
  def mark_read(%Scope{user: user}, conversation_id) do
    read_at = now()

    # The #255 active-participation predicate is folded INTO the update (join the
    # conversation) rather than a separate has_access?/2 probe first — mark_read is a
    # hot path (every read receipt), so keep it to one query. A left group member's
    # row simply isn't matched, so nothing is stamped and no {:read} is broadcast;
    # 1:1 stays permissive and rooms hard-delete, exactly as has_access?/2 encodes.
    {updated, _} =
      from(m in Membership,
        join: c in Conversation,
        on: c.id == m.conversation_id,
        where:
          m.conversation_id == ^conversation_id and m.user_id == ^user.id and
            (is_nil(m.left_at) or not (c.is_group and is_nil(c.channel_id)))
      )
      |> Repo.update_all(set: [last_read_at: read_at])

    if updated > 0, do: broadcast(conversation_id, {:read, user.id, read_at})
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
        join: c in Conversation,
        on: c.id == m.conversation_id,
        join: mem in Membership,
        on:
          mem.conversation_id == m.conversation_id and mem.user_id == ^user.id and
            (is_nil(mem.left_at) or not (c.is_group and is_nil(c.channel_id))),
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

  @doc false
  # Active-participation gate (#255). A left/removed **personal-group** member keeps
  # their membership row (left_at set) so forward/delete-of-a-specific-message still
  # work — but they must NOT read history or send (which would broadcast to the
  # remaining members). This is the authorization used by every participation path
  # (read/list/send/mark-read/attachments/forward-target); `member?/2` stays the raw
  # "row exists" check for the deliberately-permissive leave and forward-source paths.
  #   - personal group (is_group AND no channel_id): blocked once `left_at` is set.
  #   - 1:1 (not is_group): permissive — messaging back resurfaces the chat.
  #   - room (channel_id): membership is hard-deleted on leave, so a left member has
  #     no row and fails here anyway; an active member's row has `left_at` nil.
  def has_access?(%Scope{user: user}, conversation_id),
    do: Repo.exists?(access_query(user.id, conversation_id))

  defp access_query(user_id, conversation_id) do
    from m in Membership,
      join: c in Conversation,
      on: c.id == m.conversation_id,
      where:
        m.conversation_id == ^conversation_id and m.user_id == ^user_id and
          (is_nil(m.left_at) or not (c.is_group and is_nil(c.channel_id)))
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

  @doc """
  Broadcast that the scoped user is typing in `conversation_id`, on the
  conversation topic — so only sessions with that conversation open see it.
  Ephemeral: no DB write, receivers track it with a short TTL. Throttle at the
  call site (it fires per keystroke otherwise).

  Like `subscribe/1`, this does NOT re-check membership — pass a
  `conversation_id` the scoped user is authorized for. The only caller uses the
  open, already-authorized conversation, and only its members are subscribed to
  the topic, so the typing event never reaches a non-member.

  `root_id` is `nil` for the main composer and the thread root's id for a thread
  reply (#103) — receivers route it to the right indicator (a thread typer shows
  only inside that open thread panel, never the main room stream).
  """
  def broadcast_typing(%Scope{user: user}, conversation_id, root_id \\ nil),
    do: broadcast(conversation_id, {:typing, user.id, user.display_name, root_id})

  @doc "Throttle window (ms) for outgoing typing broadcasts — one source for the room AND thread composers (#11/#103)."
  def typing_throttle_ms, do: 2_000

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

  # #213: fan a notification out to everyone who should hear about `message`. The
  # recipient set is gated server-side — members (or, for a thread reply, thread
  # FOLLOWERS) minus the sender, minus anyone with the conversation directly muted
  # (membership or folder), minus Do-Not-Disturb, and (for a room, #271) minus anyone
  # who muted the CHANNEL. Only the per-session "is this the chat I'm looking at right
  # now" focus gate is left to the web layer. Mute and DND silence everything, including
  # followed threads (decided in #213). `conv` is loaded once and shared by the
  # recipient query and the payload.
  defp notify_new(message) do
    if group_follow_up?(message) do
      # A trailing member of a file group (TG-attachments): the group's FIRST message
      # already notified; the rest are the same "N files" send and must not re-ring.
      :ok
    else
      conv = Repo.get(Conversation, message.conversation_id)

      case notify_recipient_ids(message, conv) do
        [] -> :ok
        recipients -> Notifications.deliver(recipients, notify_payload(message, conv))
      end
    end
  end

  # Notify-once per file group: true when an EARLIER row of the same group already exists,
  # so only the first message of a send delivers a notification. DB-side (not a client
  # flag) so it holds even when a group's rows are created across a reconnect/resume rather
  # than in one call. Ungrouped messages (nil) always notify.
  defp group_follow_up?(%{group_id: nil}), do: false

  defp group_follow_up?(%{group_id: group_id, conversation_id: conversation_id, id: id}) do
    Repo.exists?(
      from(m in Message,
        where: m.conversation_id == ^conversation_id and m.group_id == ^group_id and m.id < ^id
      )
    )
  end

  # Who should hear about `message`: thread FOLLOWERS for a reply (#57), else the
  # conversation's active MEMBERS. The base set runs through `common_gates/2` (shared
  # per-user rules) and `exclude_channel_muted/2` (#271 — for a room, drop anyone who
  # muted the channel). Filtered entirely in SQL.
  defp notify_recipient_ids(message, conv) do
    message
    |> recipient_base_query()
    |> common_gates(message)
    |> exclude_channel_muted(channel_muted_ids(conv))
    |> Repo.all()
  end

  # Threads are rooms-only, so no folder mute — just the room membership's direct mute +
  # DND (via common_gates). The Membership join also drops anyone who left.
  defp recipient_base_query(%{root_id: root_id} = message) when not is_nil(root_id) do
    from(tm in ThreadMembership,
      join: u in User,
      as: :user,
      on: u.id == tm.user_id,
      join: m in Membership,
      as: :membership,
      on: m.user_id == tm.user_id and m.conversation_id == ^message.conversation_id,
      where: tm.root_id == ^message.root_id and tm.following == true,
      select: tm.user_id
    )
  end

  defp recipient_base_query(message) do
    from(m in Membership,
      as: :membership,
      join: u in User,
      as: :user,
      on: u.id == m.user_id,
      where:
        m.conversation_id == ^message.conversation_id and
          m.user_id not in subquery(muted_folder_users(message)),
      select: m.user_id
    )
  end

  # The gates every recipient path shares — not the sender, hasn't left, hasn't directly
  # muted the conversation, isn't in Do-Not-Disturb. Runs on the `:membership`/`:user`
  # named bindings both base queries declare. `presence_status` is NOT NULL (default
  # "auto"), so the bare `!= "dnd"` keeps everyone else (no NULL-comparison surprise).
  defp common_gates(query, message) do
    from([membership: m, user: u] in query,
      where:
        m.user_id != ^message.sender_id and is_nil(m.left_at) and
          is_nil(m.muted_at) and u.presence_status != "dnd"
    )
  end

  # #271: for a room message, drop anyone who muted the CHANNEL — that's Channels data,
  # so we ask `Eden.Channels.muted_user_ids/1` rather than reach into channel_memberships.
  # Applied server-side (not in the web layer) so every future delivery adapter (push,
  # desktop) inherits the mute for free. A no-op list for DMs/groups (no channel).
  defp channel_muted_ids(%Conversation{channel_id: cid}) when not is_nil(cid),
    do: Channels.muted_user_ids(cid)

  defp channel_muted_ids(_), do: []

  defp exclude_channel_muted(query, []), do: query

  defp exclude_channel_muted(query, muted_ids),
    do: from([membership: m] in query, where: m.user_id not in ^muted_ids)

  # Users who muted `message`'s conversation via ANY of their muted folders (direct
  # chats only — rooms/threads have no folders).
  defp muted_folder_users(message) do
    from fm in FolderMembership,
      join: f in Folder,
      on: f.id == fm.folder_id,
      where: fm.conversation_id == ^message.conversation_id and not is_nil(f.muted_at),
      select: f.user_id
  end

  # Locale-neutral payload: the web layer (recipient's session) formats the title,
  # localizes any media label, and applies the per-session focus suppression.
  # The `%User{}` match makes the `:sender` preload a hard contract — a caller that
  # forgets it fails loudly here (a NotLoaded assoc is truthy, so a `sender && …`
  # would otherwise crash deep in field access). Both callers preload it (`deliver`,
  # `deliver_reply`). `conv` (loaded once in `notify_new`) can be nil if the conversation
  # was GC'd between insert and here; the catch-all `notify_*` clauses degrade it to a
  # title-less DM.
  defp notify_payload(%{sender: %User{} = sender} = message, conv) do
    %{
      conversation_id: message.conversation_id,
      message_id: message.id,
      root_id: message.root_id,
      channel_id: conv && conv.channel_id,
      kind: notify_kind(conv),
      conv_title: notify_title(conv),
      sender_id: message.sender_id,
      sender_name: sender.display_name,
      avatar_key: sender.avatar_key,
      preview: notify_preview(message.body),
      media_kind: notify_media_kind(message)
    }
  end

  defp notify_kind(%{channel_id: cid}) when not is_nil(cid), do: "room"
  defp notify_kind(%{is_group: true}), do: "group"
  defp notify_kind(_), do: "dm"

  defp notify_title(%{channel_id: cid} = conv) when not is_nil(cid), do: conv.name
  defp notify_title(%{is_group: true} = conv), do: conv.title
  defp notify_title(_), do: nil

  defp notify_media_kind(%{attachments: [%{kind: kind} | _]}), do: kind
  defp notify_media_kind(_), do: nil

  # Bound the body for the notification payload (#273): it fans out to every recipient
  # over PubSub, so a 10 KB message shouldn't ride whole. This is a generous SIZE guard,
  # not the display length — markdown is stripped and the text fitted to the banner on the
  # RECEIVING side (`EdenWeb.Markup` is a web module, unavailable here). Stripping happens
  # BEFORE the final display cut, so a mid-token slice can't leave a dangling `**` in the
  # banner (#279 review); the 500 here just keeps a marker pair intact for the strip.
  defp notify_preview(nil), do: ""
  defp notify_preview(body), do: String.slice(body, 0, 500)

  defp topic(conversation_id), do: "conversation:#{conversation_id}"
  defp user_topic(user_id), do: "user:#{user_id}:chat"

  ## Internals

  # Keep only ids that map to a real, non-deleted (#303) user, preserving order — a forged /
  # stale / anonymized id can't be pulled into a new conversation (deletion is terminal).
  defp reachable_user_ids([]), do: []

  defp reachable_user_ids(ids) do
    valid =
      from(u in User, where: u.id in ^ids and is_nil(u.deleted_at), select: u.id)
      |> Repo.all()
      |> MapSet.new()

    Enum.filter(ids, &MapSet.member?(valid, &1))
  end

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
  defp safe_id(id), do: Eden.Ids.normalize(id)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # Touch the conversation, preload, and fan out the new message.
  defp deliver(conversation_id, message) do
    touch_conversation(conversation_id, message.inserted_at)
    resurface_direct(conversation_id)
    # forwarded_from must be loaded too: a NotLoaded assoc is truthy, and the
    # bubble would phantom-render its "Forwarded" label on realtime messages.
    # (`@message_preloads` also satisfies notify_payload's `:sender` contract.)
    message = Repo.preload(message, @message_preloads)

    broadcast(conversation_id, {:new_message, message})
    notify_members(conversation_id)
    notify_new(message)
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
          m.conversation_id == ^conversation_id and not is_nil(m.left_at) and
            c.is_group == false and is_nil(c.channel_id)
      ),
      set: [left_at: nil]
    )
  end

  defp insert_album_message(
         user,
         conversation_id,
         message_attrs,
         prepared,
         reply_to_id,
         root_id,
         group_id
       ) do
    Repo.transact(fn ->
      with {:ok, message} <-
             %Message{
               conversation_id: conversation_id,
               sender_id: user.id,
               root_id: root_id,
               reply_to_id: reply_to_id,
               # Server-set (never cast): the file-group tie (TG-attachments); nil for albums.
               group_id: group_id
             }
             |> Message.photo_changeset(message_attrs)
             |> Repo.insert(),
           :ok <- insert_attachments(message.id, prepared) do
        {:ok, Repo.preload(message, :attachments)}
      end
    end)
  end

  defp insert_attachments(message_id, prepared) do
    Enum.reduce_while(prepared, :ok, fn attrs, :ok ->
      %Attachment{message_id: message_id}
      |> Attachment.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, _attachment} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
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
        preload: [:sender, :attachments, reactions: :user]
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

  # Strict `<`: the cap is the first REJECTED value, matching Images.check_pixels (#238).
  defp guard_dimensions(width, height) when width * height < @max_source_pixels, do: :ok
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
        message =
          Repo.preload(message, [
            :sender,
            :attachments,
            reactions: :user,
            reply_to: [:sender, :attachments],
            forwarded_from: :sender
          ])

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

  # ISO base media: the "ftyp" box sits at offset 4, the major brand at offset 8.
  # HEIC/HEIF images share this container with mp4/m4v/mov video — disambiguate by
  # the major brand so an iPhone .heic isn't stored as a (broken) video (#123).
  # Anything not a known HEIC brand stays video (the prior default), so video can
  # never be misread as an image.
  defp sniff(<<_::binary-size(4), "ftyp", brand::binary-size(4), _::binary>>, _f) do
    if brand in ~w(heic heix heim heis hevc hevx hevm hevs mif1 msf1 heif),
      do: {"image", "image/heic", "heic"},
      else: {"video", "video/mp4", "mp4"}
  end

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

  # Transcode a HEIC/HEIF original to JPEG (#123). The bundled libvips reads the
  # HEIF container but can't decode HEVC (no decoder ships with it), and the distro
  # ffmpeg is too old — so we decode with `heif-convert` (libheif, in the image) to a
  # PNG (libheif applies the irot/EXIF rotation), then scale + re-encode JPEG with
  # the bundled libvips (it reads PNG fine): longest edge to #{@heic_max} (matching
  # the #97 client compression, never upscaled) + metadata stripped. The decompression
  # bomb is guarded on the decoded header, like make_thumbnail. Returns
  # `{:ok, jpeg, width, height}` | `{:error, _}` — the caller then falls back to
  # storing the original AS AN IMAGE (never the broken video the classifier produced).
  # `path` is a server-assigned upload temp file, not user input.
  # sobelow_skip ["Traversal.FileModule"]
  defp heic_to_jpeg(path) do
    png = Path.join(System.tmp_dir!(), "heic-#{System.unique_integer([:positive])}.png")

    try do
      with {:ok, _} <- run_media_cmd("heif-convert", [path, png]),
           {:ok, bytes} <- File.read(png),
           {:ok, image} <- Image.from_binary(bytes),
           :ok <- guard_dimensions(Image.width(image), Image.height(image)),
           {:ok, thumb} <-
             Vix.Vips.Operation.thumbnail_buffer(bytes, @heic_max,
               height: @heic_max,
               size: :VIPS_SIZE_DOWN
             ),
           {:ok, jpeg} <-
             Image.write(thumb, :memory,
               suffix: ".jpg",
               quality: @heic_quality,
               strip_metadata: true
             ) do
        {:ok, jpeg, Image.width(thumb), Image.height(thumb)}
      else
        # Normalize EVERY failure to {:error, _} (#123 review B1) so a partial result
        # can't fall through as an unmatched value the caller's case crashes on. The
        # caller then takes the image fallback (heif-convert missing, corrupt clip, …).
        _ -> {:error, :unprocessable}
      end
    after
      File.rm(png)
    end
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

    try do
      with {:ok, _} <- run_media_cmd("ffmpeg", args), do: read_frame(out)
    after
      # Best-effort cleanup of the extracted frame; the poster is stored separately.
      # In try/after so a raise in run_media_cmd/read_frame can't leak the temp (#238).
      File.rm(out)
    end
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
      nil -> {:error, {:unprocessable, {:cmd_unavailable, bin}}}
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
    meta = video_meta(attachment, Map.put(meta, :thumbnail_key, poster_key))

    with :ok <- Storage.put_binary(poster_key, poster_jpeg),
         {:ok, _attachment} <- update_attachment(attachment, meta) do
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
    with {:ok, _attachment} <- update_attachment(attachment, video_meta(attachment, meta)) do
      broadcast_thumbnail(attachment.message_id)
      :ok
    end
  end

  defp store_video_preview(_attachment, nil, _meta),
    do: {:error, {:unprocessable, :no_video_data}}

  # ffprobe's width/height are the ENCODED dims; the client hint (#231) is the DISPLAY
  # (rotation-applied) size the box was reserved with. Keep whichever dimension the row
  # already has so a portrait clip doesn't flip landscape and pop (#117) — the worker
  # only FILLS dims the create path left nil (legacy / create_attachment_message). Duration
  # and thumbnail_key always update.
  defp video_meta(attachment, meta) do
    meta
    |> keep_existing_dim(attachment, :width)
    |> keep_existing_dim(attachment, :height)
  end

  defp keep_existing_dim(meta, attachment, key) do
    if is_nil(Map.get(attachment, key)), do: meta, else: Map.delete(meta, key)
  end

  defp update_attachment(attachment, attrs) do
    attachment |> Attachment.changeset(attrs) |> Repo.update()
  end
end
