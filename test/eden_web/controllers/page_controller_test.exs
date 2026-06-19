defmodule EdenWeb.PageControllerTest do
  use EdenWeb.ConnCase

  test "GET / sends a signed-out visitor to the login page", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/login"
  end

  test "GET / sends a signed-in user into the messenger", %{conn: conn} do
    conn = conn |> log_in_user(user_fixture()) |> get(~p"/")
    assert redirected_to(conn) == ~p"/app"
  end
end
