defmodule Eden.RateLimitTest do
  # async: the limiter is a shared global ETS table, so every test uses a UNIQUE
  # key — buckets never collide across concurrent tests.
  use ExUnit.Case, async: true

  alias Eden.RateLimit

  defp key, do: {:test, System.unique_integer([:positive])}

  test "allows up to the limit within a window, then blocks" do
    k = key()
    for _ <- 1..5, do: assert(RateLimit.hit(k, 60_000, 5) == :ok)
    assert RateLimit.hit(k, 60_000, 5) == {:error, :rate_limited}
    assert RateLimit.hit(k, 60_000, 5) == {:error, :rate_limited}
  end

  test "counts each key independently" do
    a = key()
    b = key()

    assert RateLimit.hit(a, 60_000, 1) == :ok
    assert RateLimit.hit(a, 60_000, 1) == {:error, :rate_limited}

    # b has its own bucket, untouched by a hitting its cap.
    assert RateLimit.hit(b, 60_000, 1) == :ok
  end

  test "resets once the window elapses" do
    k = key()
    scale = 100

    # Land at the START of a fresh window, so the two hits below share it with an
    # almost-full window of headroom — no wall-clock race where a boundary falls
    # between the two consecutive calls (the flaky case).
    now = System.system_time(:millisecond)
    Process.sleep(scale - rem(now, scale))

    assert RateLimit.hit(k, scale, 1) == :ok
    assert RateLimit.hit(k, scale, 1) == {:error, :rate_limited}

    # A full window later we're definitely in the next window; the count resets.
    Process.sleep(scale)
    assert RateLimit.hit(k, scale, 1) == :ok
  end
end
