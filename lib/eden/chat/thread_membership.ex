defmodule Eden.Chat.ThreadMembership do
  @moduledoc """
  Per-user state for a Collapsed Reply Thread (#57): whether the user is
  `following` the thread, when they `last_viewed_at` it, and their
  `unread_replies` count. One row per `(user, thread root message)`, modeled on
  Mattermost's `ThreadMemberships`.

  You auto-follow a thread by replying in it (the root's author is auto-followed
  on the first reply too); a follower's `unread_replies` increments on every new
  reply by someone else and resets to zero when they open the thread. Unfollowing
  keeps the row but stops the count. Rows cascade away with the root message or
  the user.

  `root_id` / `unread_replies` / `last_viewed_at` are maintained programmatically
  by the Chat context (atomic `update_all` / upserts), never cast from input.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "thread_memberships" do
    field :following, :boolean, default: true
    field :last_viewed_at, :utc_datetime
    field :unread_replies, :integer, default: 0

    belongs_to :user, Eden.Accounts.User
    belongs_to :root, Eden.Chat.Message

    timestamps(type: :utc_datetime)
  end

  def changeset(thread_membership, attrs) do
    thread_membership
    |> cast(attrs, [:user_id, :root_id, :following, :last_viewed_at, :unread_replies])
    |> validate_required([:user_id, :root_id])
    |> assoc_constraint(:user)
    |> assoc_constraint(:root)
    |> unique_constraint([:user_id, :root_id],
      name: :thread_memberships_user_id_root_id_index
    )
  end
end
