defmodule EdenWeb.UserSessionTotpTest do
  use EdenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Eden.Accounts

  defp enroll(user) do
    {secret, _uri} = Accounts.setup_totp(user)

    {:ok, user, _codes} =
      Accounts.activate_totp(user, secret, NimbleTOTP.verification_code(secret))

    {user, secret}
  end

  defp login(conn, username, password),
    do:
      post(conn, ~p"/users/log_in", %{"user" => %{"username" => username, "password" => password}})

  test "a user without TOTP logs in directly", %{conn: conn} do
    _user = user_fixture(%{username: "plainlogin", password: "password123"})
    conn = login(conn, "plainlogin", "password123")

    assert redirected_to(conn) == ~p"/app"
    assert get_session(conn, :user_token)
  end

  test "a user with TOTP is sent to the second-factor challenge, not logged in", %{conn: conn} do
    user = user_fixture(%{username: "mfauser", password: "password123"})
    {_user, _secret} = enroll(user)

    conn = login(conn, "mfauser", "password123")

    assert redirected_to(conn) == ~p"/login/totp"
    refute get_session(conn, :user_token)
    assert get_session(conn, :totp_pending_user_id)
  end

  test "a valid second-factor code completes the login", %{conn: conn} do
    user = user_fixture(%{username: "mfaok", password: "password123"})
    {_user, secret} = enroll(user)

    conn =
      conn
      |> login("mfaok", "password123")
      |> post(~p"/login/totp", %{"totp" => %{"code" => NimbleTOTP.verification_code(secret)}})

    assert redirected_to(conn) == ~p"/app"
    assert get_session(conn, :user_token)
  end

  test "a backup code also completes the login", %{conn: conn} do
    user = user_fixture(%{username: "mfabackup", password: "password123"})
    {secret, _uri} = Accounts.setup_totp(user)

    {:ok, _user, [code | _]} =
      Accounts.activate_totp(user, secret, NimbleTOTP.verification_code(secret))

    conn =
      conn
      |> login("mfabackup", "password123")
      |> post(~p"/login/totp", %{"totp" => %{"code" => code}})

    assert redirected_to(conn) == ~p"/app"
    assert get_session(conn, :user_token)
  end

  test "a wrong second-factor code bounces back to the challenge, still not logged in", %{
    conn: conn
  } do
    user = user_fixture(%{username: "mfabad", password: "password123"})
    {_user, _secret} = enroll(user)

    conn =
      conn
      |> login("mfabad", "password123")
      |> post(~p"/login/totp", %{"totp" => %{"code" => "000000"}})

    assert redirected_to(conn) == ~p"/login/totp"
    refute get_session(conn, :user_token)
  end

  test "the challenge page redirects to /login without a pending step", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/login"}}} =
             live(conn, ~p"/login/totp")
  end
end
