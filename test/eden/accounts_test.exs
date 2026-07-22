defmodule Eden.AccountsTest do
  use Eden.DataCase, async: true
  use Oban.Testing, repo: Eden.Repo

  alias Eden.Accounts
  alias Eden.Accounts.{Invite, PasswordResetToken, Scope, User, UserToken}

  defp user_fixture(attrs \\ %{}) do
    base = %{
      username: "inviter#{System.unique_integer([:positive])}",
      display_name: "Inviter",
      password: "password123"
    }

    attrs = Map.merge(base, attrs)
    # Registration now requires a matching confirmation (#306); default it to the password.
    attrs = Map.put_new(attrs, :password_confirmation, attrs.password)

    {:ok, user} =
      %User{}
      |> User.registration_changeset(attrs)
      |> Repo.insert()

    user
  end

  # role isn't cast by registration_changeset (it's admin-managed, #174), so set it directly.
  defp promote(user, role), do: user |> Ecto.Changeset.change(role: role) |> Repo.update!()

  # A reset link minted by a super_admin (create_password_reset/2 is authorized).
  defp mint_reset(target) do
    {:ok, raw} =
      Accounts.create_password_reset(
        Scope.for_user(promote(user_fixture(), "super_admin")),
        target
      )

    raw
  end

  defp valid_attrs(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{username: "newbie", display_name: "New Person", password: "password123"},
        overrides
      )

    # Default a matching confirmation (#306) unless a test sets one (e.g. a mismatch case).
    Map.put_new(attrs, :password_confirmation, attrs.password)
  end

  defp past, do: DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)

  defp ctx_token(inviter) do
    {:ok, _invite, token} = Accounts.create_invite(inviter)
    token
  end

  defp real_png(w \\ 600, h \\ 600) do
    {:ok, img} = Image.new(w, h, color: [120, 80, 200])
    {:ok, bytes} = Image.write(img, :memory, suffix: ".png")
    path = Path.join(System.tmp_dir!(), "av-#{System.unique_integer([:positive])}.png")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "register_user_with_invite/2" do
    setup do
      inviter = user_fixture()
      {:ok, invite, token} = Accounts.create_invite(inviter, max_uses: 1)
      %{inviter: inviter, invite: invite, token: token}
    end

    test "creates a user with a valid invite and consumes a use", ctx do
      assert {:ok, %User{} = user} = Accounts.register_user_with_invite(ctx.token, valid_attrs())
      assert user.username == "newbie"
      assert user.display_name == "New Person"
      assert is_binary(user.hashed_password)
      refute user.password
      assert Repo.get!(Invite, ctx.invite.id).used_count == 1
    end

    test "rejects an unknown token" do
      assert {:error, :invalid} = Accounts.register_user_with_invite("nope", valid_attrs())
    end

    test "strips a NUL byte from display_name at registration (#357/R019)", ctx do
      assert {:ok, user} =
               Accounts.register_user_with_invite(
                 ctx.token,
                 valid_attrs(%{display_name: "Ne" <> <<0>> <> "o"})
               )

      assert user.display_name == "Neo"
    end

    test "rejects a whitespace-only display_name at registration (#357/R019)", ctx do
      assert {:error, %Ecto.Changeset{}} =
               Accounts.register_user_with_invite(ctx.token, valid_attrs(%{display_name: "   "}))
    end

    test "rejects a username that differs only in case (citext)", %{inviter: inviter} do
      assert {:ok, _} =
               Accounts.register_user_with_invite(
                 ctx_token(inviter),
                 valid_attrs(%{username: "Alice"})
               )

      assert {:error, %Ecto.Changeset{} = changeset} =
               Accounts.register_user_with_invite(
                 ctx_token(inviter),
                 valid_attrs(%{username: "alice"})
               )

      assert "has already been taken" in errors_on(changeset).username
    end

    test "rejects reuse of a single-use invite", ctx do
      assert {:ok, _} = Accounts.register_user_with_invite(ctx.token, valid_attrs())

      assert {:error, :exhausted} =
               Accounts.register_user_with_invite(ctx.token, valid_attrs(%{username: "second"}))
    end

    test "rejects an expired invite", %{inviter: inviter} do
      {:ok, _invite, token} = Accounts.create_invite(inviter, expires_at: past())
      assert {:error, :expired} = Accounts.register_user_with_invite(token, valid_attrs())
    end

    test "rejects a revoked invite", %{inviter: inviter} do
      {:ok, invite, token} = Accounts.create_invite(inviter)
      {:ok, _} = Accounts.revoke_invite(invite)
      assert {:error, :revoked} = Accounts.register_user_with_invite(token, valid_attrs())
    end

    test "honors a multi-use limit", %{inviter: inviter} do
      {:ok, _invite, token} = Accounts.create_invite(inviter, max_uses: 2)

      assert {:ok, _} =
               Accounts.register_user_with_invite(token, valid_attrs(%{username: "user_a"}))

      assert {:ok, _} =
               Accounts.register_user_with_invite(token, valid_attrs(%{username: "user_b"}))

      assert {:error, :exhausted} =
               Accounts.register_user_with_invite(token, valid_attrs(%{username: "user_c"}))
    end

    test "returns a changeset and does not consume the invite on invalid data", ctx do
      assert {:error, %Ecto.Changeset{}} =
               Accounts.register_user_with_invite(ctx.token, %{
                 username: "x",
                 display_name: "",
                 password: "short"
               })

      assert Repo.get!(Invite, ctx.invite.id).used_count == 0
    end

    test "rejects a mismatched password confirmation (#306)", ctx do
      assert {:error, changeset} =
               Accounts.register_user_with_invite(
                 ctx.token,
                 valid_attrs(%{password: "password123", password_confirmation: "different"})
               )

      assert "does not match the password" in errors_on(changeset).password_confirmation
      assert Repo.get!(Invite, ctx.invite.id).used_count == 0
    end

    test "requires a password confirmation (#306)", ctx do
      attrs = valid_attrs() |> Map.delete(:password_confirmation)
      assert {:error, changeset} = Accounts.register_user_with_invite(ctx.token, attrs)
      assert errors_on(changeset).password_confirmation != []
    end

    test "rejects a duplicate username", %{inviter: inviter, token: token} do
      assert {:ok, _} =
               Accounts.register_user_with_invite(token, valid_attrs(%{username: "dupe"}))

      {:ok, _invite, token2} = Accounts.create_invite(inviter)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Accounts.register_user_with_invite(token2, valid_attrs(%{username: "dupe"}))

      assert "has already been taken" in errors_on(changeset).username
    end
  end

  describe "fetch_valid_invite/1" do
    test "returns the invite for a valid token" do
      inviter = user_fixture()
      {:ok, invite, token} = Accounts.create_invite(inviter)
      assert {:ok, found} = Accounts.fetch_valid_invite(token)
      assert found.id == invite.id
    end

    test "errors for unknown and expired tokens" do
      inviter = user_fixture()
      assert {:error, :invalid} = Accounts.fetch_valid_invite("nope")

      {:ok, _invite, token} = Accounts.create_invite(inviter, expires_at: past())
      assert {:error, :expired} = Accounts.fetch_valid_invite(token)
    end

    test "the default invite is single-use and expires in ~30 minutes (#302)" do
      {:ok, invite, _token} = Accounts.create_invite(user_fixture())
      assert invite.max_uses == 1
      minutes = DateTime.diff(invite.expires_at, DateTime.utc_now(), :minute)
      assert minutes in 28..30
    end
  end

  describe "list_active_invites/0" do
    test "returns only outstanding invites, newest first, with the inviter preloaded" do
      inviter = user_fixture(%{username: "minter"})
      {:ok, live1, _} = Accounts.create_invite(inviter)
      {:ok, live2, _} = Accounts.create_invite(inviter)

      # Excluded: expired, revoked, and exhausted invites.
      {:ok, _expired, _} = Accounts.create_invite(inviter, expires_at: past())
      {:ok, revoked, _} = Accounts.create_invite(inviter)
      {:ok, _} = Accounts.revoke_invite(revoked)
      {:ok, exhausted, token} = Accounts.create_invite(inviter, max_uses: 1)

      {:ok, _user} =
        Accounts.register_user_with_invite(token, valid_attrs(%{username: "redeemer"}))

      ids = Accounts.list_active_invites() |> Enum.map(& &1.id)
      assert ids == [live2.id, live1.id]
      refute exhausted.id in ids

      assert [%{inviter: %{username: "minter"}} | _] = Accounts.list_active_invites()
    end
  end

  describe "admin-scoped invites (#302 review)" do
    test "create_invite/2 mints for an admin scope, refuses a member" do
      admin = promote(user_fixture(), "admin")

      assert {:ok, %Invite{inviter_id: id}, _token} =
               Accounts.create_invite(Scope.for_user(admin))

      assert id == admin.id

      assert {:error, :forbidden} = Accounts.create_invite(Scope.for_user(user_fixture()))
    end

    test "revoke_invite/2 is admin-only" do
      admin = promote(user_fixture(), "admin")
      {:ok, invite, _} = Accounts.create_invite(admin)

      assert {:error, :forbidden} = Accounts.revoke_invite(Scope.for_user(user_fixture()), invite)
      assert is_nil(Repo.get!(Invite, invite.id).revoked_at)

      assert {:ok, revoked} = Accounts.revoke_invite(Scope.for_user(admin), invite)
      assert revoked.revoked_at
    end

    test "deactivating a user revokes the invites they minted" do
      actor = promote(user_fixture(), "super_admin")
      inviter = promote(user_fixture(), "admin")
      {:ok, invite, _} = Accounts.create_invite(inviter)

      assert {:ok, _} = Accounts.deactivate_user(Scope.for_user(actor), inviter)
      assert Repo.get!(Invite, invite.id).revoked_at
      assert Accounts.list_active_invites() == []
    end
  end

  describe "get_user_by_username_and_password/2" do
    setup do
      inviter = user_fixture()
      {:ok, _invite, token} = Accounts.create_invite(inviter)

      {:ok, user} =
        Accounts.register_user_with_invite(
          token,
          valid_attrs(%{username: "loginuser", password: "supersecret"})
        )

      %{user: user}
    end

    test "returns the user for correct credentials", %{user: user} do
      assert %User{id: id} =
               Accounts.get_user_by_username_and_password("loginuser", "supersecret")

      assert id == user.id
    end

    test "is case-insensitive on the username", %{user: user} do
      assert %User{id: id} =
               Accounts.get_user_by_username_and_password("LoginUser", "supersecret")

      assert id == user.id
    end

    test "is nil for a wrong password" do
      refute Accounts.get_user_by_username_and_password("loginuser", "wrong")
    end

    test "is nil for an unknown username" do
      refute Accounts.get_user_by_username_and_password("ghost", "supersecret")
    end
  end

  describe "update_profile/2" do
    test "updates display name and bio (trimmed, NUL-stripped)" do
      user = user_fixture()

      assert {:ok, u} =
               Accounts.update_profile(user, %{
                 "display_name" => "Neo",
                 "bio" => " hi" <> <<0>> <> "there "
               })

      assert u.display_name == "Neo"
      assert u.bio == "hithere"
    end

    test "rejects a blank display name and an over-long bio" do
      user = user_fixture()
      assert {:error, %Ecto.Changeset{}} = Accounts.update_profile(user, %{"display_name" => ""})

      assert {:error, %Ecto.Changeset{}} =
               Accounts.update_profile(user, %{"bio" => String.duplicate("x", 501)})
    end

    test "strips a NUL byte from display_name instead of crashing (#357/R019)" do
      # A crafted NUL would otherwise reach Postgres and raise Postgrex.Error (a 500), not a
      # validation error — normalize_text cleans it now, like bio/managed fields do.
      assert {:ok, u} =
               Accounts.update_profile(user_fixture(), %{"display_name" => "Ne" <> <<0>> <> "o"})

      assert u.display_name == "Neo"
    end

    test "rejects a whitespace-only display_name (#357/R019)" do
      assert {:error, %Ecto.Changeset{}} =
               Accounts.update_profile(user_fixture(), %{"display_name" => "   "})
    end

    test "an empty bio clears it to nil" do
      {:ok, user} = Accounts.update_profile(user_fixture(), %{"bio" => "something"})
      assert {:ok, cleared} = Accounts.update_profile(user, %{"bio" => "   "})
      assert cleared.bio == nil
    end

    test "broadcasts the change to subscribers" do
      user = user_fixture()
      :ok = Accounts.subscribe_user_updates()

      {:ok, updated} = Accounts.update_profile(user, %{"display_name" => "Renamed"})

      assert_receive {:user_updated, %User{id: id, display_name: "Renamed"}}
      assert id == updated.id
    end

    test "cannot set managed identity fields through the profile form (#173)" do
      user = user_fixture()

      # A user submitting managed keys via the profile changeset must not touch them.
      assert {:ok, u} =
               Accounts.update_profile(user, %{
                 "display_name" => "Ok",
                 "corp_email" => "evil@corp.ru",
                 "position" => "CEO",
                 "identity_source" => "directory"
               })

      assert u.corp_email == nil
      assert u.position == nil
      assert u.identity_source == "local"
    end
  end

  describe "update_username/2 (#173)" do
    test "renames the login handle and broadcasts" do
      user = user_fixture(%{username: "old_name"})
      :ok = Accounts.subscribe_user_updates()

      assert {:ok, u} = Accounts.update_username(user, %{"username" => "new_name"})
      assert u.username == "new_name"
      assert_receive {:user_updated, %User{username: "new_name"}}

      # The rename is the login now.
      assert %User{} = Accounts.get_user_by_username_and_password("new_name", "password123")
      assert Accounts.get_user_by_username_and_password("old_name", "password123") == nil
    end

    test "rejects a taken username and a malformed one" do
      _taken = user_fixture(%{username: "taken_one"})
      user = user_fixture(%{username: "mover"})

      assert {:error, %Ecto.Changeset{}} =
               Accounts.update_username(user, %{"username" => "taken_one"})

      assert {:error, %Ecto.Changeset{}} =
               Accounts.update_username(user, %{"username" => "bad name!"})
    end

    test "renaming to the same username is a no-op, not a false collision" do
      user = user_fixture(%{username: "samename"})
      assert {:ok, u} = Accounts.update_username(user, %{"username" => "samename"})
      assert u.username == "samename"
    end
  end

  describe "apply_managed_fields/3 (#173, #262)" do
    setup do
      %{admin: Scope.for_user(promote(user_fixture(), "admin"))}
    end

    test "sets managed fields (trimmed, NUL-stripped) and broadcasts", %{admin: admin} do
      user = user_fixture()
      :ok = Accounts.subscribe_user_updates()

      assert {:ok, u} =
               Accounts.apply_managed_fields(admin, user, %{
                 "corp_email" => "  ivan@rwb.ru ",
                 "position" => " Руководитель" <> <<0>> <> " блока ",
                 "structure" => "ЦФО • Склад Обухово",
                 "identity_source" => "directory",
                 "managed_by" => "admin"
               })

      assert u.corp_email == "ivan@rwb.ru"
      assert u.position == "Руководитель блока"
      assert u.structure == "ЦФО • Склад Обухово"
      assert u.identity_source == "directory"
      assert u.managed_by == "admin"
      assert_receive {:user_updated, %User{corp_email: "ivan@rwb.ru"}}
    end

    test "rejects a malformed corp email and an unknown identity_source", %{admin: admin} do
      user = user_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Accounts.apply_managed_fields(admin, user, %{"corp_email" => "not-an-email"})

      assert {:error, %Ecto.Changeset{}} =
               Accounts.apply_managed_fields(admin, user, %{"identity_source" => "martian"})
    end

    test "bounds external_id and constrains managed_by (the remaining seams)", %{admin: admin} do
      user = user_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Accounts.apply_managed_fields(admin, user, %{
                 "external_id" => String.duplicate("x", 256)
               })

      assert {:error, %Ecto.Changeset{}} =
               Accounts.apply_managed_fields(admin, user, %{"managed_by" => "the_wind"})

      assert {:ok, u} = Accounts.apply_managed_fields(admin, user, %{"managed_by" => "directory"})
      assert u.managed_by == "directory"
    end

    test "a blank managed field clears to nil", %{admin: admin} do
      {:ok, user} =
        Accounts.apply_managed_fields(admin, user_fixture(), %{"position" => "Analyst"})

      assert {:ok, cleared} = Accounts.apply_managed_fields(admin, user, %{"position" => "  "})
      assert cleared.position == nil
    end

    test "a non-admin actor is refused (authz is in the context, not web-only) — #262" do
      member = Scope.for_user(user_fixture())

      assert {:error, :forbidden} =
               Accounts.apply_managed_fields(member, user_fixture(), %{"position" => "Nope"})

      # A super_admin is also an admin, so it's allowed.
      super_admin = Scope.for_user(promote(user_fixture(), "super_admin"))

      assert {:ok, _} =
               Accounts.apply_managed_fields(super_admin, user_fixture(), %{"position" => "Ok"})
    end

    test "refuses a permanently-deleted target and leaves the scrubbed row untouched (#357/R018)",
         %{admin: admin} do
      super_scope = Scope.for_user(promote(user_fixture(), "super_admin"))
      target = user_fixture()
      {:ok, deleted} = Accounts.delete_user_permanently(super_scope, target)

      assert {:error, :already_deleted} =
               Accounts.apply_managed_fields(admin, deleted, %{"corp_email" => "back@corp.ru"})

      # The anonymized row keeps its scrubbed (nil) PII — no write landed on the deleted account.
      assert Repo.get!(User, target.id).corp_email == nil
    end
  end

  describe "platform roles / set_user_role/3 (#174)" do
    test "admin?/1 reflects the platform role" do
      assert Accounts.admin?(promote(user_fixture(), "admin"))
      assert Accounts.admin?(promote(user_fixture(), "super_admin"))
      refute Accounts.admin?(user_fixture())
    end

    test "a super_admin can change another user's role, broadcasting the change" do
      actor = promote(user_fixture(), "super_admin")
      target = user_fixture()
      :ok = Accounts.subscribe_user_updates()

      assert {:ok, updated} = Accounts.set_user_role(Scope.for_user(actor), target, "admin")
      assert updated.role == "admin"
      assert_receive {:user_updated, %User{role: "admin"}}
    end

    test "a non-super-admin cannot change roles" do
      admin = promote(user_fixture(), "admin")
      member = user_fixture()

      assert {:error, :forbidden} =
               Accounts.set_user_role(Scope.for_user(admin), user_fixture(), "admin")

      assert {:error, :forbidden} =
               Accounts.set_user_role(Scope.for_user(member), user_fixture(), "admin")
    end

    test "cannot remove the last super_admin (no admin lockout)" do
      actor = promote(user_fixture(), "super_admin")

      assert {:error, :last_super_admin} =
               Accounts.set_user_role(Scope.for_user(actor), actor, "member")

      assert Repo.get!(User, actor.id).role == "super_admin"
    end

    test "a super_admin may step down while another super_admin remains" do
      actor = promote(user_fixture(), "super_admin")
      _peer = promote(user_fixture(), "super_admin")

      assert {:ok, stepped} = Accounts.set_user_role(Scope.for_user(actor), actor, "member")
      assert stepped.role == "member"
    end

    test "a super_admin may demote a peer, then the remaining last one is protected" do
      actor = promote(user_fixture(), "super_admin")
      peer = promote(user_fixture(), "super_admin")

      assert {:ok, demoted} = Accounts.set_user_role(Scope.for_user(actor), peer, "member")
      assert demoted.role == "member"

      assert {:error, :last_super_admin} =
               Accounts.set_user_role(Scope.for_user(actor), actor, "member")
    end

    test "cannot step down while the only other super_admin is deactivated (#357/R002)" do
      actor = promote(user_fixture(), "super_admin")
      peer = promote(user_fixture(), "super_admin")

      # Deactivating the peer leaves `actor` as the only USABLE super_admin — a deactivated
      # super still carries the role but can't reach /admin, so it no longer props up the guard.
      assert {:ok, _} = Accounts.deactivate_user(Scope.for_user(actor), peer)

      # So actor can no longer step down: the two-legitimate-actions lockout is now refused
      # (before #357 this passed and drove the active super_admin count to zero).
      assert {:error, :last_super_admin} =
               Accounts.set_user_role(Scope.for_user(actor), actor, "member")

      assert Repo.get!(User, actor.id).role == "super_admin"
    end

    test "refuses a role change on a permanently-deleted target (#357/R018)" do
      actor = promote(user_fixture(), "super_admin")
      target = user_fixture()
      {:ok, deleted} = Accounts.delete_user_permanently(Scope.for_user(actor), target)

      assert {:error, :already_deleted} =
               Accounts.set_user_role(Scope.for_user(actor), deleted, "admin")

      # No privilege re-attached to the anonymized row.
      assert Repo.get!(User, target.id).role == "member"
    end

    test "rejects an unknown role" do
      actor = promote(user_fixture(), "super_admin")

      assert {:error, %Ecto.Changeset{}} =
               Accounts.set_user_role(Scope.for_user(actor), user_fixture(), "wizard")
    end

    test "list_users/0 returns every user" do
      a = user_fixture()
      b = user_fixture()
      ids = Accounts.list_users() |> Enum.map(& &1.id)
      assert a.id in ids
      assert b.id in ids
    end
  end

  describe "user deactivation / #251" do
    test "deactivation flips active, revokes sessions, and blocks login; reactivation restores it" do
      actor = promote(user_fixture(), "super_admin")
      target = user_fixture(%{username: "offboard", password: "password123"})
      token = Accounts.generate_user_session_token(target)

      assert %User{} = Accounts.get_user_by_username_and_password("offboard", "password123")
      assert %User{} = Accounts.get_user_by_session_token(token)

      assert {:ok, deactivated} = Accounts.deactivate_user(Scope.for_user(actor), target)
      refute deactivated.active
      # Every session token is gone (revoke_all_user_sessions), so the old cookie is dead.
      assert Accounts.get_user_by_session_token(token) == nil
      # And the password no longer logs in (indistinguishable from a wrong password).
      assert Accounts.get_user_by_username_and_password("offboard", "password123") == nil

      assert {:ok, reactivated} = Accounts.reactivate_user(Scope.for_user(actor), deactivated)
      assert reactivated.active
      assert %User{} = Accounts.get_user_by_username_and_password("offboard", "password123")
    end

    test "get_user_by_session_token rejects a deactivated user even if a token survives" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      # Flip active WITHOUT revoking, simulating a token that outlives the revoke.
      user |> Ecto.Changeset.change(active: false) |> Repo.update!()
      assert Accounts.get_user_by_session_token(token) == nil
    end

    test "same authority as reset links: a plain admin can't touch a super_admin, but can a member" do
      admin = promote(user_fixture(), "admin")
      super_admin = promote(user_fixture(), "super_admin")
      member = user_fixture()

      assert {:error, :forbidden} = Accounts.deactivate_user(Scope.for_user(admin), super_admin)
      assert Repo.get!(User, super_admin.id).active

      assert {:ok, deactivated} = Accounts.deactivate_user(Scope.for_user(admin), member)
      refute deactivated.active
    end

    test "an actor can't deactivate themselves (no self-lockout)" do
      actor = promote(user_fixture(), "super_admin")
      assert {:error, :forbidden} = Accounts.deactivate_user(Scope.for_user(actor), actor)
      assert Repo.get!(User, actor.id).active
    end

    test "a non-admin can't deactivate anyone" do
      member = user_fixture()

      assert {:error, :forbidden} =
               Accounts.deactivate_user(Scope.for_user(member), user_fixture())
    end

    test "deactivation drops outstanding reset links, and none can be minted while inactive" do
      actor = promote(user_fixture(), "super_admin")
      target = user_fixture()

      {:ok, _raw} = Accounts.create_password_reset(Scope.for_user(actor), target)
      assert Repo.get_by(PasswordResetToken, user_id: target.id)

      assert {:ok, _} = Accounts.deactivate_user(Scope.for_user(actor), target)
      refute Repo.get_by(PasswordResetToken, user_id: target.id)

      assert {:error, :forbidden} =
               Accounts.create_password_reset(Scope.for_user(actor), Repo.get!(User, target.id))
    end

    test "refuses to deactivate a permanently-deleted account (#357/R018)" do
      actor = promote(user_fixture(), "super_admin")
      target = user_fixture()
      {:ok, deleted} = Accounts.delete_user_permanently(Scope.for_user(actor), target)

      assert {:error, :already_deleted} = Accounts.deactivate_user(Scope.for_user(actor), deleted)
    end

    test "a deactivated user still appears in the new-conversation picker (#357/R104)" do
      actor = promote(user_fixture(), "super_admin")
      target = user_fixture()
      assert {:ok, _} = Accounts.deactivate_user(Scope.for_user(actor), target)

      # Pinned behavior: deactivation (reversible) does NOT hide someone from list_other_users.
      # Excluding deactivated accounts from pickers is deferred to #384, not silently changed here.
      other_ids = Accounts.list_other_users(Scope.for_user(actor)) |> Enum.map(& &1.id)
      assert target.id in other_ids
    end
  end

  describe "permanent deletion (anonymization) / #303" do
    test "scrubs PII, credentials, avatar and role; stamps deleted_at; keeps the row" do
      actor = promote(user_fixture(), "super_admin")

      target =
        user_fixture(%{username: "gone", display_name: "Gone Soon", password: "password123"})

      # Give them a factor + a session + fields worth scrubbing.
      {secret, _} = Accounts.setup_totp(target)

      {:ok, target, _} =
        Accounts.activate_totp(target, secret, NimbleTOTP.verification_code(secret))

      {:ok, target} =
        target
        |> Ecto.Changeset.change(
          bio: "hi",
          avatar_key: "avatars/none.jpg",
          corp_email: "g@rwb.ru",
          position: "Analyst"
        )
        |> Repo.update()

      token = Accounts.generate_user_session_token(target)

      assert {:ok, deleted} = Accounts.delete_user_permanently(Scope.for_user(actor), target)

      assert Accounts.deleted?(deleted)
      assert deleted.username == "deleted-#{target.id}"
      assert deleted.display_name == "Удалённый аккаунт"
      refute deleted.active
      assert deleted.role == "member"

      for field <- [:bio, :avatar_key, :corp_email, :position, :totp_secret] do
        assert is_nil(Map.fetch!(deleted, field)), "expected #{field} to be scrubbed"
      end

      # The password hash is replaced (NOT NULL column), so the old credential is dead.
      assert deleted.hashed_password != target.hashed_password
      refute Accounts.totp_enrolled?(deleted)

      # The row survives (messages still reference it), but every way in is dead.
      assert Repo.get(User, target.id)
      assert Accounts.get_user_by_username_and_password("gone", "password123") == nil
      assert Accounts.get_user_by_session_token(token) == nil
    end

    test "frees the @tag with no format collision — the handle can be re-registered" do
      # `deleted-<id>` carries a hyphen, which the username format forbids, so it can never
      # collide with a real handle; and the original @tag is now free.
      actor = promote(user_fixture(), "super_admin")
      target = user_fixture(%{username: "reclaim"})

      assert {:ok, _} = Accounts.delete_user_permanently(Scope.for_user(actor), target)

      {:ok, _invite, token} = Accounts.create_invite(actor)

      assert {:ok, reborn} =
               Accounts.register_user_with_invite(token, valid_attrs(%{username: "reclaim"}))

      assert reborn.username == "reclaim"
      assert reborn.id != target.id
    end

    test "drops outstanding reset links so a deleted account has no live way back in" do
      actor = promote(user_fixture(), "super_admin")
      target = user_fixture()
      {:ok, _raw} = Accounts.create_password_reset(Scope.for_user(actor), target)

      assert {:ok, _} = Accounts.delete_user_permanently(Scope.for_user(actor), target)
      refute Repo.get_by(PasswordResetToken, user_id: target.id)
    end

    test "same authority as reset links: a plain admin can't delete a super_admin" do
      admin = promote(user_fixture(), "admin")
      super_admin = promote(user_fixture(), "super_admin")

      assert {:error, :forbidden} =
               Accounts.delete_user_permanently(Scope.for_user(admin), super_admin)

      refute Accounts.deleted?(Repo.get!(User, super_admin.id))
    end

    test "an actor can't delete themselves, and a non-admin can't delete anyone" do
      actor = promote(user_fixture(), "super_admin")
      assert {:error, :forbidden} = Accounts.delete_user_permanently(Scope.for_user(actor), actor)

      member = user_fixture()

      assert {:error, :forbidden} =
               Accounts.delete_user_permanently(Scope.for_user(member), user_fixture())
    end

    test "a super_admin can be deleted while another remains (the not-last path)" do
      a = promote(user_fixture(), "super_admin")
      b = promote(user_fixture(), "super_admin")

      assert {:ok, deleted} = Accounts.delete_user_permanently(Scope.for_user(a), b)
      assert Accounts.deleted?(deleted)
      # a is untouched and still a super_admin — the guard only bites at the LAST one.
      assert Repo.get!(User, a.id).role == "super_admin"
    end

    test "deleting is idempotent-safe: a second attempt on the same person is refused" do
      actor = promote(user_fixture(), "super_admin")
      target = user_fixture()

      assert {:ok, deleted} = Accounts.delete_user_permanently(Scope.for_user(actor), target)

      assert {:error, :already_deleted} =
               Accounts.delete_user_permanently(Scope.for_user(actor), deleted)
    end

    test "a deleted account can never be reactivated (terminal, not #251-reversible)" do
      actor = promote(user_fixture(), "super_admin")
      target = user_fixture()

      assert {:ok, deleted} = Accounts.delete_user_permanently(Scope.for_user(actor), target)
      assert {:error, :forbidden} = Accounts.reactivate_user(Scope.for_user(actor), deleted)
      assert Accounts.deleted?(Repo.get!(User, target.id))
    end

    test "deleted accounts drop out of list_users/0 and the new-conversation picker" do
      actor = promote(user_fixture(), "super_admin")
      target = user_fixture(%{username: "vanish"})

      assert target.id in (Accounts.list_users() |> Enum.map(& &1.id))

      assert {:ok, _} = Accounts.delete_user_permanently(Scope.for_user(actor), target)

      refute target.id in (Accounts.list_users() |> Enum.map(& &1.id))
      other_ids = Accounts.list_other_users(Scope.for_user(actor)) |> Enum.map(& &1.id)
      refute target.id in other_ids
    end

    test "enqueues the durable cross-context scrub worker in the deletion transaction (#357/R048)" do
      actor = promote(user_fixture(), "super_admin")
      target = user_fixture()

      assert {:ok, deleted} = Accounts.delete_user_permanently(Scope.for_user(actor), target)
      assert_enqueued(worker: Eden.DeletedUserScrubWorker, args: %{user_id: deleted.id})
    end

    test "the scrub worker is idempotent — safe to run more than once (#357/R048)" do
      actor = promote(user_fixture(), "super_admin")
      target = user_fixture()
      {:ok, deleted} = Accounts.delete_user_permanently(Scope.for_user(actor), target)

      assert :ok = perform_job(Eden.DeletedUserScrubWorker, %{"user_id" => deleted.id})
      assert :ok = perform_job(Eden.DeletedUserScrubWorker, %{"user_id" => deleted.id})
    end
  end

  describe "set_presence_status/2 (#102)" do
    test "defaults to auto and persists each allowed status" do
      user = user_fixture()
      assert user.presence_status == "auto"

      # Reuse the same (now-stale) struct each time: force_change means even
      # "auto" at the end (the struct's original value) still persists rather than
      # being skipped as a no-op against the stale value.
      for status <- ~w(away dnd invisible auto) do
        assert {:ok, updated} = Accounts.set_presence_status(user, status)
        assert updated.presence_status == status
        assert Repo.get!(User, user.id).presence_status == status
      end
    end

    test "persists with a stale caller struct (force_change) — reset to auto sticks" do
      user = user_fixture()
      {:ok, _} = Accounts.set_presence_status(user, "dnd")
      # `user` is stale (still "auto"); resetting to "auto" must persist, not no-op.
      {:ok, _} = Accounts.set_presence_status(user, "auto")
      assert Repo.get!(User, user.id).presence_status == "auto"
    end

    test "rejects an unknown status" do
      user = user_fixture()
      assert {:error, %Ecto.Changeset{}} = Accounts.set_presence_status(user, "ghost")
      assert Repo.get!(User, user.id).presence_status == "auto"
    end

    test "broadcasts on the user's own presence topic, not the global one" do
      user = user_fixture()
      user_id = user.id
      scope = Eden.Accounts.Scope.for_user(user)
      :ok = Accounts.subscribe_presence(scope)
      :ok = Accounts.subscribe_user_updates()

      {:ok, _updated} = Accounts.set_presence_status(user, "dnd")

      assert_receive {:presence_status_changed, "dnd"}
      # Pin THIS user's id: async siblings broadcast :user_updated for their own
      # users on the shared global topic, which must not trip this assertion.
      refute_received {:user_updated, %User{id: ^user_id}}
    end
  end

  describe "touch_last_active/1 (#102)" do
    test "records the user's last-active time" do
      user = user_fixture()
      refute user.last_active_at

      :ok = Accounts.touch_last_active(user.id)

      assert %DateTime{} = Repo.get!(User, user.id).last_active_at
    end
  end

  describe "avatars" do
    test "set_avatar processes the image into a square JPEG and stores it" do
      assert {:ok, u} = Accounts.set_avatar(user_fixture(), real_png(1400, 500))
      assert is_binary(u.avatar_key)
      assert Eden.Storage.exists?(u.avatar_key)

      {:ok, bytes} = Eden.Storage.read(u.avatar_key)
      {:ok, img} = Image.from_binary(bytes)
      assert Image.width(img) == 512 and Image.height(img) == 512
    end

    test "replacing an avatar deletes the previous blob" do
      {:ok, u1} = Accounts.set_avatar(user_fixture(), real_png())
      old = u1.avatar_key
      assert {:ok, u2} = Accounts.set_avatar(u1, real_png())
      refute u2.avatar_key == old
      refute Eden.Storage.exists?(old)
      assert Eden.Storage.exists?(u2.avatar_key)
    end

    test "a replace via a STALE struct still reclaims the real stored blob (#385/R114)" do
      user = user_fixture()
      {:ok, u1} = Accounts.set_avatar(user, real_png())
      key1 = u1.avatar_key

      # A second upload that never observed the first — the way a concurrent second tab holds the
      # pre-avatar struct (avatar_key still nil). The old code deleted `user.avatar_key` (nil → a
      # no-op) and orphaned key1 forever; the fix reads the CURRENT key from the DB under FOR UPDATE
      # and reclaims exactly that.
      assert {:ok, u2} = Accounts.set_avatar(user, real_png())
      refute u2.avatar_key == key1

      refute Eden.Storage.exists?(key1),
             "the real previous blob (from the DB, not the stale struct) must be reclaimed"

      assert Eden.Storage.exists?(u2.avatar_key)
    end

    test "remove_avatar clears the key and deletes the blob" do
      {:ok, u} = Accounts.set_avatar(user_fixture(), real_png())
      key = u.avatar_key
      assert {:ok, cleared} = Accounts.remove_avatar(u)
      assert cleared.avatar_key == nil
      refute Eden.Storage.exists?(key)
    end

    test "rejects a non-image upload" do
      path = Path.join(System.tmp_dir!(), "notimg-#{System.unique_integer([:positive])}")
      File.write!(path, "definitely not an image")
      on_exit(fn -> File.rm(path) end)
      assert {:error, _} = Accounts.set_avatar(user_fixture(), path)
    end
  end

  describe "change_password/3 (#232)" do
    test "verifies the current password, sets a new one, and revokes every session" do
      user = user_fixture(%{username: "pwuser", password: "password123"})
      _ = Accounts.generate_user_session_token(user)
      _ = Accounts.generate_user_session_token(user)

      assert {:ok, updated} = Accounts.change_password(user, "password123", "newpassword456")
      assert User.valid_password?(updated, "newpassword456")
      refute User.valid_password?(updated, "password123")
      assert Repo.aggregate(from(t in UserToken, where: t.user_id == ^user.id), :count) == 0
    end

    test "invalidates any pending admin reset link (no 24h backdoor)" do
      user = user_fixture(%{username: "pwuser2", password: "password123"})
      raw = mint_reset(user)

      assert {:ok, _} = Accounts.change_password(user, "password123", "newpassword456")

      refute Accounts.reset_token_valid?(raw)
      assert {:error, :invalid} = Accounts.reset_password_with_token(raw, "yetanother123")
    end

    test "rejects a wrong current password" do
      user = user_fixture(%{password: "password123"})

      assert {:error, :invalid_current_password} =
               Accounts.change_password(user, "wrong-one", "newpassword456")
    end

    test "rejects a too-short new password" do
      user = user_fixture(%{password: "password123"})
      assert {:error, %Ecto.Changeset{}} = Accounts.change_password(user, "password123", "short")
    end
  end

  describe "password reset links (#232)" do
    test "mint → redeem sets the new password, is single-use, and revokes sessions" do
      user = user_fixture(%{username: "resetme", password: "password123"})
      _ = Accounts.generate_user_session_token(user)

      raw = mint_reset(user)
      assert {:ok, updated} = Accounts.reset_password_with_token(raw, "brandnewpass789")
      assert updated.id == user.id
      assert User.valid_password?(updated, "brandnewpass789")
      assert Repo.aggregate(from(t in UserToken, where: t.user_id == ^user.id), :count) == 0

      # single-use: the row is gone, a replay fails
      assert {:error, :invalid} = Accounts.reset_password_with_token(raw, "another123456")
    end

    test "minting a new link supersedes the previous one (one live link per person)" do
      user = user_fixture(%{username: "resettwice", password: "password123"})
      first = mint_reset(user)
      second = mint_reset(user)

      refute Accounts.reset_token_valid?(first)
      assert Accounts.reset_token_valid?(second)
      assert {:error, :invalid} = Accounts.reset_password_with_token(first, "whatever123456")
      assert {:ok, _} = Accounts.reset_password_with_token(second, "brandnewpass789")
    end

    test "rejects an unknown token" do
      assert {:error, :invalid} = Accounts.reset_password_with_token("nope", "whatever123456")
    end

    test "rejects an expired token" do
      user = user_fixture()
      raw = mint_reset(user)

      Repo.update_all(from(t in PasswordResetToken, where: t.user_id == ^user.id),
        set: [
          expires_at: DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)
        ]
      )

      assert {:error, :expired} = Accounts.reset_password_with_token(raw, "whatever123456")
    end

    test "rejects a too-short new password without consuming the token" do
      user = user_fixture()
      raw = mint_reset(user)
      assert {:error, %Ecto.Changeset{}} = Accounts.reset_password_with_token(raw, "short")
      # token survives (the transaction rolled back), so a valid retry still works
      assert {:ok, _} = Accounts.reset_password_with_token(raw, "validpass1234")
    end

    test "a plain admin can't mint a reset for a super_admin (no privilege escalation)" do
      admin = promote(user_fixture(), "admin")
      target = promote(user_fixture(), "super_admin")

      assert {:error, :forbidden} =
               Accounts.create_password_reset(Scope.for_user(admin), target)

      # a super_admin can
      sa = promote(user_fixture(), "super_admin")
      assert {:ok, _} = Accounts.create_password_reset(Scope.for_user(sa), target)
    end

    test "a non-admin can't mint a reset at all" do
      member = user_fixture()

      assert {:error, :forbidden} =
               Accounts.create_password_reset(Scope.for_user(member), user_fixture())
    end

    test "re-reads the target's role — a stale in-memory role can't authorize a reset (#263)" do
      admin = promote(user_fixture(), "admin")
      target = user_fixture()

      # The plain admin holds a struct where target.role is still "member", but the DB row is
      # promoted to super_admin before the reset. The FOR UPDATE re-read checks the fresh role.
      promote(target, "super_admin")

      assert {:error, :forbidden} =
               Accounts.create_password_reset(Scope.for_user(admin), target)
    end
  end

  describe "TOTP activation hardening (#263)" do
    test "admin_reset_totp re-reads the target's role (no stale-role TOCTOU)" do
      admin = promote(user_fixture(), "admin")
      target = user_fixture()
      promote(target, "super_admin")

      assert {:error, :forbidden} = Accounts.admin_reset_totp(Scope.for_user(admin), target)
    end

    test "admin_reset_totp clears the factor AND backup codes (#253 review)" do
      admin = promote(user_fixture(), "admin")
      target = user_fixture()
      {secret, _} = Accounts.setup_totp(target)

      {:ok, target, _codes} =
        Accounts.activate_totp(target, secret, NimbleTOTP.verification_code(secret))

      assert Accounts.totp_enrolled?(target)

      assert {:ok, updated} = Accounts.admin_reset_totp(Scope.for_user(admin), target)
      refute Accounts.totp_enrolled?(updated)
      # Backup codes are emptied too (not just the secret) — else a saved code still logs in.
      assert Accounts.get_user!(target.id).totp_backup_codes == []
    end

    test "backup codes carry 80 bits of entropy (16 chars)" do
      user = user_fixture()
      {secret, _} = Accounts.setup_totp(user)

      {:ok, _user, codes} =
        Accounts.activate_totp(user, secret, NimbleTOTP.verification_code(secret))

      assert length(codes) == 10
      assert Enum.all?(codes, &(String.length(&1) == 16))
    end

    test "activation burns the confirmation code — it can't also pass the login factor" do
      user = user_fixture()
      {secret, _} = Accounts.setup_totp(user)
      code = NimbleTOTP.verification_code(secret)

      {:ok, activated, _codes} = Accounts.activate_totp(user, secret, code)

      # The same code was consumed at activation → verify_totp rejects it as a replay.
      assert :error = Accounts.verify_totp(activated, code)
    end
  end

  describe "bootstrap_super_admin/3 (#353)" do
    test "creates the first super_admin on a fresh DB" do
      assert {:ok, user} = Accounts.bootstrap_super_admin("matveyihi", "password123")
      assert user.username == "matveyihi"
      assert user.role == "super_admin"
      assert user.active
      assert Accounts.super_admin?(user)
      # The password is usable at login.
      assert %{} = Accounts.get_user_by_username_and_password("matveyihi", "password123")
    end

    test "display_name defaults to the username" do
      {:ok, a} = Accounts.bootstrap_super_admin("adminone", "password123")
      assert a.display_name == "adminone"
    end

    test "display_name takes the :display_name option" do
      {:ok, a} =
        Accounts.bootstrap_super_admin("adminopt", "password123", display_name: "Custom Name")

      assert a.display_name == "Custom Name"
    end

    test "refuses when a super_admin already exists (idempotent, no second one)" do
      {:ok, _} = Accounts.bootstrap_super_admin("firstadmin", "password123")

      assert {:error, :already_bootstrapped} =
               Accounts.bootstrap_super_admin("secondadmin", "password123")

      refute Accounts.get_user_by_username_and_password("secondadmin", "password123")
    end

    test "returns a changeset error on invalid input (short password)" do
      assert {:error, %Ecto.Changeset{} = cs} = Accounts.bootstrap_super_admin("okname", "short")
      refute cs.valid?
    end

    test "a deactivated sole super_admin doesn't block bootstrap — the recovery path (#357/R002)" do
      # The lockout state: the only super_admin has been deactivated (active=false), so nobody
      # can reach /admin. bootstrap counts only USABLE supers, so it can restore access.
      user_fixture()
      |> promote("super_admin")
      |> Ecto.Changeset.change(active: false)
      |> Repo.update!()

      assert {:ok, restored} = Accounts.bootstrap_super_admin("rescue", "password123")
      assert restored.role == "super_admin"
      assert restored.active
    end
  end
end
