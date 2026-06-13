defmodule EdenWeb.CSPTest do
  use EdenWeb.ConnCase, async: true

  defp csp(conn), do: get_resp_header(conn, "content-security-policy") |> List.first()

  test "a browser response carries a full nonce-based policy", %{conn: conn} do
    policy = conn |> get(~p"/") |> csp()

    assert policy =~ "script-src 'self' 'nonce-"
    assert policy =~ "style-src 'self' 'unsafe-inline'"
    assert policy =~ "img-src 'self' data: blob:"
    assert policy =~ "frame-ancestors 'none'"
    assert policy =~ "object-src 'none'"
  end

  test "the nonce is fresh per request" do
    refute nonce(get(build_conn(), ~p"/")) == nonce(get(build_conn(), ~p"/"))
  end

  test "the inline script in the layout carries the request's nonce", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ ~s(<script nonce="#{nonce(conn)}">)
  end

  # Pull the script-src nonce back out of the CSP header.
  defp nonce(conn) do
    [_, nonce] = Regex.run(~r/'nonce-([^']+)'/, csp(conn))
    nonce
  end
end
