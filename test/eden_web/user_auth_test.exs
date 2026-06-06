defmodule EdenWeb.UserAuthTest do
  use EdenWeb.ConnCase, async: true

  alias Eden.Accounts

  setup %{conn: conn} do
    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_private(:plug_skip_csrf_protection, true)

    {:ok, conn: conn}
  end

  describe "POST /users/log_in" do
    test "logs in with valid credentials and redirects to /app", %{conn: conn} do
      user_fixture(%{username: "alice", password: "password123"})

      conn =
        post(conn, ~p"/users/log_in", %{
          "user" => %{"username" => "alice", "password" => "password123"}
        })

      assert get_session(conn, "user_token")
      assert redirected_to(conn) == ~p"/app"
    end

    test "rejects invalid credentials", %{conn: conn} do
      user_fixture(%{username: "alice", password: "password123"})

      conn =
        post(conn, ~p"/users/log_in", %{
          "user" => %{"username" => "alice", "password" => "wrong"}
        })

      refute get_session(conn, "user_token")
      assert redirected_to(conn) == ~p"/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error)
    end
  end

  describe "already-authenticated users are bounced from signed-out POST routes" do
    test "POST /users/log_in redirects to /app", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())

      conn =
        post(conn, ~p"/users/log_in", %{"user" => %{"username" => "x", "password" => "y"}})

      assert redirected_to(conn) == ~p"/app"
    end

    test "POST /invite/:token redirects to /app and does not consume the invite", %{conn: conn} do
      token = invite_token_fixture()
      conn = log_in_user(conn, user_fixture())

      conn =
        post(conn, ~p"/invite/#{token}", %{
          "user" => %{"username" => "n3", "display_name" => "N", "password" => "password123"}
        })

      assert redirected_to(conn) == ~p"/app"
      assert {:ok, _} = Eden.Accounts.fetch_valid_invite(token)
    end
  end

  describe "DELETE /users/log_out" do
    test "logs out and revokes the session token server-side", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())
      token = get_session(conn, "user_token")
      assert Accounts.get_user_by_session_token(token)

      conn = delete(conn, ~p"/users/log_out")

      refute get_session(conn, "user_token")
      assert redirected_to(conn) == ~p"/"
      refute Accounts.get_user_by_session_token(token)
    end
  end
end
