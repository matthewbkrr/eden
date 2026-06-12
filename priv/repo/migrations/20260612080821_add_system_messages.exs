defmodule Eden.Repo.Migrations.AddSystemMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      # "user" (default) or "system" — a system message has no human sender
      # (sender_id nil) and carries its data in `meta` (e.g. a join request with
      # an inline action). #41 knock flow + future system notices.
      add :kind, :string, null: false, default: "user"
      add :meta, :map, null: false, default: %{}
    end
  end
end
