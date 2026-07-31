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

    test "serves the display-sized variant, not the stored master", %{
      conn: conn,
      viewer: viewer,
      target: target
    } do
      conn = conn |> log_in_user(viewer) |> get(~p"/users/#{target.id}/avatar")
      assert response(conn, 200)
      assert get_resp_header(conn, "content-type") == ["image/webp"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

      # The point of the route, not just its headers (#516): the stored blob is a 512px JPEG and
      # the largest avatar the app renders is 56 CSS px. Asserting the type alone would pass on a
      # route that transcoded the master to WebP at full size and saved nobody anything.
      {:ok, master} = Eden.Storage.read(target.avatar_key)
      served = response(conn, 200)
      assert byte_size(served) < byte_size(master)

      {:ok, image} = Image.from_binary(served)
      assert Image.width(image) == Eden.Images.avatar_width()
    end

    test "the variant is immutable for a year, the fallback is not", %{
      conn: conn,
      viewer: viewer,
      target: target
    } do
      ok = conn |> log_in_user(viewer) |> get(~p"/users/#{target.id}/avatar")
      assert get_resp_header(ok, "cache-control") == ["private, max-age=31536000, immutable"]

      # Now make the resize fail. The route still answers — an avatar must not disappear because
      # an optimization did — but it must NOT pin the 512px master for a year under the same URL:
      # the variant would start working and nobody would ever ask again (#516 review).
      :ok = Eden.Storage.put_binary(target.avatar_key, "not an image")
      Eden.Images.delete_variants(target.avatar_key)

      fallback = conn |> log_in_user(viewer) |> get(~p"/users/#{target.id}/avatar")
      assert response(fallback, 200) == "not an image"
      assert get_resp_header(fallback, "content-type") == ["image/jpeg"]
      assert get_resp_header(fallback, "cache-control") == ["no-store"]
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
