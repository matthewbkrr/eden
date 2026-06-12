defmodule Eden.Repo.Migrations.RoomAccessGeneralOnly do
  use Ecto.Migration

  @moduledoc """
  Room-access epic (#41) behavior phase. Adds the `is_general` marker and
  switches the corporate layer to "general-only on join": memberships in
  non-`general` rooms are dropped, so everyone re-enters those rooms under the
  new rules (open = link auto-join, private = invite/add/knock).

  ⚠️ The membership DELETE is **destructive and not reversible by data** — only
  the schema (the `is_general` column) rolls back. Production is not deployed,
  so in practice this only resets dev/test data. Documented in PR #41 PR-B.
  """
  import Ecto.Query

  def up do
    alter table(:conversations) do
      # The channel's Town Square: always open, undeletable, auto-joined on
      # channel entry. Explicit flag (not "min id" magic) so the join /
      # undeletable / always-open guards read off one source of truth.
      add :is_general, :boolean, null: false, default: false
    end

    flush()

    # Backfill: the oldest room in each channel is its general (that's how
    # Channels.create_channel seeds it).
    execute("""
    UPDATE conversations c
    SET is_general = true
    WHERE c.channel_id IS NOT NULL
      AND c.id = (
        SELECT MIN(c2.id) FROM conversations c2 WHERE c2.channel_id = c.channel_id
      )
    """)

    # All existing rooms become open (the default already, but make it explicit
    # for any row that predates the visibility column default).
    execute("""
    UPDATE conversations
    SET visibility = 'open'
    WHERE channel_id IS NOT NULL AND visibility IS NULL
    """)

    # Destructive: drop memberships in non-general rooms. Everyone keeps general
    # and re-enters other rooms under the new access rules.
    execute("""
    DELETE FROM memberships m
    USING conversations c
    WHERE m.conversation_id = c.id
      AND c.channel_id IS NOT NULL
      AND c.is_general = false
    """)
  end

  def down do
    alter table(:conversations) do
      remove :is_general
    end
  end
end
