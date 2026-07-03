defmodule Eden.Repo.Migrations.AddUserRole do
  use Ecto.Migration

  # #174 (RFC Phase 2): a global PLATFORM role on users — distinct from the
  # per-channel owner|admin|member roles (which are channel-scoped). Gates the
  # admin panel: `admin` / `super_admin` may manage people + managed identity
  # fields; everyone defaults to `member`. When orgs land (Phase 3) this becomes
  # the "platform staff / super-admin" tier, with org-admin a separate org role.
  # Reversible (add-in-change). The first admin is promoted out-of-band (iex).
  def change do
    alter table(:users) do
      add :role, :string, null: false, default: "member"
    end

    # DB-level guard so an invalid role can't slip in via raw SQL / a future path
    # that bypasses the changeset's inclusion validation (defense-in-depth).
    create constraint(:users, :role_must_be_valid,
             check: "role in ('member', 'admin', 'super_admin')"
           )

    # Both list_users/0 (admin panel) and list_other_users/1 (new-conversation
    # picker) order by display_name — index it so the sort stays cheap as the user
    # count grows instead of a scan + sort.
    create index(:users, [:display_name])
  end
end
