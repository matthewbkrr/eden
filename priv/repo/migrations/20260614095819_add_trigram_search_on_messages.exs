defmodule Eden.Repo.Migrations.AddTrigramSearchOnMessages do
  use Ecto.Migration

  # Trigram search (#56): a GIN trigram index lets the message-body search use an
  # index instead of a sequential scan, and supports both `ILIKE '%term%'` and the
  # word-similarity operator `<%` (typo tolerance). Mirrors the citext extension
  # pattern from the accounts migration.
  #
  # Plain (non-CONCURRENT) CREATE INDEX takes a write lock on `messages` for the
  # build — fine at eden's scale (the table is small). If `messages` ever grows
  # large, rebuild this as a separate CONCURRENTLY migration
  # (`@disable_ddl_transaction true` + `@disable_migration_lock true`, explicit
  # up/down) to avoid blocking message inserts during deploy.
  def change do
    execute "CREATE EXTENSION IF NOT EXISTS pg_trgm", "DROP EXTENSION IF EXISTS pg_trgm"

    create index(:messages, ["body gin_trgm_ops"], name: :messages_body_trgm_idx, using: :gin)
  end
end
