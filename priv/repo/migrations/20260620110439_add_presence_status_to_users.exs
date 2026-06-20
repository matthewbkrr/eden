defmodule Eden.Repo.Migrations.AddPresenceStatusToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # Manual presence status (#102): "auto" | "away" | "dnd" | "invisible".
      add :presence_status, :string, null: false, default: "auto"
    end
  end
end
