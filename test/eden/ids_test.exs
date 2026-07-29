defmodule Eden.IdsTest do
  use ExUnit.Case, async: true

  alias Eden.Ids

  describe "normalize/1" do
    test "passes clean integers and numeric strings through" do
      assert Ids.normalize(42) == 42
      assert Ids.normalize("42") == 42
      assert Ids.normalize("0") == 0
    end

    test "rejects anything that is not a whole number" do
      for bad <- ["abc", "12abc", "", " 12", "1.5", "-", nil, :atom, 1.5, %{}] do
        assert Ids.normalize(bad) == :error, "expected :error for #{inspect(bad)}"
      end
    end

    test "rejects values outside bigint, which parse fine and then crash Postgrex (#494)" do
      # The whole point of this module is to fail BEFORE the query. A 26-digit id passes
      # Integer.parse and every "is it a number" check, then raises DBConnection.EncodeError
      # one layer deeper — the same class of crash, just harder to trace.
      assert Ids.normalize("99999999999999999999999999") == :error
      assert Ids.normalize(9_223_372_036_854_775_808) == :error
      assert Ids.normalize(-9_223_372_036_854_775_809) == :error

      # …and the boundaries themselves still pass.
      assert Ids.normalize(9_223_372_036_854_775_807) == 9_223_372_036_854_775_807
      assert Ids.normalize(-9_223_372_036_854_775_808) == -9_223_372_036_854_775_808
    end
  end
end
