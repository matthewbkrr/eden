defmodule Eden.Channels.Membership do
  @moduledoc """
  Join between a `Channel` and a user, carrying the member's `role`:
  `owner` (the creator; deletes the channel, manages admins) → `admin`
  (manages rooms, members, invites) → `member` (reads and posts). A user has
  at most one membership per channel — the same shape as Mattermost's
  ChannelMembers.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @roles ~w(owner admin member)

  schema "channel_memberships" do
    field :role, :string, default: "member"
    # Per-user channel mute (badge-only); see the migration.
    field :muted_at, :utc_datetime

    belongs_to :channel, Eden.Channels.Channel
    belongs_to :user, Eden.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:channel_id, :user_id, :role])
    |> validate_required([:channel_id, :user_id, :role])
    |> validate_inclusion(:role, @roles)
    |> assoc_constraint(:channel)
    |> assoc_constraint(:user)
    |> unique_constraint([:channel_id, :user_id],
      name: :channel_memberships_channel_id_user_id_index
    )
  end

  def roles, do: @roles
end
