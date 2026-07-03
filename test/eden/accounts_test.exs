defmodule Eden.AccountsTest do
  use Eden.DataCase, async: true

  alias Eden.Accounts
  alias Eden.Accounts.{Invite, PasswordResetToken, Scope, User, UserToken}

  defp user_fixture(attrs \\ %{}) do
    base = %{
      username: "inviter#{System.unique_integer([:positive])}",
      display_name: "Inviter",
      password: "password123"
    }

    {:ok, user} =
      %User{}
      |> User.registration_changeset(Map.merge(base, attrs))
      |> Repo.insert()

    user
  end

  # role isn't cast by registration_changeset (it's admin-managed, #174), so set it directly.
  defp promote(user, role), do: user |> Ecto.Changeset.change(role: role) |> Repo.update!()

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{username: "newbie", display_name: "New Person", password: "password123"},
      overrides
    )
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

  describe "apply_managed_fields/2 (#173)" do
    test "sets managed fields (trimmed, NUL-stripped) and broadcasts" do
      user = user_fixture()
      :ok = Accounts.subscribe_user_updates()

      assert {:ok, u} =
               Accounts.apply_managed_fields(user, %{
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

    test "rejects a malformed corp email and an unknown identity_source" do
      user = user_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Accounts.apply_managed_fields(user, %{"corp_email" => "not-an-email"})

      assert {:error, %Ecto.Changeset{}} =
               Accounts.apply_managed_fields(user, %{"identity_source" => "martian"})
    end

    test "bounds external_id and constrains managed_by (the remaining seams)" do
      user = user_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Accounts.apply_managed_fields(user, %{"external_id" => String.duplicate("x", 256)})

      assert {:error, %Ecto.Changeset{}} =
               Accounts.apply_managed_fields(user, %{"managed_by" => "the_wind"})

      assert {:ok, u} = Accounts.apply_managed_fields(user, %{"managed_by" => "directory"})
      assert u.managed_by == "directory"
    end

    test "a blank managed field clears to nil" do
      {:ok, user} = Accounts.apply_managed_fields(user_fixture(), %{"position" => "Analyst"})
      assert {:ok, cleared} = Accounts.apply_managed_fields(user, %{"position" => "  "})
      assert cleared.position == nil
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

      assert {:ok, raw} = Accounts.create_password_reset(user)
      assert {:ok, updated} = Accounts.reset_password_with_token(raw, "brandnewpass789")
      assert updated.id == user.id
      assert User.valid_password?(updated, "brandnewpass789")
      assert Repo.aggregate(from(t in UserToken, where: t.user_id == ^user.id), :count) == 0

      # single-use: the row is gone, a replay fails
      assert {:error, :invalid} = Accounts.reset_password_with_token(raw, "another123456")
    end

    test "rejects an unknown token" do
      assert {:error, :invalid} = Accounts.reset_password_with_token("nope", "whatever123456")
    end

    test "rejects an expired token" do
      user = user_fixture()
      {:ok, raw} = Accounts.create_password_reset(user)

      Repo.update_all(from(t in PasswordResetToken, where: t.user_id == ^user.id),
        set: [
          expires_at: DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)
        ]
      )

      assert {:error, :expired} = Accounts.reset_password_with_token(raw, "whatever123456")
    end

    test "rejects a too-short new password without consuming the token" do
      user = user_fixture()
      {:ok, raw} = Accounts.create_password_reset(user)
      assert {:error, %Ecto.Changeset{}} = Accounts.reset_password_with_token(raw, "short")
      # token survives (the transaction rolled back), so a valid retry still works
      assert {:ok, _} = Accounts.reset_password_with_token(raw, "validpass1234")
    end
  end
end
