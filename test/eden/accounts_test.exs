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
end
