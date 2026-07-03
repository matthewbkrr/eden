defmodule Eden.Accounts do
  @moduledoc """
  The Accounts context: users and invite-based registration.

  There is no email/self sign-up. An account is created only by accepting a valid
  invite. Invite tokens are random 32-byte values; only their SHA-256 hash is
  stored. Acceptance is transactional and locks the invite row so concurrent
  acceptances cannot exceed `max_uses`.
  """
  import Ecto.Query, warn: false

  alias Eden.Accounts.{Invite, Scope, User, UserToken}
  alias Eden.Repo
  alias Eden.Storage

  @pubsub Eden.PubSub
  @user_updates_topic "user_updates"

  @token_bytes 32
  @default_ttl_days 7

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
  Returns the user if the username/password pair is valid, otherwise nil.
  Always runs a hash comparison so timing does not reveal whether a username exists.
  """
  def get_user_by_username_and_password(username, password)
      when is_binary(username) and is_binary(password) do
    user = get_user_by_username(username)
    if User.valid_password?(user, password), do: user
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
