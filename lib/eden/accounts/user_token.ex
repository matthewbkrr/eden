defmodule Eden.Accounts.UserToken do
  @moduledoc """
  Revocable session tokens. The raw token lives only in the signed session
  cookie; the database stores its SHA-256 hash, so a leak of the `users_tokens`
  table does not expose usable session tokens (same at-rest protection as invite
  tokens). A session is invalidated by deleting its row (logout).
  """
  use Ecto.Schema
  import Ecto.Query

  alias Eden.Accounts.UserToken

  @hash_algorithm :sha256
  @rand_size 32
  @session_validity_in_days 60

  schema "users_tokens" do
    field :token, :binary
    field :context, :string

    belongs_to :user, Eden.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "Builds a session token: returns the raw token and the struct that stores its hash."
  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    {token, %UserToken{token: hash(token), context: "session", user_id: user.id}}
  end

  @doc "Query returning the user for a non-expired session token, given the raw token."
  def verify_session_token_query(token) do
    query =
      from row in by_token_and_context_query(token, "session"),
        join: user in assoc(row, :user),
        where: row.inserted_at > ago(@session_validity_in_days, "day"),
        select: user

    {:ok, query}
  end

  @doc "Query for a stored token (given the raw token) in a context."
  def by_token_and_context_query(token, context) do
    from UserToken, where: [token: ^hash(token), context: ^context]
  end

  @doc """
  Query selecting session tokens past the validity window — the rows
  `verify_session_token_query/1` already treats as expired, for periodic pruning
  (#238). Boundary matches: `inserted_at > ago(N)` is valid, so `<=` is expired.
  """
  def expired_session_tokens_query do
    from t in UserToken,
      where: t.context == "session" and t.inserted_at <= ago(@session_validity_in_days, "day")
  end

  defp hash(token), do: :crypto.hash(@hash_algorithm, token)
end
