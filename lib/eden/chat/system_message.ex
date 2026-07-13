defmodule Eden.Chat.SystemMessage do
  @moduledoc """
  The single owner of a system message's jsonb `meta` shape (#360).

  System messages (`kind == "system"`, empty body, no sender — the payload lives in `meta`)
  are private-room knock requests (#41) and group "X added / removed" notices (#165). Their
  `meta` was a stringly-typed contract smeared across `Eden.Chat`, `Eden.Channels`, and the web
  layer, with no owner and no compiler check on the keys.

  This module is now the ONLY place that shape is **built** (`join_request/1`, `member_added/1`,
  `member_removed/2`, `resolve_status/2`) and **decoded** (`describe/1` → a tagged tuple the web
  layer renders without ever touching a raw key). Encapsulated jsonb queries reference the key
  names here (`action_key/0`, …) instead of bare literals scattered across fragments.
  """
  alias Eden.Accounts.User

  # Well-known `meta["action"]` values.
  @join_request "join_request"
  @member_added "member_added"
  @member_removed "member_removed"

  # `meta["status"]` values for a knock.
  @pending "pending"
  @statuses ~w(pending accepted declined)

  ## Constructors — the ONLY place a system-message meta map is built.

  @doc "meta for a private-room knock (#41), status `pending`."
  def join_request(%User{} = requester) do
    %{
      "action" => @join_request,
      "requester_id" => requester.id,
      "requester_name" => requester.display_name,
      "status" => @pending
    }
  end

  @doc "meta for a group \"X added\" notice (#165)."
  def member_added(%User{} = user) do
    %{"action" => @member_added, "user_id" => user.id, "name" => user.display_name}
  end

  @doc "meta for a group \"X removed\" notice (#165) — the id + denormalized name directly."
  def member_removed(user_id, name) when is_integer(user_id) and is_binary(name) do
    %{"action" => @member_removed, "user_id" => user_id, "name" => name}
  end

  @doc "Sets a knock's `status` (`accepted`/`declined`), keeping the rest of `meta`."
  def resolve_status(meta, status) when is_map(meta) and status in @statuses do
    Map.put(meta, "status", status)
  end

  ## Reader — decode meta into a tagged tuple for rendering / matching (never a raw key).

  @doc """
  Decodes `meta` into a tagged tuple so callers match on an atom, never a raw jsonb key:
  `{:join_request, %{requester_id, requester_name, status}}` | `{:member_added, %{user_id, name}}`
  | `{:member_removed, %{user_id, name}}` | `:unknown` (an unrecognized / future action).
  """
  def describe(%{"action" => @join_request} = meta) do
    {:join_request,
     %{
       requester_id: meta["requester_id"],
       requester_name: meta["requester_name"],
       status: meta["status"]
     }}
  end

  def describe(%{"action" => @member_added} = meta),
    do: {:member_added, %{user_id: meta["user_id"], name: meta["name"]}}

  def describe(%{"action" => @member_removed} = meta),
    do: {:member_removed, %{user_id: meta["user_id"], name: meta["name"]}}

  def describe(_meta), do: :unknown

  ## Key / value accessors for the encapsulated jsonb queries in Eden.Chat / Eden.Channels.

  @doc "The `meta` key holding the event type."
  def action_key, do: "action"

  @doc "The `meta` key holding a knock's status."
  def status_key, do: "status"

  @doc "The `meta` key holding a knock requester's id."
  def requester_id_key, do: "requester_id"

  @doc "The `action` value of a knock."
  def join_request_action, do: @join_request

  @doc "The `status` value of an open knock."
  def pending_status, do: @pending

  @doc """
  The `{id_key, name_path}` pairs whose `meta` points at a user, scrubbed on account deletion
  (#303/#305): a knock's `requester_id` → `requester_name`, a member notice's `user_id` → `name`.
  """
  def scrub_targets, do: [{"requester_id", ["requester_name"]}, {"user_id", ["name"]}]
end
