defmodule EdenWeb.Presence do
  @moduledoc """
  Tracks which users are currently online (connected via a LiveView), on a single
  global topic. Online state is presence, not persisted: it lives only while a
  process is tracked and clears automatically when the process exits.
  """
  use Phoenix.Presence,
    otp_app: :eden,
    pubsub_server: Eden.PubSub

  @topic "eden:presence"

  @doc "The presence topic for online users."
  def topic, do: @topic

  @doc "Tracks `user_id` as online for the given (LiveView) process."
  def track_user(pid, user_id) do
    track(pid, @topic, to_string(user_id), %{})
  end

  @doc "The set of currently-online user ids (integers)."
  def online_ids do
    @topic
    |> list()
    |> Map.keys()
    |> MapSet.new(&String.to_integer/1)
  end
end
