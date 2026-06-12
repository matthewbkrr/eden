defmodule Eden.Repo.Migrations.AddVisibilityToConversations do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      # Room visibility (corporate layer, #41): "open" rooms auto-join on any
      # link; "private" rooms require an admin add / invite token / knock. Nil
      # for DMs and groups (only channel rooms carry it). Default "open" so
      # existing rooms keep today's behavior until the access epic lands.
      add :visibility, :string, default: "open"
    end
  end
end
