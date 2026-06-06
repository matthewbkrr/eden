defmodule Eden.AccountsFixtures do
  @moduledoc "Test fixtures for the Accounts context."

  alias Eden.Accounts

  def valid_user_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      username: "user#{System.unique_integer([:positive])}",
      display_name: "Test User",
      password: "password123"
    })
  end

  @doc "Creates a system invite and returns its raw token."
  def invite_token_fixture(opts \\ []) do
    {:ok, _invite, token} = Accounts.create_invite(nil, opts)
    token
  end

  @doc "Registers a user by accepting a fresh single-use invite."
  def user_fixture(attrs \\ %{}) do
    {:ok, user} =
      Accounts.register_user_with_invite(invite_token_fixture(), valid_user_attrs(attrs))

    user
  end
end
