defmodule Eden.Repo.Migrations.AddThumbFailedToAttachments do
  use Ecto.Migration

  # Whether thumbnail generation is known to be over for this attachment (#516). Without it,
  # "no thumbnail yet" and "no thumbnail ever" are indistinguishable, and the renderer had to
  # guess by age — a guess that only expires on a re-render, so a permanently failed thumbnail
  # could leave a blank photo for the rest of a session (#532 review).
  def up do
    alter table(:attachments) do
      add :thumb_failed, :boolean, null: false, default: false
    end

    # Backfill, or this migration is a regression rather than a fix (#532 review, second round).
    # Every attachment that already has no thumbnail is one whose generation is long over — the
    # job either failed or was cancelled before this deploy. Left at the `false` default they
    # would render the pending placeholder FOREVER, i.e. photos that display today would go
    # blank. Marking them failed makes the renderer fall back to the original, which is exactly
    # what they show now.
    #
    # An attachment enqueued moments before this runs is also marked, and that is the safe
    # direction: it shows the original (heavy) instead of the placeholder (blank), and the
    # worker's success path clears nothing — it sets thumbnail_key, which wins outright.
    execute("UPDATE attachments SET thumb_failed = true WHERE thumbnail_key IS NULL")
  end

  def down do
    alter table(:attachments) do
      remove :thumb_failed
    end
  end
end
