defmodule EdenWeb.LoginLiveTest do
  use EdenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "the password field has a show/hide reveal toggle (#368/R088)", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/login")
    # ed_password_field renders the .PasswordReveal hook + a reveal toggle button.
    assert html =~ "data-reveal-toggle"
    assert html =~ "PasswordReveal"
  end

  test "shows the admin-mediated recovery hint (no email self-recovery, #368/R087)", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/login")
    assert html =~ "Ask an admin to send you a reset link"
  end
end
