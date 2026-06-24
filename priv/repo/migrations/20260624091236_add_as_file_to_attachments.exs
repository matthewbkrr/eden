defmodule Eden.Repo.Migrations.AddAsFileToAttachments do
  use Ecto.Migration

  def change do
    # "Send as file" (#122): an image stored uncompressed and rendered as a downloadable
    # document (with a thumbnail) instead of an inline photo. Default false = a normal
    # compressed inline image.
    alter table(:attachments) do
      add :as_file, :boolean, null: false, default: false
    end
  end
end
