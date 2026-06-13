defmodule EdenWeb.CSP do
  @moduledoc """
  A per-request, nonce-based **Content-Security-Policy** for the `:browser`
  pipeline (security follow-up tracked in `CLAUDE.md`).

  Each request gets a fresh random nonce, stashed in `conn.assigns.csp_nonce`
  (the root layout puts it on its one inline `<script>`), and a full policy that
  replaces the minimal default `put_secure_browser_headers` emits.

  **Scripts are nonce-locked** — the real XSS barrier: only `'self'` bundles and
  the nonce'd inline script run, injected `<script>` never does. **Styles allow
  `'unsafe-inline'`** because the UI uses inline `style=""` attributes pervasively
  and nonces don't apply to attributes (style injection is far lower risk than
  script injection). `img-src` allows `data:` (heroicon CSS masks) and `blob:`
  (`live_img_preview` upload previews); the LiveView socket rides `connect-src
  'self'`.
  """
  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    nonce = 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("content-security-policy", policy(nonce))
  end

  defp policy(nonce) do
    Enum.join(
      [
        "default-src 'self'",
        "script-src 'self' 'nonce-#{nonce}'",
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data: blob:",
        "media-src 'self'",
        "font-src 'self'",
        "connect-src 'self'",
        "base-uri 'self'",
        "form-action 'self'",
        "frame-ancestors 'none'",
        "object-src 'none'"
      ],
      "; "
    )
  end
end
