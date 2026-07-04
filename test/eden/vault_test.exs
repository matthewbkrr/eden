defmodule Eden.VaultTest do
  use ExUnit.Case, async: true

  alias Eden.Vault

  test "round-trips a secret" do
    secret = :crypto.strong_rand_bytes(20)
    assert {:ok, ^secret} = secret |> Vault.encrypt() |> Vault.decrypt()
  end

  test "produces a different ciphertext each time (random IV)" do
    plaintext = "same input"
    refute Vault.encrypt(plaintext) == Vault.encrypt(plaintext)
  end

  test "fails closed on a tampered blob" do
    import Bitwise
    # Flip a byte inside the GCM tag region — authentication must reject it.
    <<head::binary-size(20), b, tail::binary>> = Vault.encrypt("secret")
    assert :error = Vault.decrypt(head <> <<bxor(b, 1)>> <> tail)
  end

  test "rejects a foreign / malformed blob" do
    assert :error = Vault.decrypt("not a vault blob")
    assert :error = Vault.decrypt(<<9, 9, 9>>)
  end
end
