defmodule Eden.Repo.Migrations.AddClientIdToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      # Client-generated idempotency key (a UUID), set on realtime sends so a
      # resend after a reconnect doesn't create a duplicate row. Nullable: older
      # rows and server-side inserts may not carry one.
      add :client_id, :string
    end

    # Unique per sender (UUIDs are globally unique anyway); partial so the many
    # rows without a client_id are unconstrained.
    create unique_index(:messages, [:sender_id, :client_id],
             where: "client_id IS NOT NULL",
             name: :messages_sender_id_client_id_index
           )
  end
end
