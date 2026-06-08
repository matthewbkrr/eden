defmodule EdenWeb.AvatarControllerTest do
  use EdenWeb.ConnCase, async: true

  import Eden.AccountsFixtures

  alias Eden.Accounts

  defp real_png(w \\ 600, h \\ 600) do
    {:ok, img} = Image.new(w, h, color: [10, 200, 90])
    {:ok, bytes} = Image.write(img, :memory, suffix: ".png")
    path = Path.join(System.tmp_dir!(), "av-#{System.unique_integer([:positive])}.png")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "GET /users/:id/avatar" do
    setup do
      viewer = user_fixture(%{username: "viewer"})
      target = user_fixture(%{username: "target", display_name: "Target"})
      {:ok, target} = Accounts.set_avatar(target, real_png())
      %{viewer: viewer, target: target}
    end

    test "serves an authenticated user the avatar JPEG", %{conn: conn, viewer: viewer, target: target} do
      conn = conn |> log_in_user(viewer) |> get(~p"/users/#{target.id}/avatar")
      assert response(conn, 200)
      assert get_resp_header(conn, "content-type") == ["image/jpeg"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end

    test "404 for a user without an avatar", %{conn: conn, viewer: viewer} do
      no_avatar = user_fixture(%{username: "plain"})
      conn = conn |> log_in_user(viewer) |> get(~p"/users/#{no_avatar.id}/avatar")
      assert response(conn, 404)
    end

    test "404 for an unknown user id", %{conn: conn, viewer: viewer} do
      conn = conn |> log_in_user(viewer) |> get(~p"/users/999999/avatar")
      assert response(conn, 404)
    end

    test "redirects an unauthenticated request to login", %{conn: conn, target: target} do
      conn = get(conn, ~p"/users/#{target.id}/avatar")
      assert redirected_to(conn) == ~p"/login"
    end
  end
end
