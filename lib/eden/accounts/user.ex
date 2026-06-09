defmodule Eden.Accounts.User do
  @moduledoc """
  A person with access to eden. Identity is a unique `username` (login handle)
  plus a `display_name` shown in chat. No email — accounts are created only by
  accepting an invite (see `Eden.Accounts`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @max_bio 500

  schema "users" do
    field :username, :string
    field :display_name, :string
    field :bio, :string
    # Storage key of the processed avatar (set by Accounts.set_avatar/2), or nil.
    field :avatar_key, :string
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
    |> validate_username(opts)
    |> validate_display_name()
    |> validate_password(opts)
  end

  @doc "Changeset for editing the profile (display name + bio; no credentials)."
  def profile_changeset(user, attrs) do
    user
    # empty_values: [] so an empty bio submission is treated as "clear it" (→ nil)
    # rather than being dropped; display_name "" then fails validate_required below.
    |> cast(attrs, [:display_name, :bio], empty_values: [])
    |> validate_display_name()
    |> update_change(:bio, &normalize_bio/1)
    |> validate_length(:bio, max: @max_bio, count: :codepoints)
  end

  # Strip NUL bytes (Postgres rejects them) and trim; a blank bio becomes nil.
  defp normalize_bio(nil), do: nil

  defp normalize_bio(bio) do
    case bio |> String.replace("\0", "") |> String.trim() do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp validate_username(changeset, opts) do
    changeset =
      changeset
      |> validate_required([:username])
      |> validate_length(:username, min: 3, max: 30)
      |> validate_format(:username, ~r/^[a-z0-9_]+$/i,
        message: "only letters, numbers, and underscores"
      )
      |> unique_constraint(:username)

    # The early DB probe is for nicer messages on insert; skip it during live
    # form validation (`validate_unique: false`) to avoid a query per keystroke
    # and username enumeration on the public invite form. The unique_constraint
    # above still enforces uniqueness atomically at insert time.
    if Keyword.get(opts, :validate_unique, true) do
      unsafe_validate_unique(changeset, :username, Eden.Repo)
    else
      changeset
    end
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
