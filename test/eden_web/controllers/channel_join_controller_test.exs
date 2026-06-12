defmodule EdenWeb.ChannelJoinControllerTest do
  use EdenWeb.ConnCase, async: true

  alias Eden.Accounts.Scope
  alias Eden.Channels

  defp scope(user), do: Scope.for_user(user)

  setup do
    alice = user_fixture(%{username: "alice"})
    bob = user_fixture(%{username: "bob"})
    {:ok, channel} = Channels.create_channel(scope(alice), %{"name" => "Joinable"})
    {:ok, _invite, raw} = Channels.create_invite(scope(alice), channel.id)
    %{alice: alice, bob: bob, channel: channel, raw: raw}
  end

  test "an authenticated user joins and lands in the channel", %{conn: conn} = ctx do
    conn = conn |> log_in_user(ctx.bob) |> get(~p"/channels/join/#{ctx.raw}")

    assert redirected_to(conn) == "/channels/#{ctx.channel.id}"
    assert Channels.member_role(scope(ctx.bob), ctx.channel.id) == "member"
    # Rooms materialized in the same step.
    assert {:ok, [_general]} = Channels.list_rooms(scope(ctx.bob), ctx.channel.id)
  end

  test "a private-room invite lands the user in the room (#41 PR-C2)", %{conn: conn} = ctx do
    {:ok, priv} =
      Channels.create_room(scope(ctx.alice), ctx.channel.id, %{
        "name" => "secret",
        "visibility" => "private"
      })

    {:ok, _invite, room_raw} = Channels.create_room_invite(scope(ctx.alice), priv.id)

    conn = conn |> log_in_user(ctx.bob) |> get(~p"/channels/join/#{room_raw}")

    assert redirected_to(conn) == "/channels/#{ctx.channel.id}/r/#{priv.id}"
    assert Eden.Chat.room_member?(priv.id, ctx.bob.id)
  end

  test "a signed-out visitor is sent to login and the join survives it", %{conn: conn} = ctx do
    conn = get(conn, ~p"/channels/join/#{ctx.raw}")
    assert redirected_to(conn) == "/login"

    # Log in through the real controller flow: the stored return path wins.
    conn =
      post(conn, ~p"/users/log_in", %{
        "user" => %{"username" => "bob", "password" => "password123"}
      })

    assert redirected_to(conn) == "/channels/join/#{ctx.raw}"

    conn = get(conn, ~p"/channels/join/#{ctx.raw}")
    assert redirected_to(conn) == "/channels/#{ctx.channel.id}"
  end

  test "a dead token bounces home with a flash", %{conn: conn} = ctx do
    {:ok, invite, raw} = Channels.create_invite(scope(ctx.alice), ctx.channel.id)
    :ok = Channels.revoke_invite(scope(ctx.alice), invite.id)

    conn = conn |> log_in_user(ctx.bob) |> get(~p"/channels/join/#{raw}")
    assert redirected_to(conn) == "/app"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "no longer active"
  end

  test "joining twice is idempotent", %{conn: conn} = ctx do
    conn = log_in_user(conn, ctx.bob)
    conn1 = get(conn, ~p"/channels/join/#{ctx.raw}")
    assert redirected_to(conn1) == "/channels/#{ctx.channel.id}"

    conn2 = get(conn, ~p"/channels/join/#{ctx.raw}")
    assert redirected_to(conn2) == "/channels/#{ctx.channel.id}"
  end
end
