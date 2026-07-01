defmodule Eden.Repo.Migrations.AddEditedAtToMessages do
  use Ecto.Migration

  # #164: message editing. `edited_at` is set the first time a message's text/caption
  # is changed by its author; the UI shows "(edited)" + the time. Nullable, reversible.
  def change do
    alter table(:messages) do
      add :edited_at, :utc_datetime
    end
  end
end
