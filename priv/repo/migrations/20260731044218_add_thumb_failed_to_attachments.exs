defmodule Eden.Repo.Migrations.AddThumbFailedToAttachments do
  use Ecto.Migration

  # Whether thumbnail generation is known to be over for this attachment (#516). Without it,
  # "no thumbnail yet" and "no thumbnail ever" are indistinguishable, and the renderer had to
  # guess by age — a guess that only expires on a re-render, so a permanently failed thumbnail
  # could leave a blank photo for the rest of a session (#532 review).
  def change do
    alter table(:attachments) do
      add :thumb_failed, :boolean, null: false, default: false
    end
  end
end
