defmodule Eden.Chat.Message do
  @moduledoc """
  A message in a conversation. Belongs to its conversation and to a `sender`
  (a user) — the name/avatar are rendered from the preloaded sender, never copied
  into the row, so profile changes stay additive. `conversation_id` and
  `sender_id` are set programmatically by the context, not cast from user input.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @max_body 4000

  schema "messages" do
    field :body, :string

    belongs_to :conversation, Eden.Chat.Conversation
    belongs_to :sender, Eden.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:body])
    |> update_change(:body, &sanitize/1)
    |> validate_required([:body])
    |> validate_length(:body, max: @max_body, count: :codepoints)
  end

  # Postgres rejects NUL bytes even though they're valid UTF-8; strip them and
  # trim surrounding whitespace (a whitespace-only message becomes "" and fails
  # validate_required).
  defp sanitize(nil), do: nil
  defp sanitize(body), do: body |> String.replace("\0", "") |> String.trim()
end
