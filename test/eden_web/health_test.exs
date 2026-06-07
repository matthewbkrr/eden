defmodule EdenWeb.HealthTest do
  use EdenWeb.ConnCase, async: true

  test "GET /healthz returns 200 ok without a session", %{conn: conn} do
    conn = get(conn, "/healthz")
    assert text_response(conn, 200) == "ok"
  end

  test "GET /healthz/ (trailing slash) also returns 200 ok", %{conn: conn} do
    conn = get(conn, "/healthz/")
    assert text_response(conn, 200) == "ok"
  end
end
