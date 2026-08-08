defmodule Eden.Repo.Migrations.CreateMessageMentions do
  use Ecto.Migration

  def change do
    create table(:message_mentions) do
      add :message_id, references(:messages, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      # The handle AS TYPED, so the renderer knows which span of the body to turn into a chip.
      # The person is the `user_id`; this is only where the text sits. A rename therefore
      # re-labels every past mention (the chip shows the CURRENT handle) without touching the
      # stored body — the same thing Slack does, and the reason the row exists at all.
      add :handle, :string, null: false

      timestamps(type: :utc_datetime)
    end

    # One row per (message, person, handle): the same `@tag` twice in one body names the person
    # once, but `@all` and `@bob` in the SAME body are two different namings of Bob — one as the
    # room, one as himself — and each has its own span of text to chip. Keying on the person alone
    # dropped the second one silently (#577 review).
    create unique_index(:message_mentions, [:message_id, :user_id, :handle])
    # "Everything that mentions me" — the lookup a future mentions inbox and the unread
    # marker both need, and the one the delete cascade walks.
    create index(:message_mentions, [:user_id])
  end
end
