defmodule Eden.Accounts.TokenPruner do
  @moduledoc """
  Reclaims expired auth tokens off the request path (#238): session tokens past the
  60-day validity window and password-reset tokens past their expiry, which are
  otherwise never deleted (a live request only *filters* expired tokens by query, it
  never removes them, so `users_tokens` / `password_reset_tokens` would grow forever).

  Scheduled once a day by `Oban.Plugins.Cron` (see `config/config.exs`). Idempotent —
  an empty run is a no-op — so retries and an occasional overlapping schedule are safe.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Eden.Accounts

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    %{sessions: sessions, resets: resets} = Accounts.prune_expired_tokens()
    Logger.info("token prune: #{sessions} expired session token(s), #{resets} reset token(s)")
    :ok
  end
end
