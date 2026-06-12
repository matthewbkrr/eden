defmodule Eden.Repo.Migrations.AddPositionToAttachments do
  use Ecto.Migration

  # Albums (#58): a message goes from one attachment to many. Drop the
  # one-per-message unique index, add an explicit order column, and re-index
  # by (message_id, position) so the grid renders deterministically.
  def change do
    alter table(:attachments) do
      add :position, :integer, null: false, default: 0
    end

    drop unique_index(:attachments, [:message_id])
    create unique_index(:attachments, [:message_id, :position])
  end
end
