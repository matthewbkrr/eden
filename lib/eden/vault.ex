defmodule Eden.Vault do
  @moduledoc """
  Symmetric encryption at rest for small secrets (#250 — the TOTP secret). AES-256-GCM
  via `:crypto`, hand-rolled in the spirit of `Eden.Storage.SigV4` (no dependency).

  The key comes from application config (`config/runtime.exs` derives it from
  `SECRET_KEY_BASE`, or a dedicated `EDEN_VAULT_KEY`) and **never touches the
  database**, so a DB leak alone can't decrypt what's stored — which is the whole
  point of encrypting a recoverable TOTP secret rather than storing it in the clear.

  Ciphertext layout: `<<version, iv::12, tag::16, ciphertext::binary>>`. The leading
  version byte + a versioned AAD leave room for key rotation later without a data
  migration guess today.
  """
  @version 1
  @aad "eden.vault.v1"
  @iv_size 12
  @tag_size 16

  @doc "Encrypts `plaintext`, returning an opaque binary safe to store."
  @spec encrypt(binary()) :: binary()
  def encrypt(plaintext) when is_binary(plaintext) do
    iv = :crypto.strong_rand_bytes(@iv_size)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, plaintext, @aad, true)

    <<@version, iv::binary, tag::binary, ciphertext::binary>>
  end

  @doc """
  Decrypts a blob produced by `encrypt/1`. Returns `{:ok, plaintext}`, or `:error`
  for a tampered/corrupt/foreign blob (GCM authentication fails closed).
  """
  @spec decrypt(binary()) :: {:ok, binary()} | :error
  def decrypt(<<@version, iv::binary-size(@iv_size), tag::binary-size(@tag_size), ct::binary>>) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, ct, @aad, tag, false) do
      :error -> :error
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
    end
  end

  def decrypt(_), do: :error

  # Normalize any configured secret to a stable 32-byte AES-256 key. The key lives
  # in env/config, never in the DB.
  defp key do
    secret = Application.fetch_env!(:eden, __MODULE__) |> Keyword.fetch!(:key)
    :crypto.hash(:sha256, secret)
  end
end
