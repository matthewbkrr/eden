defmodule EdenWeb.AuthLiveTest do
  use EdenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "/login" do
    test "renders the login form", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/login")
      assert html =~ "Log in to eden"
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
      assert html =~ "No conversation selected"
    end
  end

  describe "/invite/:token" do
    test "renders the registration form for a valid token", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/invite/#{invite_token_fixture()}")
      assert html =~ "Join eden"
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
  end
end
