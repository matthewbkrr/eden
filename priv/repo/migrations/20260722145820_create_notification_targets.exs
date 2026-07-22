defmodule Eden.Repo.Migrations.CreateNotificationTargets do
  use Ecto.Migration

  # Push-device registry (#418, ADR-0001): one row per (user, transport, device
  # token). Push-only by design — the in-tab Web adapter has no device token and
  # therefore no row here, which keeps `token` NOT NULL (a nullable token would
  # defeat the unique index: Postgres treats NULLs as distinct).
  def change do
    create table(:notification_targets) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :token, :text, null: false
      add :enabled, :boolean, null: false, default: true
      add :last_seen_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # Registration is an upsert on this triple; its leftmost column also serves
    # the per-user lookups, so no separate user_id index is needed.
    create unique_index(:notification_targets, [:user_id, :kind, :token])

    # The changeset validates inclusion, but `kind` fans out to transport modules
    # — back it with a DB CHECK like users.role so no code path can smuggle an
    # unknown transport in. rustore/vk are pre-declared for the #421 fallback.
    create constraint(:notification_targets, :kind_must_be_known,
             check: "kind IN ('apns', 'fcm', 'rustore', 'vk')"
           )
  end
end
