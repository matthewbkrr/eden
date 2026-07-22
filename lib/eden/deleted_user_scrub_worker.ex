defmodule Eden.DeletedUserScrubWorker do
  @moduledoc """
  Completes the cross-context scrub for a permanently-deleted (anonymized, #303) user,
  off the request path and **durably** (#357/R048).

  Enqueued inside `Eden.Accounts.delete_user_permanently/2`'s transaction, so the job row
  commits atomically with the anonymization (transactional outbox): a crash after commit can
  no longer lose the erasure the way the old best-effort post-commit call in `AdminLive`
  could — the person's name would otherwise linger forever in denormalized system-message
  `meta` with no product path to finish the scrub.

  It orchestrates two contexts (Accounts never reaches into them itself — that's an app-level
  job's job, like the web layer): scrubs the person's denormalized name from Chat's
  system-message `meta` and purges their private folders
  (`Eden.Chat.scrub_deleted_user_content/1`), revokes every channel/room invite they minted
  (`Eden.Channels.revoke_invites_by/1`), and reassigns any channel they solely own to a live
  successor — or deletes it if they were the only member — so no channel is left with a dead
  owner (`Eden.Channels.reassign_orphaned_ownerships/1`, #358). All three are idempotent, so
  retries are safe. A transient DB hiccup raises and retries; the anonymized row is already
  login-locked, so only the denormalized copies lag until the job runs.
  """
  use Oban.Worker, queue: :default, max_attempts: 5

  alias Eden.{Channels, Chat, Notifications}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) when is_integer(user_id) do
    Chat.scrub_deleted_user_content(user_id)
    Channels.revoke_invites_by(user_id)
    # delete_orphans: true — deletion is irreversible, so a channel left with no usable member
    # is permanently ownerless and should go (the deactivate path keeps it, #358 review).
    Channels.reassign_orphaned_ownerships(user_id, delete_orphans: true)
    # Push-device hygiene (#418): a deleted account's tokens must not linger.
    Notifications.delete_user_targets(user_id)
    :ok
  end
end
