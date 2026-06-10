defmodule Eden.Repo.Migrations.CreateChannels do
  use Ecto.Migration

  def change do
    # The corporate container (≈ Mattermost team / Discord server): groups
    # thematic chat rooms (#29) and carries its own membership and roles.
    create table(:channels) do
      add :name, :string, null: false
      add :about, :string
      add :creator_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:channels, [:creator_id])

    # Per-user channel membership with a role. The creator becomes "owner";
    # admins manage rooms/members/invites; members read and post.
    create table(:channel_memberships) do
      add :channel_id, references(:channels, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "member"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:channel_memberships, [:channel_id, :user_id])
    create index(:channel_memberships, [:user_id])
  end
end
