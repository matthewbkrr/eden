defmodule Eden.Repo.Migrations.CreatePasswordResetTokens do
  use Ecto.Migration

  # #232: admin-issued password-reset links. Only the SHA-256 hash is stored
  # (hash-at-rest, like invite + session tokens); redemption is single-use (the
  # row is deleted) and short-lived (expires_at). Cascades on user delete.
  def change do
    create table(:password_reset_tokens) do
      add :hashed_token, :string, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:password_reset_tokens, [:hashed_token])
    create index(:password_reset_tokens, [:user_id])
  end
end
