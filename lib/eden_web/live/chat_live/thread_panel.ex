defmodule EdenWeb.ChatLive.ThreadPanel do
  @moduledoc """
  Thread-panel logic pulled out of the (very large) `EdenWeb.ChatLive` (#237, first seam).

  Threads are a corporate-room feature (#26/#57): a flat, Mattermost-style reply panel with per-user
  following + per-thread unread. These are the SELF-CONTAINED thread helpers — search, the followed-
  threads list, per-thread unread sync, the reply-typing broadcast, and the small state resets — that
  touch only the socket + the `Eden.Chat` context (no shared ChatLive privates, no render).

  `EdenWeb.ChatLive` still owns the `handle_event`/`handle_info` clauses (LiveView dispatches to the
  LiveView module) and delegates their bodies here, plus the render component (co-owned with the room
  stream via `flat_message`, so it stays until a shared component module is extracted — Step 3 of #237).
  """
  import Phoenix.Component, only: [assign: 2, assign: 3, to_form: 2]
  import Phoenix.LiveView
  use Gettext, backend: EdenWeb.Gettext

  alias Eden.Chat

  # In-thread search (#189): same nil-vs-[] convention as run_room_search.
  def run_thread_search(socket, root_id, q) do
    if String.trim(q) == "" do
      nil
    else
      Chat.search_thread(socket.assigns.current_scope, root_id, q)
    end
  end

  # Reset the in-thread search panel — on close, on opening a different thread, and
  # after jumping to a result (so the panel doesn't linger over the focused reply).
  def reset_thread_search(socket) do
    assign(socket, thread_search_open: false, thread_search: "", thread_results: nil)
  end

  # A reply arrived: bump the facepile locally (no query) — newest first, capped.
  def bump_facepile(socket, root_id, sender) do
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

  def thread_open_for?(socket, root_id) do
    match?(%{id: ^root_id}, socket.assigns.thread_root)
  end

  # The open panel's root was deleted (for both) or hidden (for me): the panel
  # would keep showing the stale root forever — close it instead.
  def close_thread_if_root_gone(socket, message_id) do
    if thread_open_for?(socket, message_id) do
      assign(socket, thread_root: nil)
    else
      socket
    end
  end

  # A thread selection is bound to the open thread — drop it when the thread opens/closes/switches
  # (a main-stream selection is left alone).
  def reset_thread_select(%{assigns: %{select_surface: :thread}} = socket),
    do: assign(socket, selection: nil, sel_delete: nil, select_surface: nil)

  def reset_thread_select(socket), do: socket

  # Set one thread's unread badge from the authoritative server state — drops the
  # key when the viewer doesn't follow. Keeps the local map in lockstep with the
  # DB across every lifecycle event (new reply, reply delete), not just guesses.
  def sync_thread_unread(socket, root_id) do
    %{following: following, unread: unread} =
      Chat.thread_follow_state(socket.assigns.current_scope, root_id)

    unreads =
      if following,
        do: Map.put(socket.assigns.thread_unreads, root_id, unread),
        else: Map.delete(socket.assigns.thread_unreads, root_id)

    assign(socket, :thread_unreads, unreads)
  end

  # #164: keep an open thread panel's root header live when the root message itself is edited
  # (it renders from @thread_root, not the :messages stream).
  def maybe_update_thread_root(socket, %{id: mid} = message) do
    case socket.assigns.thread_root do
      %{id: ^mid} -> assign(socket, thread_root: message)
      _ -> socket
    end
  end

  # Reload the Threads list panel when it's open (cheap; only while shown).
  def refresh_thread_list(socket) do
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
  def unread_thread_count(unreads), do: Enum.count(unreads, fn {_id, n} -> n > 0 end)

  # Thread-reply typing (#103): same throttle, tagged with the thread root's id so
  # receivers route it to the thread panel only. No-op without an open thread.
  def maybe_broadcast_thread_typing(%{assigns: %{selected: nil}} = socket, _body), do: socket
  def maybe_broadcast_thread_typing(%{assigns: %{thread_root: nil}} = socket, _body), do: socket

  def maybe_broadcast_thread_typing(socket, body) do
    now = System.monotonic_time(:millisecond)
    last = socket.assigns.last_thread_typing_at

    if String.trim(body) != "" and (is_nil(last) or now - last >= Chat.typing_throttle_ms()) do
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

  def clear_thread_typing(socket),
    do: assign(socket, thread_typing_users: %{}, last_thread_typing_at: nil)

  # #164: same as save_edit, for a thread reply edited in the thread composer. The
  # {:message_edited} broadcast routes the updated reply to the :thread stream.
  def save_thread_edit(socket, body) do
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

  def reset_reply_composer(socket),
    do:
      assign(socket,
        reply_composer: to_form(%{"body" => ""}, as: "reply"),
        thread_reply_to: nil,
        last_thread_typing_at: nil
      )

  # Drop any staged thread-reply attachments (#104) — on close, or when switching to a
  # different thread, so they don't bleed into the next reply.
  def cancel_staged_thread_attachments(socket) do
    Enum.reduce(socket.assigns.uploads.thread_attachment.entries, socket, fn entry, acc ->
      cancel_upload(acc, :thread_attachment, entry.ref)
    end)
  end

  # Continue/break the thread panel's compact run for a live reply (#105), mirroring the main stream's
  # last_flat logic. Threads are rooms-only, so always flat. compact?/mark_compact/restore_compact stay
  # in ChatLive (co-owned by the main flat stream); we call them there (a documented runtime two-way
  # ref — a shared MessageComponents/Compact module is the eventual cleanup, #237 step 3).
  def mark_thread_compact(socket, reply) do
    marked = %{reply | compact: EdenWeb.ChatLive.compact?(reply, socket.assigns.thread_last_flat)}
    {marked, assign(socket, thread_last_flat: {reply.sender_id, reply.inserted_at})}
  end

  # Re-stream a root ONLY when it's in the loaded message window (tracked by the `compacts` map). The
  # `:messages` stream is unbounded with manual paging, so inserting a paged-out root would resurrect
  # it out of order at the stream end.
  def restream_root_if_loaded(socket, root) do
    if Map.has_key?(socket.assigns.compacts, root.id),
      do: stream_insert(socket, :messages, EdenWeb.ChatLive.restore_compact(socket, root)),
      else: socket
  end

  # Tear down the open thread panel (composer, staged attachments, typing, search). Does NOT touch a
  # selection — callers decide (close_thread drops it, forward_selection kept the carry).
  def close_thread_panel(socket) do
    socket
    |> cancel_staged_thread_attachments()
    |> clear_thread_typing()
    |> assign(thread_root: nil, thread_reply_to: nil, thread_editing: nil)
    |> reset_thread_search()
  end

  def open_thread(socket, root_id) do
    scope = socket.assigns.current_scope

    case Chat.list_thread(scope, root_id) do
      {:ok, root, replies} ->
        # Opening a thread reads it: clear the unread (server + the local badge)
        # and surface the follow state in the header bell.
        Chat.mark_thread_read(scope, root.id)
        %{following: following} = Chat.thread_follow_state(scope, root.id)
        # Collapse consecutive same-author replies, same as the main flat stream,
        # so the panel doesn't repeat avatar+name on every reply (#105).
        {replies, thread_last_flat} =
          EdenWeb.ChatLive.mark_compact(replies, socket.assigns.selected)

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
end
