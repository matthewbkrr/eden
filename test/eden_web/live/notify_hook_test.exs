defmodule EdenWeb.NotifyHookTest do
  use EdenWeb.ConnCase, async: true

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Eden.Accounts.Scope
  alias Eden.Channels
  alias Eden.Chat

  defp scope(user), do: Scope.for_user(user)

  # Force the async room selection (finish_open_room) to complete before we send: a bare live/2
  # can return before `selected` is assigned, and a notify racing that window would deliver only
  # because `selected` is momentarily nil (a test artifact, not the gate under test). render/1
  # drains the mailbox, so this is deterministic (the first pass matches); the retry is
  # belt-and-suspenders against a slow CI box, not a bare one-shot assert (#395 review).
  defp await_room_open(view) do
    matched? =
      Enum.any?(1..50, fn _ ->
        render(view) =~ "the-root-post" or (Process.sleep(10) && false)
      end)

    assert matched?, "the room's async selection never rendered (the-root-post absent)"
  end

  setup %{conn: conn} do
    alice = user_fixture(%{username: "notify_alice"})
    bob = user_fixture(%{username: "notify_bob"})
    {:ok, dm} = Chat.create_conversation(scope(bob), [alice.id])
    %{conn: log_in_user(conn, alice), alice: alice, bob: bob, dm: dm}
  end

  test "a DM delivers a notification while the only open tab is /settings (#272)", %{
    conn: conn,
    bob: bob,
    dm: dm
  } do
    {:ok, view, _} = live(conn, ~p"/settings")

    {:ok, _} = Chat.create_message(scope(bob), dm.id, %{"body" => "ping"})

    assert_push_event(view, "notify", %{conversation_id: conv_id, body: "ping"})
    assert conv_id == dm.id
  end

  test "a notification pref change re-renders the notifier host live, no reload (#363/R096)", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, ~p"/settings")
    assert html =~ ~s(data-sound="true")

    render_click(view, "set_notify_sound", %{})

    # Chat broadcasts {:notify_prefs_changed} on the notify topic; this same session (NotifyHook)
    # receives it and reassigns :notify_prefs, so the <.notifier> data-* update without a reload —
    # the R096 bug was that the toggle wrote the DB but never refreshed this host.
    assert render(view) =~ ~s(data-sound="false")
  end

  test "still delivers in ChatLive when not viewing that conversation (no regression)", %{
    conn: conn,
    bob: bob,
    dm: dm
  } do
    # On /app (conversation list, nothing selected) → not focused → notifies.
    {:ok, view, _} = live(conn, ~p"/app")

    {:ok, _} = Chat.create_message(scope(bob), dm.id, %{"body" => "hey"})

    assert_push_event(view, "notify", %{conversation_id: conv_id})
    assert conv_id == dm.id
  end

  test "a room message delivers on /settings — channel-mute is server-side (#271, closes #272 deferral)",
       %{conn: conn, alice: alice, bob: bob} do
    {:ok, channel} = Channels.create_channel(scope(bob), %{"name" => "Team"})
    {:ok, room} = Channels.create_room(scope(bob), channel.id, %{"name" => "talk"})
    {:ok, _} = Channels.ensure_member(scope(alice), channel.id)
    :ok = Chat.join_room(room.id, alice.id)

    # Only /settings open (no rail data). Before #271 the web layer suppressed room
    # notifs here; now an unmuted channel's recipients are chosen server-side, so it lands.
    {:ok, view, _} = live(conn, ~p"/settings")
    {:ok, _} = Chat.create_message(scope(bob), room.id, %{"body" => "room ping"})

    assert_push_event(view, "notify", %{conversation_id: conv_id, kind: "room"})
    assert conv_id == room.id
  end

  test "sidebar-sync chatter on the chat topic never reaches a non-chat page (#272 review)", %{
    conn: conn,
    alice: alice
  } do
    {:ok, view, _} = live(conn, ~p"/settings")

    # NotifyHook subscribes to the DEDICATED :notify topic, not the full chat topic — so a
    # folder/activity event that fans out to every session must NOT reach Settings (which
    # has no handle_info for it). Before #272's dedicated topic, it did, logging an
    # "Unhandled message" warning on every folder change while any Settings tab was open.
    log =
      capture_log(fn ->
        Phoenix.PubSub.broadcast(Eden.PubSub, "user:#{alice.id}:chat", :folders_changed)
        # A sync round-trip so a mis-delivered message would be processed before we assert.
        render(view)
      end)

    refute log =~ "Unhandled message"
    refute_push_event(view, "notify", %{}, 0)
  end

  describe "followed-thread reply focus (#362/R011)" do
    setup %{alice: alice, bob: bob} do
      {:ok, channel} = Channels.create_channel(scope(bob), %{"name" => "Team"})
      {:ok, room} = Channels.create_room(scope(bob), channel.id, %{"name" => "talk"})
      {:ok, _} = Channels.ensure_member(scope(alice), channel.id)
      :ok = Chat.join_room(room.id, alice.id)
      # alice authors the root, so bob's first reply pulls her in as a thread follower.
      {:ok, root} = Chat.create_message(scope(alice), room.id, %{"body" => "the-root-post"})
      %{channel: channel, room: room, root: root}
    end

    test "delivers when the room is open but this thread's panel is closed", %{
      conn: conn,
      bob: bob,
      channel: channel,
      room: room,
      root: root
    } do
      # Room selected, thread panel closed (thread_root == nil), tab visible (mount default). The
      # room being open must NOT suppress a reply that never lands in the main stream (#362).
      {:ok, view, _} = live(conn, ~p"/channels/#{channel.id}/r/#{room.id}")
      await_room_open(view)

      {:ok, _} = Chat.create_reply(scope(bob), root.id, %{"body" => "a reply"})

      assert_push_event(view, "notify", %{root_id: root_id})
      assert root_id == root.id
    end

    test "suppresses when this thread's panel is open (focused)", %{
      conn: conn,
      alice: alice,
      bob: bob,
      channel: channel,
      room: room,
      root: root
    } do
      # A reply exists so its permalink opens the thread panel (a root's own permalink doesn't).
      # alice replying also makes her a follower. Opening it sets thread_root == root, so alice
      # sees a new reply live → it must NOT also chime. The #thread-<reply> row confirms the panel.
      {:ok, reply} = Chat.create_reply(scope(alice), root.id, %{"body" => "first"})

      {:ok, view, _} = live(conn, ~p"/channels/#{channel.id}/r/#{room.id}/m/#{reply.id}")
      await_room_open(view)
      assert has_element?(view, "#thread-#{reply.id}")

      {:ok, _} = Chat.create_reply(scope(bob), root.id, %{"body" => "seen live"})

      refute_push_event(view, "notify", %{}, 100)
    end

    test "a normal room message is still suppressed when the room is open (no regression)", %{
      conn: conn,
      bob: bob,
      channel: channel,
      room: room
    } do
      {:ok, view, _} = live(conn, ~p"/channels/#{channel.id}/r/#{room.id}")
      await_room_open(view)

      {:ok, _} = Chat.create_message(scope(bob), room.id, %{"body" => "in the room"})

      refute_push_event(view, "notify", %{}, 100)
    end
  end
end
