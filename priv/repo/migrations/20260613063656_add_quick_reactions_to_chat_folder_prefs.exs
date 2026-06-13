defmodule Eden.Repo.Migrations.AddQuickReactionsToChatFolderPrefs do
  use Ecto.Migration

  # Per-user quick-react row (#67): the emoji shown up front in the message menu.
  # NULL means "use the default set" — we don't seed a copy so the default stays
  # the single source of truth in code.
  def change do
    alter table(:chat_folder_prefs) do
      add :quick_reactions, {:array, :string}
    end
  end
end
