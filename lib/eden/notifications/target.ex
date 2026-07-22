defmodule Eden.Notifications.Target do
  @moduledoc """
  A registered push device (#418, ADR-0001): `(user, kind, token)` where `kind`
  names the transport (`apns | fcm | rustore | vk`) and `token` is the device's
  opaque push token. A user has many (phone + tablet + future desktop app). The
  in-tab Web adapter never stores a row — it has no device token.

  `enabled` is a soft switch reserved for a future per-device toggle; delivery
  reads only enabled rows. `last_seen_at` is touched on every (re-)registration
  so stale devices can be reaped by age later.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(apns fcm rustore vk)

  schema "notification_targets" do
    field :kind, :string
    field :token, :string
    field :enabled, :boolean, default: true
    field :last_seen_at, :utc_datetime

    belongs_to :user, Eden.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc "The known transport kinds (mirrors the DB CHECK constraint)."
  def kinds, do: @kinds

  @doc false
  def changeset(target, attrs) do
    target
    |> cast(attrs, [:kind, :token])
    |> validate_required([:kind, :token])
    |> validate_inclusion(:kind, @kinds)
    # APNs tokens are 64 hex chars, FCM registrations a few hundred — the cap
    # only guards junk from the (authed but client-supplied) register endpoint.
    |> validate_length(:token, min: 8, max: 4096)
    |> unique_constraint([:user_id, :kind, :token])
    |> check_constraint(:kind, name: :kind_must_be_known)
  end
end
