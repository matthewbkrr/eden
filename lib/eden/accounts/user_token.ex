defmodule Eden.Accounts.UserToken do
  @moduledoc """
  Revocable session tokens, persisted so a session can be invalidated server-side
  (logout, "sign out everywhere"). The raw token is high-entropy random bytes; the
  same value lives in the signed session cookie and in this table.
  """
  use Ecto.Schema
  import Ecto.Query

  alias Eden.Accounts.UserToken

  @rand_size 32
  @session_validity_in_days 60

  schema "users_tokens" do
    field :token, :binary
    field :context, :string

    belongs_to :user, Eden.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "Builds a new session token and the schema struct to persist."
  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    {token, %UserToken{token: token, context: "session", user_id: user.id}}
  end

  @doc "Query returning the user for a non-expired session token."
  def verify_session_token_query(token) do
    query =
      from token in by_token_and_context_query(token, "session"),
        join: user in assoc(token, :user),
        where: token.inserted_at > ago(@session_validity_in_days, "day"),
        select: user

    {:ok, query}
  end

  @doc "Query for a token in a given context."
  def by_token_and_context_query(token, context) do
    from UserToken, where: [token: ^token, context: ^context]
  end

  @doc "Query for all of a user's tokens (used to sign out everywhere)."
  def by_user_and_contexts_query(user, :all) do
    from t in UserToken, where: t.user_id == ^user.id
  end
end
