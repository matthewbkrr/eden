defmodule EdenWeb.GroupAvatarControllerTest do
  # The same authorization surface as ChannelAvatarController (member-only, existence not leaked)
  # but previously untested (#374/R046).
  use EdenWeb.ConnCase, async: true

  import Eden.AccountsFixtures

  alias Eden.Accounts.Scope
  alias Eden.Chat

  defp scope(user), do: Scope.for_user(user)

  defp real_png do
    {:ok, img} = Image.new(600, 600, color: [200, 60, 120])
    {:ok, bytes} = Image.write(img, :memory, suffix: ".png")
    path = Path.join(System.tmp_dir!(), "gav-#{System.unique_integer([:positive])}.png")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "GET /conversations/:id/avatar" do
    setup do
      alice = user_fixture(%{username: "gav_alice"})
      bob = user_fixture(%{username: "gav_bob"})

      {:ok, group} =
        Chat.create_conversation(scope(alice), [bob.id], group: true, title: "Trip")

      {:ok, group} = Chat.set_group_avatar(scope(alice), group.id, real_png())
      %{alice: alice, bob: bob, group: group}
    end

    test "serves a member the avatar JPEG with nosniff + immutable cache", %{
      conn: conn,
      bob: bob,
      group: group
    } do
      conn = conn |> log_in_user(bob) |> get(~p"/conversations/#{group.id}/avatar")
      assert response(conn, 200)
      assert get_resp_header(conn, "content-type") == ["image/jpeg"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert ["private, max-age=31536000, immutable"] = get_resp_header(conn, "cache-control")
    end

    test "404 for a group without an avatar", %{conn: conn, alice: alice, bob: bob} do
      {:ok, plain} =
        Chat.create_conversation(scope(alice), [bob.id], group: true, title: "Plain")

      conn = conn |> log_in_user(alice) |> get(~p"/conversations/#{plain.id}/avatar")
      assert response(conn, 404)
    end

    test "404 for a non-member (existence not leaked)", %{conn: conn, group: group} do
      stranger = user_fixture(%{username: "gav_stranger"})
      conn = conn |> log_in_user(stranger) |> get(~p"/conversations/#{group.id}/avatar")
      assert response(conn, 404)
    end

    test "redirects an unauthenticated request to login", %{conn: conn, group: group} do
      conn = get(conn, ~p"/conversations/#{group.id}/avatar")
      assert redirected_to(conn) == ~p"/login"
    end
  end
end
