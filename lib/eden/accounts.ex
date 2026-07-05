defmodule Eden.Accounts do
  @moduledoc """
  The Accounts context: users and invite-based registration.

  There is no email/self sign-up. An account is created only by accepting a valid
  invite. Invite tokens are random 32-byte values; only their SHA-256 hash is
  stored. Acceptance is transactional and locks the invite row so concurrent
  acceptances cannot exceed `max_uses`.
  """
  import Ecto.Query, warn: false

  alias Eden.Accounts.{Invite, PasswordResetToken, Scope, User, UserToken}
  alias Eden.Repo
  alias Eden.Storage

  @pubsub Eden.PubSub
  @user_updates_topic "user_updates"

  @default_ttl_days 7
  # Admin-issued password-reset links are short-lived: handed to the user and
  # redeemed promptly (#232), unlike a multi-day registration invite.
  @reset_ttl_hours 24

  ## Users

  @doc "Fetches a user by id, raising if missing."
  def get_user!(id), do: Repo.get!(User, id)

  @doc "Fetches a user by id, or nil."
  def get_user(id), do: Repo.get(User, id)

  @doc "Fetches a user by username (case-insensitive via citext), or nil."
  def get_user_by_username(username) when is_binary(username) do
    Repo.get_by(User, username: username)
  end

  @doc "All other users (everyone except the scoped user), for the new-conversation picker."
  def list_other_users(%Scope{user: user}) do
    from(u in User, where: u.id != ^user.id, order_by: [asc: u.display_name])
    |> Repo.all()
  end

  @doc """
  Lists all users for the admin panel (#174), by display name. The caller (the
  `/admin` on_mount gate) restricts this to admins; it is not scoped itself.
  """
  def list_users do
    from(u in User, order_by: [asc: u.display_name]) |> Repo.all()
  end

  @doc "True if the user holds a platform admin role (`admin` or `super_admin`, #174)."
  def admin?(%User{} = user), do: User.admin?(user)

  @doc "True if the user is a platform `super_admin` (#174) — may assign roles."
  def super_admin?(%User{} = user), do: User.super_admin?(user)

  @doc "True unless an admin has deactivated the account (#251)."
  def active?(%User{} = user), do: User.active?(user)

  @doc """
  Sets a user's platform role (#174). **Super-admin only** — enforced here, not
  just in the UI. An actor can't change their own role (no self-lockout / no
  accidental last-super-admin demotion of self). Returns `{:ok, user}` |
  `{:error, :forbidden}` | `{:error, changeset}`; broadcasts `{:user_updated}`.
  """
  def set_user_role(%Scope{user: %User{} = actor}, %User{} = target, role) do
    if User.super_admin?(actor) do
      set_role_guarded(target, role)
    else
      {:error, :forbidden}
    end
  end

  # The one invariant that matters: the platform must never reach ZERO super_admins
  # (that would lock everyone out of admin). So the only refused move is taking the
  # LAST super_admin off the role — whether that's the actor themselves (a lone
  # super_admin can't step down) or someone else. A super_admin CAN step down or
  # demote a peer as long as another super_admin remains. `FOR UPDATE` locks the
  # super_admin set so two concurrent demotions can't both pass the check and reach
  # zero. Returns {:error, :last_super_admin} when it would.
  defp set_role_guarded(%User{} = target, role) do
    Repo.transact(fn ->
      super_ids =
        from(u in User, where: u.role == "super_admin", lock: "FOR UPDATE", select: u.id)
        |> Repo.all()

      if role != "super_admin" and target.id in super_ids and length(super_ids) <= 1 do
        {:error, :last_super_admin}
      else
        target |> User.role_changeset(%{role: role}) |> Repo.update()
      end
    end)
    |> case do
      {:ok, updated} -> {:ok, broadcast_user_update(updated)}
      other -> other
    end
  end

  @doc """
  Deactivates a user (#251, ADR-0002 Decision 8 — the manual half): sets `active =
  false` and **revokes every session**, so their live sessions are booted immediately
  (via the #256 `:sessions_revoked` signal) and they can't log back in.

  Admin-scoped, same authority as reset links (`can_reset_password?/2` — a plain admin
  can't touch a super_admin); an actor **can't deactivate themselves** (no self-lockout).
  Any outstanding reset link is dropped too, so a disabled account has no live way back
  in. Broadcasts `{:user_updated}`. Returns `{:ok, user}` | `{:error, :forbidden}`.
  """
  def deactivate_user(%Scope{user: %User{} = actor}, %User{} = target) do
    with :ok <- authorize_activation(actor, target),
         {:ok, updated} <- Repo.transact(fn -> deactivate_writes(target) end) do
      # Side effects only after the row + token deletions commit: booting live
      # sessions and refreshing open views must never fire on a rolled-back write.
      broadcast_sessions_revoked(updated.id)
      {:ok, broadcast_user_update(updated)}
    end
  end

  # The atomic DB half of a deactivation: flip active, then drop every session token
  # and any outstanding reset link in the same transaction.
  defp deactivate_writes(%User{} = target) do
    with {:ok, updated} <- set_active(target, false) do
      delete_all_session_tokens(updated.id)
      delete_reset_tokens(updated.id)
      {:ok, updated}
    end
  end

  @doc """
  Reactivates a deactivated user (#251): flips `active` back to true so login works
  again. Same authority as `deactivate_user/2`. Returns `{:ok, user}` |
  `{:error, :forbidden}`.
  """
  def reactivate_user(%Scope{user: %User{} = actor}, %User{} = target) do
    with :ok <- authorize_activation(actor, target),
         {:ok, updated} <- set_active(target, true) do
      {:ok, broadcast_user_update(updated)}
    end
  end

  # A plain admin can't touch a super_admin (mirrors reset links), and nobody
  # deactivates themselves out of their own admin session.
  defp authorize_activation(%User{} = actor, %User{} = target) do
    if actor.id != target.id and can_reset_password?(actor, target),
      do: :ok,
      else: {:error, :forbidden}
  end

  defp set_active(%User{} = user, active) when is_boolean(active),
    do: user |> Ecto.Changeset.change(active: active) |> Repo.update()

  @doc """
  Returns the user if the username/password pair is valid **and the account is active**
  (#251), otherwise nil. Always runs a hash comparison so timing does not reveal whether
  a username exists; a deactivated account is indistinguishable from a wrong password (we
  don't reveal account state).
  """
  def get_user_by_username_and_password(username, password)
      when is_binary(username) and is_binary(password) do
    user = get_user_by_username(username)
    if User.valid_password?(user, password) and User.active?(user), do: user
  end

  @doc """
  Changeset for the live registration form: does not hash the password and skips
  the unique-username DB probe (uniqueness is still enforced at insert).
  """
  def change_user_registration(attrs \\ %{}) do
    User.registration_changeset(%User{}, attrs, hash_password: false, validate_unique: false)
  end

  ## Profile

  @doc """
  Subscribes the calling process to profile changes (display name / bio / avatar)
  of any user. Identity is shown wherever a person appears, so connected views
  (e.g. the chat) subscribe and refresh on `{:user_updated, %User{}}`.
  """
  def subscribe_user_updates, do: Phoenix.PubSub.subscribe(@pubsub, @user_updates_topic)

  @doc """
  Subscribes the caller to a user's own presence-status changes (#102). Scoped
  per user (not the global `user_updates` topic) so a status change fans only to
  that user's own sessions — the multi-tab / Settings→chat sync path.
  """
  def subscribe_presence(%Scope{user: %User{id: id}}),
    do: Phoenix.PubSub.subscribe(@pubsub, presence_topic(id))

  defp presence_topic(id), do: "user:#{id}:presence"

  @doc "Changeset for the profile form (display name + bio)."
  def change_profile(%User{} = user, attrs \\ %{}), do: User.profile_changeset(user, attrs)

  @doc "Updates the user's display name and bio."
  def update_profile(%User{} = user, attrs) do
    with {:ok, updated} <- user |> User.profile_changeset(attrs) |> Repo.update() do
      {:ok, broadcast_user_update(updated)}
    end
  end

  @doc """
  Changeset for the username-rename form (#173); skips the per-keystroke DB probe
  (`validate_unique: false`) — the unique constraint still enforces it atomically on
  save, and skipping the probe avoids a query per keystroke.
  """
  def change_username(%User{} = user, attrs \\ %{}, opts \\ [validate_unique: false]),
    do: User.username_changeset(user, attrs, opts)

  @doc """
  Renames the user's `username` — the login handle and public `@tag` (#173).
  Re-validates format + uniqueness; on success broadcasts `{:user_updated, user}` so
  every view showing `@username` refreshes. Sessions survive (tokens reference the
  user id, not the name). Returns `{:ok, user}` or `{:error, changeset}`.
  """
  def update_username(%User{} = user, attrs) do
    with {:ok, updated} <- user |> User.username_changeset(attrs) |> Repo.update() do
      {:ok, broadcast_user_update(updated)}
    end
  end

  @doc "Changeset for the managed identity fields (#173) — for the admin-panel (#174) form."
  def change_managed_fields(%User{} = user, attrs \\ %{}),
    do: User.managed_changeset(user, attrs)

  @doc """
  Writes the admin-/sync-managed identity fields (#173): corp email, Должность,
  org structure, and the directory-sync seams. This is the **only** write path for
  those fields — called by the admin panel (#174) or a future sync, never by a
  user-facing form. Broadcasts `{:user_updated, user}` so open profile cards refresh.
  Returns `{:ok, user}` or `{:error, changeset}`.
  """
  def apply_managed_fields(%User{} = user, attrs) do
    with {:ok, updated} <- user |> User.managed_changeset(attrs) |> Repo.update() do
      {:ok, broadcast_user_update(updated)}
    end
  end

  @doc """
  Sets the user's manual presence status (#102) and notifies their own sessions
  on the per-user presence topic. `status` is one of `User.presence_statuses/0`;
  an invalid value returns the changeset error.
  """
  def set_presence_status(%User{} = user, status) do
    # force_change so a stale caller struct can't turn a real change into a skipped
    # no-op: ChatLive passes its `current_scope.user`, which isn't refreshed when the
    # status changes, so e.g. resetting to "auto" (the struct's original value) would
    # otherwise leave the DB on the previously-set status (#102).
    changeset =
      user
      |> User.presence_status_changeset(%{presence_status: status})
      |> Ecto.Changeset.force_change(:presence_status, status)

    with {:ok, updated} <- Repo.update(changeset) do
      Phoenix.PubSub.broadcast(
        @pubsub,
        presence_topic(updated.id),
        {:presence_status_changed, updated.presence_status}
      )

      {:ok, updated}
    end
  end

  @doc """
  Records that `user_id` was online now (#102), for the "last seen" shown to
  offline peers. `update_all` so there's no struct load. Trusts the caller to pass
  its own id (the LiveView heartbeat passes `current_scope.user.id`).
  """
  def touch_last_active(user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    User |> where([u], u.id == ^user_id) |> Repo.update_all(set: [last_active_at: now])
    :ok
  end

  @doc """
  Processes an uploaded image into a square avatar and stores it, swapping the
  user's `avatar_key` and deleting the previous blob. `source_path` is a local
  temp file. Returns `{:ok, user}` or `{:error, :too_large | :unprocessable | reason}`.
  """
  def set_avatar(%User{} = user, source_path) do
    with {:ok, jpeg} <- Eden.Images.square_avatar(source_path),
         key = Storage.build_key("avatars", "jpg"),
         :ok <- Storage.put_binary(key, jpeg),
         {:ok, updated} <- user |> Ecto.Changeset.change(avatar_key: key) |> Repo.update() do
      # Best-effort cleanup of the replaced blob (don't fail the update on it).
      if user.avatar_key, do: Storage.delete(user.avatar_key)
      {:ok, broadcast_user_update(updated)}
    end
  end

  @doc "Removes the user's avatar (and its stored blob)."
  def remove_avatar(%User{avatar_key: nil} = user), do: {:ok, user}

  def remove_avatar(%User{avatar_key: key} = user) do
    with {:ok, updated} <- user |> Ecto.Changeset.change(avatar_key: nil) |> Repo.update() do
      Storage.delete(key)
      {:ok, broadcast_user_update(updated)}
    end
  end

  defp broadcast_user_update(%User{} = user) do
    Phoenix.PubSub.broadcast(@pubsub, @user_updates_topic, {:user_updated, user})
    user
  end

  ## Session tokens

  @doc "Issues a new session token for the user and returns the raw token."
  def generate_user_session_token(%User{} = user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Returns the user for a valid, non-expired session token, or nil. A **deactivated**
  account (#251) is rejected here too — defense-in-depth beyond the token revoke, so any
  session token that outlives the revoke (or a race) still can't authenticate a request
  or LiveView mount.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)

    case Repo.one(query) do
      %User{active: true} = user -> user
      _ -> nil
    end
  end

  @doc "Deletes a session token (logout)."
  def delete_user_session_token(token) do
    Repo.delete_all(UserToken.by_token_and_context_query(token, "session"))
    :ok
  end

  @doc """
  Deletes EVERY session token for the user (#232) — used by \"log out everywhere\"
  and after any password change/reset, so a stolen cookie dies immediately.

  Deleting the tokens stops *new* mounts/requests, but an already-connected LiveView
  is only re-checked on (re)connect, so it would keep working until the socket drops
  (#256). We can't reuse the per-token `live_socket_id` disconnect — the DB holds only
  the token hash, not the raw value it's built from — so we broadcast on a per-user
  topic that every authenticated LiveView subscribes to (see `EdenWeb.UserAuth`),
  which redirects them to sign in immediately.

  `broadcast_from(self())` skips the **initiating** process: a self-service password
  change / "log out everywhere" is driven from the user's own LiveView, whose handler
  already navigates it to sign-in with a specific message — no need to also boot it
  with the generic session-ended flash. Every OTHER live session still gets booted.
  """
  def revoke_all_user_sessions(%User{} = user) do
    delete_all_session_tokens(user.id)
    broadcast_sessions_revoked(user.id)
    :ok
  end

  # The DB half of a revoke, split out so a caller that needs atomicity (deactivation)
  # can delete tokens INSIDE its transaction and fire the broadcast after commit.
  defp delete_all_session_tokens(user_id),
    do:
      Repo.delete_all(
        from t in UserToken, where: t.user_id == ^user_id and t.context == "session"
      )

  # The side-effect half — never call this inside a transaction (a rollback can't
  # un-send a broadcast; it must run only after the deletion commits).
  defp broadcast_sessions_revoked(user_id),
    do: Phoenix.PubSub.broadcast_from(@pubsub, self(), sessions_topic(user_id), :sessions_revoked)

  @doc "Subscribes a connected LiveView to its user's session-revocation signal (#256)."
  def subscribe_user_sessions(%Scope{user: %User{id: id}}),
    do: Phoenix.PubSub.subscribe(@pubsub, sessions_topic(id))

  defp sessions_topic(id), do: "user:#{id}:sessions"

  ## Passwords & resets (#232)

  @doc """
  Verifies the user's current password and sets a new one, then revokes ALL of
  their sessions (including the current one — a password change kills every login).
  Returns `{:ok, user}` | `{:error, :invalid_current_password | changeset}`.
  """
  def change_password(%User{} = user, current_password, new_password) do
    if User.valid_password?(user, current_password) do
      with {:ok, updated} <-
             user |> User.password_changeset(%{password: new_password}) |> Repo.update() do
        revoke_all_user_sessions(updated)
        # A self-chosen password kills any pending admin reset link — otherwise
        # that link stays a 24h backdoor to the account.
        delete_reset_tokens(updated.id)
        {:ok, updated}
      end
    else
      {:error, :invalid_current_password}
    end
  end

  @doc """
  Mints an admin-issued password-reset link for `target` (#232, ADR-0002 Decision
  6): stores only the hash, expires in #{@reset_ttl_hours}h, single-use. Returns
  `{:ok, raw_token}` (shown once, never stored) | `{:error, :forbidden}`.

  Authorized here, not just in the UI: the actor must be an admin, and a **plain
  admin may not reset a `super_admin`** — minting that link would let them redeem
  it and seize the account (privilege escalation). Only a super_admin resets a
  super_admin.
  """
  def create_password_reset(%Scope{user: %User{} = actor}, %User{} = target) do
    if User.admin?(actor) do
      Repo.transact(fn -> mint_reset_locked(actor, target.id) end)
    else
      {:error, :forbidden}
    end
  end

  # Re-read the target under `FOR UPDATE` (#263) so the authority guard (plain admin ↛
  # super_admin) + the #251 active check run against the FRESH row, not the in-memory struct
  # from AdminLive's list. Closes a TOCTOU where a target promoted to super_admin in the
  # sub-second before `{:user_updated}` lands could be reset by a plain admin on a stale role.
  # Mirrors `set_role_guarded/2`. The token delete + insert commit in the same transaction.
  defp mint_reset_locked(actor, target_id) do
    with %User{} = target <-
           Repo.one(from(u in User, where: u.id == ^target_id, lock: "FOR UPDATE")),
         true <- can_reset_password?(actor, target),
         true <- User.active?(target) do
      raw = Eden.Tokens.generate()

      expires_at =
        DateTime.utc_now() |> DateTime.add(@reset_ttl_hours, :hour) |> DateTime.truncate(:second)

      # One live link per person: minting supersedes any outstanding link.
      delete_reset_tokens(target.id)

      Repo.insert!(%PasswordResetToken{
        user_id: target.id,
        hashed_token: Eden.Tokens.hash(raw),
        expires_at: expires_at
      })

      {:ok, raw}
    else
      _ -> {:error, :forbidden}
    end
  end

  @doc "True if `actor` may mint a reset link for `target` (#232) — see `create_password_reset/2`."
  def can_reset_password?(%User{} = actor, %User{} = target),
    do: User.admin?(actor) and (not User.super_admin?(target) or User.super_admin?(actor))

  @doc """
  Redeems a reset link (#232): under a row lock, if the token is valid and
  unexpired, sets the new password, deletes the token (single-use), and revokes
  all the user's sessions. Returns `{:ok, user}` | `{:error, :invalid | :expired |
  changeset}`.
  """
  def reset_password_with_token(raw_token, new_password) when is_binary(raw_token) do
    hashed = Eden.Tokens.hash(raw_token)
    Repo.transact(fn -> redeem_reset(hashed, new_password) end)
  end

  @doc """
  True if a reset token is currently redeemable (exists + unexpired). A read-only
  peek for the `/reset/:token` page to show the form vs an \"expired\" state; the
  redeem path (`reset_password_with_token/2`) re-checks under a lock.
  """
  def reset_token_valid?(raw_token) when is_binary(raw_token) do
    case Repo.get_by(PasswordResetToken, hashed_token: Eden.Tokens.hash(raw_token)) do
      nil -> false
      # The SAME predicate the redeem path uses, so the peek and the redeem never
      # disagree at the exact expiry instant.
      %PasswordResetToken{} = token -> not reset_expired?(token)
    end
  end

  defp redeem_reset(hashed, new_password) do
    with %PasswordResetToken{} = token <- Repo.one(locked_reset_query(hashed)),
         false <- reset_expired?(token) do
      apply_reset(token, new_password)
    else
      nil -> {:error, :invalid}
      true -> {:error, :expired}
    end
  end

  defp locked_reset_query(hashed) do
    from(t in PasswordResetToken,
      where: t.hashed_token == ^hashed,
      lock: "FOR UPDATE",
      preload: :user
    )
  end

  defp reset_expired?(%PasswordResetToken{expires_at: at}),
    do: DateTime.after?(DateTime.utc_now(), at)

  defp apply_reset(%PasswordResetToken{} = token, new_password) do
    with {:ok, updated} <-
           token.user |> User.password_changeset(%{password: new_password}) |> Repo.update() do
      # Delete every reset token for this user, not just the redeemed one — a
      # redemption single-uses this link AND invalidates any sibling links.
      delete_reset_tokens(token.user_id)
      revoke_all_user_sessions(updated)
      {:ok, updated}
    end
  end

  defp delete_reset_tokens(user_id),
    do: Repo.delete_all(from(t in PasswordResetToken, where: t.user_id == ^user_id))

  ## TOTP two-factor auth (#250, ADR-0002 Decision 7)

  @totp_issuer "ihichat"
  @backup_code_count 10

  @doc "True if the user has an active TOTP factor (#250)."
  def totp_enrolled?(%User{} = user), do: User.totp_enrolled?(user)

  @doc """
  Begins TOTP setup: returns `{secret, otpauth_uri}` where `secret` is a fresh,
  **not-yet-persisted** secret and the URI feeds the enrollment QR. The caller (the
  Settings LiveView) holds the secret until `activate_totp/3` confirms a code from
  it, so an abandoned setup never leaves a half-enrolled account.
  """
  def setup_totp(%User{} = user) do
    secret = NimbleTOTP.secret()
    uri = NimbleTOTP.otpauth_uri("#{@totp_issuer}:#{user.username}", secret, issuer: @totp_issuer)
    {secret, uri}
  end

  @doc """
  Activates TOTP once the user proves possession with a valid `code` for `secret`
  (from `setup_totp/1`). Persists the **Vault-encrypted** secret + activation time
  and returns fresh one-time backup codes (shown once, stored only as hashes).
  Returns `{:ok, user, backup_codes}` | `{:error, :invalid_code}`.
  """
  def activate_totp(%User{} = user, secret, code) when is_binary(secret) and is_binary(code) do
    if NimbleTOTP.valid?(secret, String.trim(code)) do
      {plain_codes, hashed} = generate_backup_codes()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      changeset =
        Ecto.Changeset.change(user,
          totp_secret: Eden.Vault.encrypt(secret),
          totp_activated_at: now,
          # Burn the activation code (#263): stamp it used so the SAME code can't also pass
          # the login second factor within its ~30s window (verify_totp checks `since`).
          totp_last_used_at: now,
          totp_backup_codes: hashed
        )

      # `case`, not a `{:ok, _} =` match (#263): an unexpected write error is an error tuple,
      # not a MatchError → 500.
      case Repo.update(changeset) do
        {:ok, updated} -> {:ok, updated, plain_codes}
        {:error, _} = error -> error
      end
    else
      {:error, :invalid_code}
    end
  end

  @doc """
  Verifies a TOTP `code` for an enrolled user and stamps `totp_last_used_at` so the
  same code can't be replayed within its validity window. Returns `{:ok, user}` |
  `:error`.

  The check-and-stamp runs under a `FOR UPDATE` row lock: two concurrent logins with
  the same code serialize, and the second re-reads the freshly stamped
  `totp_last_used_at`, so `NimbleTOTP.valid?` rejects the replay (no last-write-wins
  TOCTOU).
  """
  def verify_totp(%User{id: id}, code) when is_binary(code) do
    Repo.transact(fn ->
      with %User{} = user <- lock_user(id),
           true <- User.totp_enrolled?(user),
           {:ok, secret} <- Eden.Vault.decrypt(user.totp_secret),
           true <- NimbleTOTP.valid?(secret, String.trim(code), since: user.totp_last_used_at) do
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        user |> Ecto.Changeset.change(totp_last_used_at: now) |> Repo.update()
      else
        _ -> {:error, :invalid}
      end
    end)
    |> totp_result()
  end

  @doc """
  Verifies and **consumes** a one-time backup code (recovery when the authenticator
  is unavailable). Returns `{:ok, user}` with the code removed | `:error`.

  Runs under a `FOR UPDATE` row lock so a code can't be redeemed twice by concurrent
  requests: the second sees the code already gone from the locked row.
  """
  def consume_backup_code(%User{id: id}, code) when is_binary(code) do
    hash = Eden.Tokens.hash(normalize_backup(code))

    Repo.transact(fn ->
      with %User{} = user <- lock_user(id),
           true <- hash in user.totp_backup_codes do
        remaining = List.delete(user.totp_backup_codes, hash)
        user |> Ecto.Changeset.change(totp_backup_codes: remaining) |> Repo.update()
      else
        _ -> {:error, :invalid}
      end
    end)
    |> totp_result()
  end

  defp lock_user(id), do: Repo.one(from(u in User, where: u.id == ^id, lock: "FOR UPDATE"))

  # Repo.transact unwraps {:ok, user}; collapse any error (rolled back) to :error.
  defp totp_result({:ok, %User{} = user}), do: {:ok, user}
  defp totp_result(_), do: :error

  @doc """
  Disables TOTP after the user proves possession with a valid current `code`.
  **Refused while the user holds an admin role** — an admin's second factor is
  mandatory (#250), so they can't drop it while privileged. Returns `{:ok, user}` |
  `{:error, :required_for_admin | :invalid_code}`.
  """
  def disable_totp(%User{} = user, code) when is_binary(code) do
    cond do
      User.admin?(user) -> {:error, :required_for_admin}
      match?({:ok, _}, verify_totp(user, code)) -> clear_totp(user)
      true -> {:error, :invalid_code}
    end
  end

  @doc """
  Admin recovery for a user who lost their authenticator **and** backup codes (#250):
  clears the target's TOTP so they can sign in with just their password and re-enroll.
  Same authority as reset links (`can_reset_password?/2`) — an admin, and a plain admin
  can't touch a super_admin. If the target is an admin, the `:require_admin` gate then
  makes them re-enroll before using admin power. Returns `{:ok, user}` | `{:error, :forbidden}`.
  """
  def admin_reset_totp(%Scope{user: %User{} = actor}, %User{} = target) do
    # No self-service: an admin clearing their OWN factor here would sidestep disable_totp/2's
    # admin-refusal and shed a mandatory factor. Recovery is for OTHER people.
    if actor.id == target.id do
      {:error, :forbidden}
    else
      Repo.transact(fn -> reset_totp_locked(actor, target.id) end)
    end
  end

  # Re-read the target under `FOR UPDATE` (#263) so the authority guard checks the FRESH role,
  # not the in-memory struct — same TOCTOU fix as `create_password_reset/2`.
  defp reset_totp_locked(actor, target_id) do
    with %User{} = target <-
           Repo.one(from(u in User, where: u.id == ^target_id, lock: "FOR UPDATE")),
         true <- can_reset_password?(actor, target) do
      clear_totp(target)
    else
      _ -> {:error, :forbidden}
    end
  end

  defp clear_totp(%User{} = user) do
    user
    |> Ecto.Changeset.change(
      totp_secret: nil,
      totp_activated_at: nil,
      totp_last_used_at: nil,
      totp_backup_codes: []
    )
    |> Repo.update()
  end

  # 10 codes; the plaintext is returned once for the user to save, only hashes persist.
  defp generate_backup_codes do
    plain = for _ <- 1..@backup_code_count, do: backup_code()
    hashed = Enum.map(plain, fn c -> Eden.Tokens.hash(normalize_backup(c)) end)
    {plain, hashed}
  end

  # 10 random bytes = 80 bits (#263): even unsalted SHA-256 at rest is then infeasible to
  # offline-bruteforce on a DB leak (the old 5 bytes / 40 bits fell in minutes on a GPU,
  # split across the 10 codes). 16 lowercase chars — saved once, not memorized.
  defp backup_code,
    do: :crypto.strong_rand_bytes(10) |> Base.hex_encode32(case: :lower, padding: false)

  # Normalize before hashing so display formatting / spacing / case never blocks a
  # match (hash on generation and on redemption run through the same funnel).
  defp normalize_backup(code), do: code |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")

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
  `{:error, reason}` where reason is an invite problem atom (`:invalid`,
  `:expired`, `:revoked`, `:exhausted` — same vocabulary as `fetch_valid_invite/1`)
  or a registration `%Ecto.Changeset{}`.

  The invite row is locked `FOR UPDATE` for the transaction so two people racing
  on the last use of an invite cannot both succeed.
  """
  def register_user_with_invite(raw_token, attrs) when is_binary(raw_token) do
    hashed = hash_token(raw_token)
    Repo.transact(fn -> accept_locked_invite(hashed, attrs) end)
  end

  ## Token helpers

  @doc "A URL-safe random invite token (raw; never stored). See `Eden.Tokens`."
  def build_token, do: Eden.Tokens.generate()

  @doc "The stored form of a token. See `Eden.Tokens`."
  def hash_token(raw) when is_binary(raw), do: Eden.Tokens.hash(raw)

  ## Internals

  defp accept_locked_invite(hashed, attrs) do
    case lock_invite(hashed) do
      nil ->
        {:error, :invalid}

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
