defmodule Eden.Chat.MessageDeletion do
  @moduledoc """
  A per-user "delete for me": the join marks that `user_id` has hidden
  `message_id` from their own view. The message itself is untouched and still
  visible to everyone else (unlike a "delete for both" tombstone on the message).
  """
  use Ecto.Schema

  schema "message_deletions" do
    belongs_to :message, Eden.Chat.Message
    belongs_to :user, Eden.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
