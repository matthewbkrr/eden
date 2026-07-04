defmodule EdenWeb.RateLimit do
  @moduledoc """
  Per-IP throttle plug for the signed-out credential endpoints (#236, security
  P2-1): `POST /users/log_in` and `POST /invite/:token`. Backed by the hand-rolled
  `Eden.RateLimit`.

  Over-limit requests are **halted before the controller** and bounced back to the
  page with a flash — the form never reaches the auth path, so parallel guessing
  can't outrun the bcrypt delay. Login is the real target (guessable usernames);
  the invite endpoint's 256-bit token already resists guessing, but the same plug
  covers it cheaply against redemption-spraying.

  Keyed on `conn.remote_ip`, which behind the prod reverse proxy is the real client
  IP only because the endpoint trusts Caddy's `x-forwarded-for` (see `endpoint.ex`)
  and Caddy overwrites that header with the true peer (see `deploy/Caddyfile`).

  Options:
    * `:scope`  — `:login | :invite`, the bucket namespace + retry target (required)
    * `:limit`  — max requests per window (default #{10})
    * `:window` — window length in ms (default 5 min)
    * `:enabled` — override the on/off state (defaults to app env; off in test so the
      suite's many logins aren't throttled — the throttle is unit-tested directly)
  """
  @behaviour Plug

  import Plug.Conn
  import Phoenix.Controller, only: [put_flash: 3, redirect: 2]

  use Gettext, backend: EdenWeb.Gettext
  use EdenWeb, :verified_routes

  @default_limit 10
  @default_window :timer.minutes(5)

  @impl true
  def init(opts) do
    %{
      scope: Keyword.fetch!(opts, :scope),
      limit: Keyword.get(opts, :limit, @default_limit),
      window: Keyword.get(opts, :window, @default_window),
      enabled: Keyword.get(opts, :enabled, :app_env)
    }
  end

  @impl true
  def call(conn, %{scope: scope} = opts) do
    if enabled?(opts) do
      case Eden.RateLimit.hit({scope, conn.remote_ip}, opts.window, opts.limit) do
        :ok -> conn
        {:error, :rate_limited} -> reject(conn, scope)
      end
    else
      conn
    end
  end

  defp reject(conn, scope) do
    conn
    |> put_flash(:error, gettext("Too many attempts. Please wait a few minutes and try again."))
    |> redirect(to: retry_path(scope, conn))
    |> halt()
  end

  # Login always bounces to the login page; an invite bounces back to its own page
  # (the POST path equals the invite page path), so the token is preserved.
  defp retry_path(:login, _conn), do: ~p"/login"
  defp retry_path(:invite, conn), do: conn.request_path

  defp enabled?(%{enabled: :app_env}),
    do: Application.get_env(:eden, __MODULE__, [])[:enabled] != false

  defp enabled?(%{enabled: enabled}), do: enabled
end
