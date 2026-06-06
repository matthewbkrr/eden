defmodule Eden.Accounts do
  @moduledoc """
  The Accounts context: users and invite-based registration.

  There is no email/self sign-up. An account is created only by accepting a valid
  invite. Invite tokens are random 32-byte values; only their SHA-256 hash is
  stored. Acceptance is transactional and locks the invite row so concurrent
  acceptances cannot exceed `max_uses`.
  """
  import Ecto.Query, warn: false

  alias Eden.Accounts.{Invite, User, UserToken}
  alias Eden.Repo

  @token_bytes 32
  @default_ttl_days 7

  ## Users

  @doc "Fetches a user by id, raising if missing."
  def get_user!(id), do: Repo.get!(User, id)

  @doc "Fetches a user by username (case-insensitive via citext), or nil."
  def get_user_by_username(username) when is_binary(username) do
    Repo.get_by(User, username: username)
  end

  @doc """
  Returns the user if the username/password pair is valid, otherwise nil.
  Always runs a hash comparison so timing does not reveal whether a username exists.
  """
  def get_user_by_username_and_password(username, password)
      when is_binary(username) and is_binary(password) do
    user = get_user_by_username(username)
    if User.valid_password?(user, password), do: user
  end

  @doc "Changeset for the registration form (does not hash unless told to)."
  def change_user_registration(attrs \\ %{}) do
    User.registration_changeset(%User{}, attrs, hash_password: false)
  end

  ## Session tokens

  @doc "Issues a new session token for the user and returns the raw token."
  def generate_user_session_token(%User{} = user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc "Returns the user for a valid, non-expired session token, or nil."
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc "Deletes a session token (logout)."
  def delete_user_session_token(token) do
    Repo.delete_all(UserToken.by_token_and_context_query(token, "session"))
    :ok
  end

  ## Invites

  @doc """
  Creates an invite and returns `{:ok, invite, raw_token}`. The raw token is shown
  once (in the invite URL); only its hash is persisted.

  `inviter` is a `%User{}` or `nil` (a "system" invite that bootstraps the first
  account). Options: `:max_uses` (default 1), `:expires_at` (default 7 days out).
  """
  def create_invite(inviter \\ nil, opts \\ [])

  def create_invite(inviter, opts) when is_nil(inviter) or is_struct(inviter, User) do
    raw_token = build_token()
    inviter_id = if is_struct(inviter, User), do: inviter.id

    attrs = %{
      expires_at: Keyword.get(opts, :expires_at, default_expiry()),
      max_uses: Keyword.get(opts, :max_uses, 1)
    }

    %Invite{inviter_id: inviter_id, hashed_token: hash_token(raw_token)}
    |> Invite.create_changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, invite} -> {:ok, invite, raw_token}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Returns `{:ok, invite}` if the raw token maps to a usable invite, otherwise
  `{:error, reason}` where reason is `:invalid | :expired | :revoked | :exhausted`.
  Read-only; use it to decide whether to show the acceptance form.
  """
  def fetch_valid_invite(raw_token) when is_binary(raw_token) do
    case Repo.get_by(Invite, hashed_token: hash_token(raw_token)) do
      nil -> {:error, :invalid}
      invite -> validate_invite(invite)
    end
  end

  @doc "Revokes an invite so it can no longer be accepted."
  def revoke_invite(%Invite{} = invite) do
    invite
    |> Ecto.Changeset.change(revoked_at: now())
    |> Repo.update()
  end

  ## Registration

  @doc """
  Accepts an invite and creates a user, atomically. Returns `{:ok, user}` or
  `{:error, reason}` where reason is an invite problem atom (`:invalid_invite`,
  `:expired`, `:revoked`, `:exhausted`) or a registration `%Ecto.Changeset{}`.

  The invite row is locked `FOR UPDATE` for the transaction so two people racing
  on the last use of an invite cannot both succeed.
  """
  def register_user_with_invite(raw_token, attrs) when is_binary(raw_token) do
    hashed = hash_token(raw_token)
    Repo.transact(fn -> accept_locked_invite(hashed, attrs) end)
  end

  ## Token helpers

  @doc "A URL-safe random invite token (raw; never stored)."
  def build_token,
    do: @token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc "The stored form of a token."
  def hash_token(raw) when is_binary(raw),
    do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

  ## Internals

  defp accept_locked_invite(hashed, attrs) do
    case lock_invite(hashed) do
      nil ->
        {:error, :invalid_invite}

      invite ->
        with {:ok, _invite} <- validate_invite(invite),
             {:ok, user} <- insert_user(attrs),
             {:ok, _invite} <- bump_used_count(invite) do
          {:ok, user}
        end
    end
  end

  defp insert_user(attrs) do
    %User{} |> User.registration_changeset(attrs) |> Repo.insert()
  end

  defp lock_invite(hashed) do
    Repo.one(from i in Invite, where: i.hashed_token == ^hashed, lock: "FOR UPDATE")
  end

  defp validate_invite(invite) do
    cond do
      not is_nil(invite.revoked_at) -> {:error, :revoked}
      DateTime.compare(now(), invite.expires_at) != :lt -> {:error, :expired}
      invite.used_count >= invite.max_uses -> {:error, :exhausted}
      true -> {:ok, invite}
    end
  end

  defp bump_used_count(invite) do
    invite
    |> Ecto.Changeset.change(used_count: invite.used_count + 1)
    |> Repo.update()
  end

  defp default_expiry, do: now() |> DateTime.add(@default_ttl_days, :day)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
