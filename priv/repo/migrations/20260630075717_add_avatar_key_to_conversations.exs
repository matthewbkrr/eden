defmodule Eden.Repo.Migrations.AddAvatarKeyToConversations do
  use Ecto.Migration

  # #178: a group can have its own photo (owner/admin set). Stored as a Storage key
  # to the processed JPEG, mirroring users.avatar_key / channels.avatar_key. Nullable
  # (initials fallback when unset). Reversible.
  def change do
    alter table(:conversations) do
      add :avatar_key, :string
    end
  end
end
