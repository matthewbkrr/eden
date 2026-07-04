defmodule Eden.Repo.Migrations.AddTotpToUsers do
  use Ecto.Migration

  # TOTP 2FA (#250). All columns are additive/nullable (expand-only, safe to deploy
  # against the running app). `totp_secret` holds the Eden.Vault-encrypted secret;
  # `totp_activated_at` nil means "not enrolled"; `totp_backup_codes` are hashed,
  # single-use recovery codes; `totp_last_used_at` guards against code replay.
  def change do
    alter table(:users) do
      add :totp_secret, :binary
      add :totp_activated_at, :utc_datetime
      add :totp_last_used_at, :utc_datetime
      add :totp_backup_codes, {:array, :string}, null: false, default: []
    end
  end
end
