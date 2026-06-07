defmodule Eden.Repo.Migrations.CreateAttachments do
  use Ecto.Migration

  def change do
    create table(:attachments) do
      add :message_id, references(:messages, on_delete: :delete_all), null: false
      add :storage_key, :string, null: false
      add :content_type, :string, null: false
      add :byte_size, :integer, null: false
      add :width, :integer
      add :height, :integer
      add :thumbnail_key, :string

      timestamps(type: :utc_datetime)
    end

    # One photo per message in Phase 3.
    create unique_index(:attachments, [:message_id])
  end
end
