defmodule Eden.Repo.Migrations.CreateChannelInvites do
  use Ecto.Migration

  def change do
    # Shareable channel invite links — same shape as registration invites:
    # only the SHA-256 hash of the token is stored, validity derives from
    # expires_at / used_count vs max_uses / revoked_at.
    create table(:channel_invites) do
      add :channel_id, references(:channels, on_delete: :delete_all), null: false
      add :hashed_token, :string, null: false
      add :expires_at, :utc_datetime, null: false
      add :max_uses, :integer
      add :used_count, :integer, null: false, default: 0
      add :revoked_at, :utc_datetime
      add :created_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:channel_invites, [:hashed_token])
    create index(:channel_invites, [:channel_id])
  end
end
