defmodule Eden.Accounts.PasswordResetToken do
  @moduledoc """
  An admin-issued password-reset link (#232). Hash-at-rest (`hashed_token`,
  redacted), single-use (the row is deleted on redemption), short-lived
  (`expires_at`). Belongs to the user whose password it resets; cascades on user
  delete. Minted/hashed via `Eden.Tokens`.
  """
  use Ecto.Schema

  schema "password_reset_tokens" do
    field :hashed_token, :string, redact: true
    field :expires_at, :utc_datetime
    belongs_to :user, Eden.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
