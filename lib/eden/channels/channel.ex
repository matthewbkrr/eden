defmodule Eden.Channels.Channel do
  @moduledoc """
  The corporate container (≈ Mattermost *team*, Discord *server*): groups
  thematic chat rooms and carries its own membership and roles. Created by a
  user who becomes its `owner` (see `Eden.Channels.Membership`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @max_name 60
  @max_about 300

  schema "channels" do
    field :name, :string
    field :about, :string

    # The scoped user's role in this channel, filled by Eden.Channels queries.
    field :role, :string, virtual: true
    # Rail badge state, filled by list_channels/1: aggregate unread across the
    # user's joined rooms (room-mute-aware) and whether the channel is muted.
    field :unread_count, :integer, virtual: true, default: 0
    field :muted, :boolean, virtual: true, default: false

    belongs_to :creator, Eden.Accounts.User
    has_many :memberships, Eden.Channels.Membership

    timestamps(type: :utc_datetime)
  end

  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [:name, :about])
    # cast turns whitespace-only params into a nil change (Ecto's default
    # empty_values), so the trims must tolerate nil; validate_required then
    # reports the blank name.
    |> update_change(:name, &(&1 && String.trim(&1)))
    |> update_change(:about, &(&1 && String.trim(&1)))
    |> validate_required([:name])
    |> validate_length(:name, max: @max_name)
    |> validate_length(:about, max: @max_about)
  end

  def max_name, do: @max_name
  def max_about, do: @max_about
end
