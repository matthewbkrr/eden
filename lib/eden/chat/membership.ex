defmodule Eden.Chat.Membership do
  @moduledoc """
  Join between a `Conversation` and a user. Carries the member's `role`, their
  join time (`inserted_at`), and `last_read_at` for unread tracking. A user has
  at most one membership per conversation.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "memberships" do
    field :role, :string, default: "member"
    field :last_read_at, :utc_datetime
    # Set when the user "deletes" (hides) the conversation; cleared on new activity.
    field :left_at, :utc_datetime

    belongs_to :conversation, Eden.Chat.Conversation
    belongs_to :user, Eden.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:user_id, :role, :last_read_at])
    |> validate_required([:user_id])
    |> validate_inclusion(:role, ["member", "owner"])
    |> assoc_constraint(:user)
    |> assoc_constraint(:conversation)
    |> unique_constraint([:user_id, :conversation_id],
      name: :memberships_conversation_id_user_id_index
    )
  end
end
