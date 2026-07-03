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
  end
end
