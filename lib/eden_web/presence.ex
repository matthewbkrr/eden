defmodule EdenWeb.Presence do
  @moduledoc """
  Tracks which users are currently connected (via a LiveView) and the effective
  presence status others see, on a single global topic. Presence is ephemeral,
  not persisted: it lives only while a process is tracked and clears when the
  process exits.

  Two status vocabularies meet here (#102):

    * the user's *manual* choice — `auto | away | dnd | invisible` — is persisted
      on the user (see `Eden.Accounts`);
    * the *effective* status carried in the presence meta — `"online" | "away" |
      "dnd"` — is what other clients render.

  An "invisible" user is simply not tracked, so they appear offline to everyone
  while staying connected.
  """
  use Phoenix.Presence,
    otp_app: :eden,
    pubsub_server: Eden.PubSub

  @topic "eden:presence"
  # Lower rank = more available. Used to pick one deterministic status when a user
  # is tracked by several sessions whose metas momentarily disagree (#102 review).
  @status_rank %{"online" => 0, "away" => 1, "dnd" => 2}

  @doc "The presence topic for online users."
  def topic, do: @topic

  @doc """
  Tracks `user_id` with the given effective `status` (`"online" | "away" | "dnd"`)
  for the given (LiveView) process.
  """
  def track_user(pid, user_id, status \\ "online") do
    track(pid, @topic, to_string(user_id), %{status: status})
  end

  @doc """
  Maps a user's *manual* status to the *effective* status others see, or the
  `:invisible` sentinel (meaning "don't track" — appear offline).
  """
  def manual_to_effective("away"), do: "away"
  def manual_to_effective("dnd"), do: "dnd"
  def manual_to_effective("invisible"), do: :invisible
  # "auto" and a legacy nil are both online; an unknown value too, but spelled out
  # so a typo'd status isn't silently absorbed by a bare catch-all.
  def manual_to_effective(status) when status in ["auto", nil], do: "online"
  def manual_to_effective(_unknown), do: "online"

  @doc """
  Effective status per currently-tracked user: `%{integer_id => "online" | "away"
  | "dnd"}`. When a user has several sessions, the most-available status wins
  (deterministic), and a metaless/legacy `%{}` meta is treated as `"online"`.
  Plain map (not a MapSet) so it's safe to read back from LiveView assigns.
  """
  def statuses do
    @topic
    |> list()
    |> Map.new(fn {id, %{metas: metas}} ->
      status =
        metas
        |> Enum.map(&Map.get(&1, :status, "online"))
        |> Enum.min_by(&Map.get(@status_rank, &1, 0), fn -> "online" end)

      {String.to_integer(id), status}
    end)
  end

  @doc """
  Applies a `manual` status change for `user_id` on `pid`: untracks for
  "invisible", otherwise updates the meta — re-tracking if the process wasn't
  tracked (e.g. returning from invisible, where `update/4` yields
  `{:error, :nopresence}`).
  """
  def set_status(pid, user_id, manual) do
    case manual_to_effective(manual) do
      :invisible ->
        untrack(pid, @topic, to_string(user_id))

      effective ->
        case update(pid, @topic, to_string(user_id), %{status: effective}) do
          {:error, :nopresence} -> track_user(pid, user_id, effective)
          ok -> ok
        end
    end
  end
end
