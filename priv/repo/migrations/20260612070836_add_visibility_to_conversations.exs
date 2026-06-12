defmodule Eden.Repo.Migrations.AddVisibilityToConversations do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      # Room visibility (corporate layer, #41): "open" rooms auto-join on any
      # link; "private" rooms require an admin add / invite token / knock. Only
      # consulted for channel rooms — DMs/groups get the default too but never
      # read it. Default "open" so existing rooms keep today's behavior until
      # the access epic's behavior phase (PR-B) lands.
      add :visibility, :string, default: "open"
    end
  end
end
