defmodule Eden.Accounts.TokenPrunerTest do
  use Eden.DataCase, async: true

  import Eden.AccountsFixtures

  alias Eden.Accounts
  alias Eden.Accounts.{PasswordResetToken, TokenPruner, UserToken}

  defp put_session_token(user, inserted_at) do
    {_raw, token} = UserToken.build_session_token(user)
    Repo.insert!(%{token | inserted_at: inserted_at})
  end

  defp days_ago(n), do: DateTime.utc_now() |> DateTime.add(-n, :day) |> DateTime.truncate(:second)

  defp days_hence(n),
    do: DateTime.utc_now() |> DateTime.add(n, :day) |> DateTime.truncate(:second)

  describe "prune_expired_tokens/0" do
    test "deletes session tokens past the 60-day window, keeps fresh ones" do
      user = user_fixture()
      expired = put_session_token(user, days_ago(61))
      fresh = put_session_token(user, days_ago(1))

      assert %{sessions: 1} = Accounts.prune_expired_tokens()

      refute Repo.get(UserToken, expired.id)
      assert Repo.get(UserToken, fresh.id)
    end

    test "deletes password-reset tokens past expiry, keeps valid ones" do
      user = user_fixture()

      expired =
        Repo.insert!(%PasswordResetToken{
          hashed_token: "expired",
          expires_at: days_ago(1),
          user_id: user.id
        })

      valid =
        Repo.insert!(%PasswordResetToken{
          hashed_token: "valid",
          expires_at: days_hence(1),
          user_id: user.id
        })

      assert %{resets: 1} = Accounts.prune_expired_tokens()

      refute Repo.get(PasswordResetToken, expired.id)
      assert Repo.get(PasswordResetToken, valid.id)
    end

    test "an empty run is a no-op" do
      assert %{sessions: 0, resets: 0} = Accounts.prune_expired_tokens()
    end
  end

  test "the TokenPruner worker prunes and returns :ok" do
    user = user_fixture()
    stale = put_session_token(user, days_ago(90))

    assert :ok = TokenPruner.perform(%Oban.Job{args: %{}})
    refute Repo.get(UserToken, stale.id)
  end
end
