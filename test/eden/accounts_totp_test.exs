defmodule Eden.AccountsTotpTest do
  use Eden.DataCase, async: true

  alias Eden.Accounts
  alias Eden.Accounts.{Scope, User}

  import Eden.AccountsFixtures

  defp promote(user, role), do: user |> Ecto.Changeset.change(role: role) |> Repo.update!()
  defp code(secret), do: NimbleTOTP.verification_code(secret)

  describe "enrollment" do
    test "setup → activate stores an encrypted secret and returns backup codes" do
      user = user_fixture()
      refute Accounts.totp_enrolled?(user)

      {secret, uri} = Accounts.setup_totp(user)
      assert uri =~ "otpauth://totp/"
      # Not persisted until activation.
      refute Accounts.totp_enrolled?(Accounts.get_user!(user.id))

      assert {:ok, updated, codes} = Accounts.activate_totp(user, secret, code(secret))
      assert Accounts.totp_enrolled?(updated)
      assert length(codes) == 10
      # The secret is stored encrypted, never in the clear.
      refute updated.totp_secret == secret
      assert {:ok, ^secret} = Eden.Vault.decrypt(updated.totp_secret)
    end

    test "rejects activation with a wrong code" do
      user = user_fixture()
      {secret, _uri} = Accounts.setup_totp(user)
      assert {:error, :invalid_code} = Accounts.activate_totp(user, secret, "000000")
      refute Accounts.totp_enrolled?(Accounts.get_user!(user.id))
    end
  end

  describe "verification" do
    setup do
      user = user_fixture()
      {secret, _} = Accounts.setup_totp(user)
      {:ok, user, codes} = Accounts.activate_totp(user, secret, code(secret))
      %{user: user, secret: secret, codes: codes}
    end

    test "accepts a valid code and blocks its replay", %{user: user, secret: secret} do
      assert {:ok, used} = Accounts.verify_totp(user, code(secret))
      # Same code again (same window) is rejected — replay guard via totp_last_used_at.
      assert :error = Accounts.verify_totp(used, code(secret))
    end

    test "rejects a wrong code", %{user: user} do
      assert :error = Accounts.verify_totp(user, "000000")
    end

    test "consumes a one-time backup code", %{user: user, codes: [c | _]} do
      assert {:ok, updated} = Accounts.consume_backup_code(user, c)
      assert length(updated.totp_backup_codes) == 9
      # single use: the same code no longer works
      assert :error = Accounts.consume_backup_code(updated, c)
    end

    test "a backup code matches regardless of case/spacing", %{user: user, codes: [c | _]} do
      assert {:ok, _} = Accounts.consume_backup_code(user, " #{String.upcase(c)} ")
    end
  end

  describe "disable" do
    setup do
      user = user_fixture()
      {secret, _} = Accounts.setup_totp(user)
      {:ok, user, _} = Accounts.activate_totp(user, secret, code(secret))
      %{user: user, secret: secret}
    end

    test "a member can disable with a valid code", %{user: user, secret: secret} do
      assert {:ok, updated} = Accounts.disable_totp(user, code(secret))
      refute Accounts.totp_enrolled?(updated)
      assert updated.totp_secret == nil
    end

    test "a wrong code doesn't disable", %{user: user} do
      assert {:error, :invalid_code} = Accounts.disable_totp(user, "000000")
    end

    test "an admin can't disable their mandatory factor", %{user: user, secret: secret} do
      admin = promote(user, "admin")
      assert {:error, :required_for_admin} = Accounts.disable_totp(admin, code(secret))
      assert %User{} = Accounts.get_user!(admin.id)
      assert Accounts.totp_enrolled?(Accounts.get_user!(admin.id))
    end
  end

  describe "admin reset (lost-device recovery, #250)" do
    setup do
      target = user_fixture(%{username: "victim"})
      {secret, _} = Accounts.setup_totp(target)
      {:ok, target, _} = Accounts.activate_totp(target, secret, code(secret))
      %{target: target}
    end

    test "an admin clears a member's TOTP", %{target: target} do
      admin = promote(user_fixture(%{username: "resetter"}), "admin")
      assert {:ok, cleared} = Accounts.admin_reset_totp(Scope.for_user(admin), target)
      refute Accounts.totp_enrolled?(cleared)
    end

    test "a plain admin can't reset a super_admin's TOTP" do
      admin = promote(user_fixture(%{username: "plainadmin"}), "admin")
      sa = promote(user_fixture(%{username: "bigboss"}), "super_admin")
      {secret, _} = Accounts.setup_totp(sa)
      {:ok, sa, _} = Accounts.activate_totp(sa, secret, code(secret))

      assert {:error, :forbidden} = Accounts.admin_reset_totp(Scope.for_user(admin), sa)
      assert Accounts.totp_enrolled?(Accounts.get_user!(sa.id))
    end

    test "an admin can't reset their OWN factor via the recovery path (no mandatory-2FA bypass)" do
      admin = promote(user_fixture(%{username: "selfreset"}), "admin")
      {secret, _} = Accounts.setup_totp(admin)
      {:ok, admin, _} = Accounts.activate_totp(admin, secret, code(secret))

      assert {:error, :forbidden} = Accounts.admin_reset_totp(Scope.for_user(admin), admin)
      assert Accounts.totp_enrolled?(Accounts.get_user!(admin.id))
    end
  end
end
