defmodule Eden.Tokens do
  @moduledoc """
  Shared single-use token machinery (#232): a URL-safe random token of which only
  the SHA-256 hash is ever stored, so a leak of the storing table exposes nothing
  usable. Used by every hash-at-rest token flow — registration invites
  (`Eden.Accounts.Invite`), channel invites (`Eden.Channels.Invite`), and
  password-reset links (`Eden.Accounts.PasswordResetToken`) — so the generate/hash
  pair lives in one place. Each caller owns its own schema + expiry / max-uses /
  `FOR UPDATE` redemption policy; this module only mints and hashes.
  """
  @token_bytes 32

  @doc "A URL-safe random token (raw; shown once, never stored)."
  def generate,
    do: @token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc "The stored form of a token (SHA-256, lowercase hex)."
  def hash(raw) when is_binary(raw),
    do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
