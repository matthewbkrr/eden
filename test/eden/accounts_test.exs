defmodule Eden.AccountsTest do
  use Eden.DataCase, async: true

  alias Eden.Accounts
  alias Eden.Accounts.{Invite, User}

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

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{username: "newbie", display_name: "New Person", password: "password123"},
      overrides
    )
  end

  defp past, do: DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)

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
      assert {:error, :invalid_invite} = Accounts.register_user_with_invite("nope", valid_attrs())
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
end
