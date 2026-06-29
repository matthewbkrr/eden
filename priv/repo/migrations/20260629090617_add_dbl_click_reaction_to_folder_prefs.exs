defmodule Eden.Repo.Migrations.AddDblClickReactionToFolderPrefs do
  use Ecto.Migration

  # #106: the emoji a double-click reacts with. NULL = "use the first quick
  # reaction" (which itself falls back to the default set). Reversible.
  def change do
    alter table(:chat_folder_prefs) do
      add :dbl_click_reaction, :string
    end
  end
end
