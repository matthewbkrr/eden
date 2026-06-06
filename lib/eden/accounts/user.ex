defmodule Eden.Accounts.User do
  @moduledoc """
  A person with access to eden. Identity is a unique `username` (login handle)
  plus a `display_name` shown in chat. No email — accounts are created only by
  accepting an invite (see `Eden.Accounts`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :username, :string
    field :display_name, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating an account (used when accepting an invite).

  Options:
    * `:hash_password` - hashes the password so it can be stored. Defaults to
      true; set to false to validate the form without hashing (e.g. live preview).
  """
  def registration_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:username, :display_name, :password])
    |> validate_username()
    |> validate_display_name()
    |> validate_password(opts)
  end

  @doc "Changeset for editing the profile (no credentials)."
  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:display_name])
    |> validate_display_name()
  end

  defp validate_username(changeset) do
    changeset
    |> validate_required([:username])
    |> validate_length(:username, min: 3, max: 30)
    |> validate_format(:username, ~r/^[a-z0-9_]+$/i,
      message: "only letters, numbers, and underscores"
    )
    |> unsafe_validate_unique(:username, Eden.Repo)
    |> unique_constraint(:username)
  end

  defp validate_display_name(changeset) do
    changeset
    |> validate_required([:display_name])
    |> validate_length(:display_name, min: 1, max: 50)
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_required([:password])
    # bcrypt truncates at 72 bytes; cap to avoid silently ignoring the tail.
    |> validate_length(:password, min: 8, max: 72, count: :bytes)
    |> maybe_hash_password(opts)
  end

  defp maybe_hash_password(changeset, opts) do
    hash_password? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash_password? && password && changeset.valid? do
      changeset
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  @doc "Verifies a password against the stored hash in constant time."
  def valid_password?(%__MODULE__{hashed_password: hashed}, password)
      when is_binary(hashed) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hashed)
  end

  def valid_password?(_user, _password) do
    # Spend the same time as a real check to avoid leaking which usernames exist.
    Bcrypt.no_user_verify()
    false
  end
end
