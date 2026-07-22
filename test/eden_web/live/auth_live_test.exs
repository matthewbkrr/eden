defmodule EdenWeb.AuthLiveTest do
  use EdenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "/login" do
    test "renders the login form", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/login")
      assert html =~ "Log in to ihichat"
      # #153: the native-post form is phx-update="ignore" so the connect re-render can't
      # wipe credentials typed before the socket connects. (The timing race itself is only
      # reproducible in the e2e harness, which isn't in CI — this guards the mechanism.)
      assert html =~ ~s(phx-update="ignore")
      assert html =~ "_csrf_token"
    end

    test "redirects already-authenticated users to /app", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/login")
      assert path == ~p"/app"
    end
  end

  describe "/app (protected)" do
    test "redirects guests to /login", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/app")
      assert path == ~p"/login"
    end

    test "renders the chat for an authenticated user", %{conn: conn} do
      conn = log_in_user(conn, user_fixture(%{display_name: "Anna"}))
      {:ok, _view, html} = live(conn, ~p"/app")
      assert html =~ "No chat selected"
    end
  end

  describe "/invite/:token" do
    test "renders the registration form for a valid token", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/invite/#{invite_token_fixture()}")
      assert html =~ "Join ihichat"
    end

    test "shows an error for an invalid token", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/invite/nope")
      assert html =~ "Invalid invite"
    end

    test "validates the form live", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invite/#{invite_token_fixture()}")

      html =
        view
        |> form("form", user: %{username: "x", display_name: "", password: "short"})
        |> render_change()

      assert html =~ "should be at least"
    end

    test "renders the repeat-password field and a show/hide toggle (#306)", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/invite/#{invite_token_fixture()}")
      assert html =~ "Repeat password"
      assert html =~ "data-reveal-toggle"
    end

    test "flags a mismatched password confirmation live (#306)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invite/#{invite_token_fixture()}")

      html =
        view
        |> form("form",
          user: %{
            username: "newbie",
            display_name: "New",
            password: "password123",
            password_confirmation: "different"
          }
        )
        |> render_change()

      assert html =~ "does not match"
    end
  end
end
