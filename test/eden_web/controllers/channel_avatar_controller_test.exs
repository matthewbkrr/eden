defmodule EdenWeb.ChannelAvatarControllerTest do
  use EdenWeb.ConnCase, async: true

  import Eden.AccountsFixtures

  alias Eden.Accounts.Scope
  alias Eden.Channels

  defp scope(user), do: Scope.for_user(user)

  defp real_png(w \\ 600, h \\ 600) do
    {:ok, img} = Image.new(w, h, color: [10, 120, 200])
    {:ok, bytes} = Image.write(img, :memory, suffix: ".png")
    path = Path.join(System.tmp_dir!(), "cav-#{System.unique_integer([:positive])}.png")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "GET /channels/:id/avatar" do
    setup do
      owner = user_fixture(%{username: "av_owner"})
      {:ok, channel} = Channels.create_channel(scope(owner), %{"name" => "Team"})
      {:ok, channel} = Channels.set_channel_avatar(scope(owner), channel.id, real_png())
      %{owner: owner, channel: channel}
    end

    test "serves a member the avatar JPEG with nosniff", %{
      conn: conn,
      owner: owner,
      channel: channel
    } do
      conn = conn |> log_in_user(owner) |> get(~p"/channels/#{channel.id}/avatar")
      assert response(conn, 200)
      assert get_resp_header(conn, "content-type") == ["image/jpeg"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end

    test "404 for a channel without an avatar", %{conn: conn, owner: owner} do
      {:ok, plain} = Channels.create_channel(scope(owner), %{"name" => "Plain"})
      conn = conn |> log_in_user(owner) |> get(~p"/channels/#{plain.id}/avatar")
      assert response(conn, 404)
    end

    test "404 for a non-member (existence not leaked)", %{conn: conn, channel: channel} do
      stranger = user_fixture(%{username: "av_stranger"})
      conn = conn |> log_in_user(stranger) |> get(~p"/channels/#{channel.id}/avatar")
      assert response(conn, 404)
    end
  end
end
