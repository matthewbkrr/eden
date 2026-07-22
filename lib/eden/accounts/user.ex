defmodule Eden.Accounts.User do
  @moduledoc """
  A person with access to eden. Identity is a unique `username` (login handle)
  plus a `display_name` shown in chat. No email — accounts are created only by
  accepting an invite (see `Eden.Accounts`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @max_bio 500

  # The user's chosen presence status (#102). "auto" follows the connection
  # (online when connected); "away"/"dnd" are manual; "invisible" appears offline
  # to others while staying connected. Persisted so the choice survives reconnect.
  @presence_statuses ~w(auto away dnd invisible)

  # Global platform roles (#174), lowest → highest privilege.
  @roles ~w(member admin super_admin)

  schema "users" do
    field :username, :string
    field :display_name, :string
    field :bio, :string
    # Storage key of the processed avatar (set by Accounts.set_avatar/2), or nil.
    field :avatar_key, :string
    field :presence_status, :string, default: "auto"
    # When the user last fully disconnected (#102), for "last seen" on offline peers.
    field :last_active_at, :utc_datetime

    # Global platform role (#174): member | admin | super_admin. Distinct from the
    # per-channel owner|admin|member roles; gates the admin panel. Written only via
    # role_changeset/2 (through Accounts.set_user_role/3, super-admin-restricted).
    field :role, :string, default: "member"

    # Account activation (#251, ADR-0002 Decision 8). false = an admin deactivated the
    # account: login is refused and every session is revoked, until an admin reactivates.
    # Written ONLY via Accounts.deactivate_user/2 · reactivate_user/2 (admin-scoped).
    field :active, :boolean, default: true

    # Permanent deletion by anonymization (#303). Non-nil = an admin scrubbed this
    # account's PII/credentials for good (also sets active=false). The row survives so its
    # messages stay attributed as "Deleted account"; it's filtered from rosters/pickers.
    # Irreversible — distinct from the reversible `active` flag. Written ONLY via
    # Accounts.delete_user_permanently/2.
    field :deleted_at, :utc_datetime

    # Managed identity fields (#173, RFC Phase 1): admin-/sync-owned, written ONLY
    # via managed_changeset/2 (the admin panel #174 or a future directory sync),
    # never through the user's profile form. Read-only to the person on their card.
    field :corp_email, :string
    field :position, :string
    field :structure, :string
    field :external_id, :string
    field :identity_source, :string, default: "local"
    field :managed_by, :string
    field :directory_synced_at, :utc_datetime

    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true

    # TOTP 2FA (#250, ADR-0002 Decision 7). `totp_secret` is Eden.Vault-encrypted at
    # rest; `totp_activated_at` nil = not enrolled; backup codes are hashed + single
    # use; `totp_last_used_at` blocks replay of a code inside its validity window.
    field :totp_secret, :binary, redact: true
    field :totp_activated_at, :utc_datetime
    field :totp_last_used_at, :utc_datetime
    field :totp_backup_codes, {:array, :string}, default: [], redact: true

    timestamps(type: :utc_datetime)
  end

  @doc "True if the user has an active TOTP factor (#250)."
  def totp_enrolled?(%__MODULE__{totp_activated_at: at}), do: not is_nil(at)

  @doc "The allowed manual presence statuses (#102)."
  def presence_statuses, do: @presence_statuses

  @doc "The platform roles (#174)."
  def roles, do: @roles

  @doc "True if the user holds a platform admin role (`admin` or `super_admin`, #174)."
  def admin?(%__MODULE__{role: role}), do: role in ~w(admin super_admin)

  @doc "True if the user is a `super_admin` (#174)."
  def super_admin?(%__MODULE__{role: role}), do: role == "super_admin"

  @doc "True unless an admin has deactivated the account (#251)."
  def active?(%__MODULE__{active: active}), do: active == true

  @doc "True if the account has been permanently deleted (anonymized, #303)."
  def deleted?(%__MODULE__{deleted_at: at}), do: not is_nil(at)

  @doc """
  Admin-only changeset for a user's platform role (#174). The write path
  (`Accounts.set_user_role/3`) restricts who may call it (super-admin only).
  """
  def role_changeset(user, attrs) do
    user
    |> cast(attrs, [:role])
    |> validate_required([:role])
    |> validate_inclusion(:role, @roles)
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
    # `required: true` makes "repeat password" mandatory on the registration form (#306).
    # (validate_confirmation reads the raw `password_confirmation` from params, not the
    # `:password` change, so its order relative to hashing doesn't matter — kept next to
    # the other credential validations.)
    |> validate_confirmation(:password, required: true, message: "does not match the password")
    |> validate_password(opts)
  end

  @doc """
  Changeset for setting a new password (a self-change or an admin-issued reset,
  #232) — casts and validates just the password (min 8 / max 72 bytes) and hashes
  it. Verifying any *current* password is the caller's job (`change_password/3`).
  """
  def password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:password])
    |> validate_password(opts)
    |> maybe_confirm_password(opts)
  end

  # The UI paths (change password in Settings, /reset/:token) pass a repeat field so a typo in the
  # new password is caught BEFORE it revokes every session / burns the reset link (#368) — the
  # product has no email self-recovery, so a typo would otherwise lock the user out. Programmatic
  # callers omit `:confirm` and skip it. `password_confirmation` isn't cast — validate_confirmation
  # reads it straight from the (string-keyed) params.
  defp maybe_confirm_password(changeset, opts) do
    if Keyword.get(opts, :confirm, false) do
      validate_confirmation(changeset, :password,
        required: true,
        message: "does not match the password"
      )
    else
      changeset
    end
  end

  @doc "Changeset for editing the profile (display name + bio; no credentials)."
  def profile_changeset(user, attrs) do
    user
    # empty_values: [] so an empty bio submission is treated as "clear it" (→ nil)
    # rather than being dropped; display_name "" then fails validate_required below.
    |> cast(attrs, [:display_name, :bio], empty_values: [])
    |> validate_display_name()
    |> update_change(:bio, &normalize_text/1)
    |> validate_length(:bio, max: @max_bio, count: :codepoints)
  end

  @doc """
  Changeset for renaming the login handle (#173). `username` is both the login and
  the public `@tag`, so it stays self-chosen and unique — this reuses the exact
  registration-time `validate_username/2` (format, length, uniqueness). A rename
  changes the name typed at login, but sessions survive (tokens reference the user
  id, not the name). `opts[:validate_unique]` gates the early DB probe (pass `false`
  for live per-keystroke validation).
  """
  def username_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:username])
    |> validate_username(opts)
  end

  @managed_fields ~w(corp_email position structure external_id identity_source managed_by directory_synced_at)a

  @doc """
  Admin-/sync-only changeset for the managed identity fields (#173): corp email,
  Должность (`position`), org `structure`, and the directory-sync seams. Kept
  strictly separate from `profile_changeset/2` (display_name + bio) so a user can
  never set their own managed fields through the profile form — only the admin
  panel (#174) or a future sync calls this. Text is trimmed + NUL-stripped; a blank
  clears to nil.
  """
  def managed_changeset(user, attrs) do
    user
    |> cast(attrs, @managed_fields, empty_values: [])
    |> update_change(:corp_email, &normalize_text/1)
    |> update_change(:position, &normalize_text/1)
    |> update_change(:structure, &normalize_text/1)
    |> validate_length(:corp_email, max: 160)
    |> validate_length(:position, max: 120)
    |> validate_length(:structure, max: 160)
    |> validate_format(:corp_email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "must be a valid email"
    )
    |> validate_inclusion(:identity_source, ~w(local directory ihi))
    # The remaining sync seams: bound external_id (an opaque upstream key) and
    # constrain managed_by to its documented set (RFC §2.2) so no seam is unchecked.
    |> update_change(:external_id, &normalize_text/1)
    |> validate_length(:external_id, max: 255)
    |> validate_inclusion(:managed_by, ~w(user directory admin))
  end

  @doc "Changeset for the user's manual presence status (#102); separate from the profile."
  def presence_status_changeset(user, attrs) do
    user
    |> cast(attrs, [:presence_status])
    |> validate_required([:presence_status])
    |> validate_inclusion(:presence_status, @presence_statuses)
  end

  # Strip NUL bytes (Postgres rejects them) and trim; a blank string becomes nil.
  # Shared by the free-text profile/managed fields (bio, position, structure, …).
  defp normalize_text(nil), do: nil

  defp normalize_text(text) do
    case text |> String.replace("\0", "") |> String.trim() do
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
    # Normalize FIRST (like bio/managed fields): strip NUL bytes — Postgres rejects them, so a
    # crafted `display_name` would crash update_profile / invite POST with a Postgrex.Error
    # instead of a validation error (#357/R019, same class as the #267 title fix) — and collapse
    # a whitespace-only name to nil so validate_required fails it honestly on both paths.
    |> update_change(:display_name, &normalize_text/1)
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
