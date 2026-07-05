defmodule Eden.Repo.Migrations.AddNotifySoundNameToPrefs do
  use Ecto.Migration

  # #289: which notification chime plays. Nullable — NULL resolves to the default
  # preset, so existing rows and the no-prefs case keep the current sound.
  def change do
    alter table(:chat_folder_prefs) do
      add :notify_sound_name, :string
    end
  end
end
