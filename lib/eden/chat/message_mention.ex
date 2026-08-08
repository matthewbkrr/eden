defmodule Eden.Chat.MessageMention do
  @moduledoc """
  One `@` in one message, resolved to the person it names (#576).

  The row stores the USER, never the text. `username` is the public `@tag` and is
  self-chosen and renameable (#173) — a mention kept as `"@matvey"` would follow the
  handle rather than the person and, after a rename, point at someone else or at
  nobody. Resolution happens once, when the message is sent or edited; every render
  reads the person's CURRENT name through this row.
  """
  use Ecto.Schema

  schema "message_mentions" do
    # The handle as typed — where the chip goes in the body. The person is `user`.
    field :handle, :string

    belongs_to :message, Eden.Chat.Message
    belongs_to :user, Eden.Accounts.User

    timestamps(type: :utc_datetime)
  end
end
