defmodule EdenWeb.RateLimitTest do
  use EdenWeb.ConnCase, async: true

  alias EdenWeb.RateLimit

  # A unique remote_ip per test so the shared limiter buckets never collide across
  # concurrent tests; flash is fetched so the plug can put its error on it.
  defp fresh_conn do
    n = System.unique_integer([:positive])
    octets = {10, rem(div(n, 65_536), 256), rem(div(n, 256), 256), rem(n, 256)}

    build_conn()
    |> Map.put(:remote_ip, octets)
    |> Plug.Test.init_test_session(%{})
    |> Phoenix.Controller.fetch_flash()
  end

  test "passes through under the limit, then halts and bounces to /login" do
    opts = RateLimit.init(scope: :login, limit: 3, enabled: true)
    conn = fresh_conn()

    for _ <- 1..3, do: refute(RateLimit.call(conn, opts).halted)

    out = RateLimit.call(conn, opts)
    assert out.halted
    assert redirected_to(out) == ~p"/login"
    assert Phoenix.Flash.get(out.assigns.flash, :error) =~ "Too many attempts"
  end

  test "an over-limit invite bounces back to its own token path" do
    opts = RateLimit.init(scope: :invite, limit: 1, enabled: true)
    conn = %{fresh_conn() | request_path: "/invite/sometoken"}

    refute RateLimit.call(conn, opts).halted
    out = RateLimit.call(conn, opts)
    assert out.halted
    assert redirected_to(out) == "/invite/sometoken"
  end

  test "is a no-op when disabled (how the test env keeps the suite unthrottled)" do
    opts = RateLimit.init(scope: :login, limit: 1, enabled: false)
    conn = fresh_conn()

    refute RateLimit.call(conn, opts).halted
    refute RateLimit.call(conn, opts).halted
  end
end
