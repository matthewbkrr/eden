defmodule EdenWeb.NotifyHookTest do
  use EdenWeb.ConnCase, async: true

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Eden.Accounts.Scope
  alias Eden.Chat

  defp scope(user), do: Scope.for_user(user)

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
end
