defmodule Eden.Repo.Migrations.AddNotifyPrefsToFolderPrefs do
  use Ecto.Migration

  # #214: per-user notification toggles. NOT NULL with defaults so existing
  # rows backfill cleanly (sound on, desktop off until the user opts in +
  # grants browser permission). Reversible.
  def change do
    alter table(:chat_folder_prefs) do
      add :notify_sound, :boolean, null: false, default: true
      add :notify_desktop, :boolean, null: false, default: false
    end
  end
end
