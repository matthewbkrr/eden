defmodule EdenWeb.NotifyHookTest do
  use EdenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Eden.Accounts.Scope
  alias Eden.Chat

  defp scope(user), do: Scope.for_user(user)

  setup %{conn: conn} do
    alice = user_fixture(%{username: "notify_alice"})
    bob = user_fixture(%{username: "notify_bob"})
    {:ok, dm} = Chat.create_conversation(scope(bob), [alice.id])
    %{conn: log_in_user(conn, alice), bob: bob, dm: dm}
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
end
