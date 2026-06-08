defmodule Eden.Repo.Migrations.AddProfileFieldsToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # Free-text profile description (length-capped + NUL-sanitized in the changeset).
      add :bio, :text
      # Storage key of the processed (square, EXIF-stripped) avatar, or NULL.
      add :avatar_key, :string
    end
  end
end
