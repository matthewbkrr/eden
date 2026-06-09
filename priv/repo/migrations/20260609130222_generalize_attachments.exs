defmodule Eden.Repo.Migrations.GeneralizeAttachments do
  use Ecto.Migration

  def change do
    alter table(:attachments) do
      add :kind, :string
      add :filename, :string
      add :duration, :integer
    end

    # Every existing attachment predates non-image kinds (Phase 3 was image-only).
    execute(
      "UPDATE attachments SET kind = 'image' WHERE kind IS NULL",
      "UPDATE attachments SET kind = NULL"
    )

    # kind is intrinsic to every attachment; require it once existing rows are backfilled.
    alter table(:attachments) do
      modify :kind, :string, null: false, from: {:string, null: true}
    end
  end
end
