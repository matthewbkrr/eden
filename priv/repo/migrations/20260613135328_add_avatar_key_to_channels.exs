defmodule Eden.Repo.Migrations.AddAvatarKeyToChannels do
  use Ecto.Migration

  # Channel avatar (#70): the storage key of a processed square JPEG, shown in
  # the rail. NULL = no avatar (rail falls back to initials).
  def change do
    alter table(:channels) do
      add :avatar_key, :string
    end
  end
end
