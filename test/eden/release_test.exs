defmodule Eden.ReleaseTest do
  # async: false — the reset guard reads a process-global env var.
  use ExUnit.Case, async: false

  describe "reset!/0 guard (#353)" do
    test "refuses (raises) without the EDEN_ALLOW_RESET confirmation, before touching the DB" do
      original = System.get_env("EDEN_ALLOW_RESET")
      System.delete_env("EDEN_ALLOW_RESET")

      try do
        assert_raise RuntimeError, ~r/Refusing to reset/, fn -> Eden.Release.reset!() end
      after
        if original, do: System.put_env("EDEN_ALLOW_RESET", original)
      end
    end

    test "a stray/wrong value does not arm it" do
      original = System.get_env("EDEN_ALLOW_RESET")
      System.put_env("EDEN_ALLOW_RESET", "true")

      try do
        assert_raise RuntimeError, ~r/Refusing to reset/, fn -> Eden.Release.reset!() end
      after
        if original,
          do: System.put_env("EDEN_ALLOW_RESET", original),
          else: System.delete_env("EDEN_ALLOW_RESET")
      end
    end
  end
end
