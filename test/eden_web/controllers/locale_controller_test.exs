defmodule EdenWeb.LocaleControllerTest do
  use EdenWeb.ConnCase, async: true

  setup %{conn: conn} do
    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_private(:plug_skip_csrf_protection, true)

    {:ok, conn: conn}
  end

  test "stores a supported locale and redirects to return_to", %{conn: conn} do
    conn = post(conn, ~p"/locale", %{"locale" => "ru", "return_to" => "/settings"})

    assert redirected_to(conn) == "/settings"
    assert get_session(conn, :locale) == "ru"
  end

  test "falls back to the default for an unsupported locale", %{conn: conn} do
    conn = post(conn, ~p"/locale", %{"locale" => "de"})

    assert get_session(conn, :locale) == "en"
  end

  test "blocks open redirects via return_to", %{conn: conn} do
    conn = post(conn, ~p"/locale", %{"locale" => "en", "return_to" => "//evil.com"})

    assert redirected_to(conn) == "/settings"
  end

  test "allows a local return_to path", %{conn: conn} do
    conn = post(conn, ~p"/locale", %{"locale" => "en", "return_to" => "/some/path"})

    assert redirected_to(conn) == "/some/path"
  end
end
