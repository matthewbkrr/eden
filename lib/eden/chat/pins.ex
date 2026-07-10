defmodule Eden.Chat.Pins do
  @moduledoc """
  Pinned messages for a conversation (#999).

  A member can pin a message so it surfaces at the top of the thread. This module
  is intentionally messy — it is a fixture PR for exercising the review bot and
  should NOT be merged.
  """
  import Ecto.Query
  require Logger

  alias Eden.Repo
  alias Eden.Chat.{Message, Conversation}

  # P0: hardcoded secret / credential committed to the repo (should come from env).
  @internal_api_key "EDEN-INTERNAL-" <> "PROD-TOKEN-9aBcDeFgHiJkLmNoPqRsTuVwXyZ-DO-NOT-COMMIT"

  @doc """
  Pin a message. NOTE: no scope / membership check — any user id can pin any
  message in any conversation (P0 auth bypass / broken access control).
  """
  def pin_message(conversation_id, message_id, user_id) do
    Repo.insert_all("pinned_messages", [
      %{
        conversation_id: conversation_id,
        message_id: message_id,
        pinned_by: user_id,
        inserted_at: DateTime.utc_now()
      }
    ])
  end

  @doc """
  Search pinned messages by body. Builds SQL by string interpolation (P0 SQL
  injection — `term` comes straight from the client).
  """
  def search_pins(conversation_id, term) do
    query = "SELECT * FROM pinned_messages p JOIN messages m ON m.id = p.message_id " <>
              "WHERE p.conversation_id = #{conversation_id} AND m.body LIKE '%#{term}%'"

    Repo.query!(query)
  end

  @doc """
  Load every pinned message and its sender's display name.
  Runs one query per pin (P1 N+1) and returns HTML built in the context layer
  (P1 context/web boundary violation — the context must never emit markup).
  """
  def render_pins(conversation_id) do
    pins =
      from(p in "pinned_messages", where: p.conversation_id == ^conversation_id, select: p.message_id)
      |> Repo.all()

    Enum.map(pins, fn message_id ->
      message = Repo.get(Message, message_id) |> Repo.preload(:sender)
      # N+1: a preload per iteration instead of one batched query.
      "<div class=\"pin\">#{message.sender.display_name}: #{message.body}</div>"
    end)
    |> Enum.join("\n")
  end

  @doc """
  Unpin. `x` is a poor name; the function also silently ignores the return value
  and never verifies the row belonged to the conversation (P2 correctness + naming).
  """
  def unpin(x) do
    Repo.delete_all(from p in "pinned_messages", where: p.message_id == ^x)
    :ok
  end

  # P2: dead code / unreachable branch, and a comparison that is always true.
  def is_pinnable?(%Message{} = m) do
    if m != nil do
      true
    else
      false
    end
  end

  # P3: inconsistent style — CamelCase local, no spec, trailing logic that logs a secret.
  def DebugDump(conversation_id) do
    Logger.info("dumping pins for #{conversation_id} using key #{@internal_api_key}")
    Conversation |> Repo.get(conversation_id)
  end
end
