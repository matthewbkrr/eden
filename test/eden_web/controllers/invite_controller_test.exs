defmodule EdenWeb.InviteControllerTest do
  use EdenWeb.ConnCase, async: true

  alias Eden.Accounts

  setup %{conn: conn} do
    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_private(:plug_skip_csrf_protection, true)

    {:ok, conn: conn}
  end

  test "a valid token creates the account, logs in, and lands on the 2FA onboarding step (#306)",
       %{conn: conn} do
    token = invite_token_fixture()

    conn =
      post(conn, ~p"/invite/#{token}", %{
        "user" => %{
          "username" => "newbie",
          "display_name" => "New",
          "password" => "password123",
          "password_confirmation" => "password123"
        }
      })

    assert get_session(conn, "user_token")
    # New users are routed through the "set up two-factor" onboarding step, not straight to /app.
    assert redirected_to(conn) == ~p"/welcome/two-factor"
    assert Accounts.get_user_by_username("newbie")
  end

  test "a mismatched password confirmation is rejected (#306)", %{conn: conn} do
    token = invite_token_fixture()

    conn =
      post(conn, ~p"/invite/#{token}", %{
        "user" => %{
          "username" => "mismatch",
          "display_name" => "M",
          "password" => "password123",
          "password_confirmation" => "different"
        }
      })

    refute get_session(conn, "user_token")
    assert redirected_to(conn) == ~p"/invite/#{token}"
    refute Accounts.get_user_by_username("mismatch")
    assert {:ok, _} = Accounts.fetch_valid_invite(token)
  end

  test "a duplicate username redirects back to the invite with a flash and no session", %{
    conn: conn
  } do
    user_fixture(%{username: "taken"})
    token = invite_token_fixture()

    conn =
      post(conn, ~p"/invite/#{token}", %{
        "user" => %{
          "username" => "taken",
          "display_name" => "Dup",
          "password" => "password123",
          "password_confirmation" => "password123"
        }
      })

    refute get_session(conn, "user_token")
    assert redirected_to(conn) == ~p"/invite/#{token}"
    assert Phoenix.Flash.get(conn.assigns.flash, :error)
    # the invite was not consumed
    assert {:ok, _} = Accounts.fetch_valid_invite(token)
  end

  test "an unknown invite redirects back to the invite page without a session", %{conn: conn} do
    conn =
      post(conn, ~p"/invite/nope", %{
        "user" => %{
          "username" => "ghost",
          "display_name" => "G",
          "password" => "password123",
          "password_confirmation" => "password123"
        }
      })

    refute get_session(conn, "user_token")
    assert redirected_to(conn) == ~p"/invite/nope"
  end
end
