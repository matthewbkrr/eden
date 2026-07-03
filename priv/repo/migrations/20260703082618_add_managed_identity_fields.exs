defmodule Eden.Repo.Migrations.AddManagedIdentityFields do
  use Ecto.Migration

  # #173 (RFC Phase 1): managed identity fields on `users`. These are written ONLY
  # by the admin panel (#174) / a future directory sync — never by the user's own
  # profile changeset. All nullable so existing accounts backfill to "unset";
  # `identity_source` defaults to "local" (every current user is eden-local, no
  # upstream). Reversible: `add` inside `change` auto-drops on rollback.
  def change do
    alter table(:users) do
      # Admin-managed profile data (read-only to the user), populated by #174.
      add :corp_email, :string
      add :position, :string
      add :structure, :string

      # Seams for a future directory/SSO sync (ADR-0002 corp-OIDC slot).
      add :external_id, :string
      add :identity_source, :string, null: false, default: "local"
      add :managed_by, :string
      add :directory_synced_at, :utc_datetime
    end
  end
end
