defmodule EdenWeb.ErrorHTML do
  @moduledoc """
  Renders HTML error pages. 404 and 500 get a small branded page; any other
  status falls back to a plain status message. The page is fully self-contained
  (inline styles) so it still renders when assets are unavailable — e.g. mid-500.
  """
  use EdenWeb, :html

  def render("404.html", _assigns) do
    page("404", gettext("Page not found"), gettext("This page doesn't exist or has moved."))
  end

  def render("500.html", _assigns) do
    page(
      "500",
      gettext("Something went wrong"),
      gettext("An unexpected error occurred. Try again in a moment.")
    )
  end

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end

  defp page(code, title, body) do
    """
    <!DOCTYPE html>
    <html lang="#{Gettext.get_locale()}">
    <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>#{title} · eden</title>
    <style>
      :root { color-scheme: dark; }
      html, body { height: 100%; margin: 0; }
      body {
        display: grid; place-items: center; padding: 24px;
        background: oklch(0.18 0.012 261); color: oklch(0.96 0.005 261);
        font: 400 15px/1.5 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
      }
      .wrap { max-width: 26rem; text-align: center; }
      .code { font: 600 13px/1 ui-monospace, SFMono-Regular, Menlo, monospace;
        letter-spacing: 0.08em; color: oklch(0.62 0.16 261); }
      h1 { margin: 12px 0 8px; font-size: 1.375rem; font-weight: 650; }
      p { margin: 0 0 24px; color: oklch(0.68 0.012 261); }
      a { display: inline-flex; align-items: center; height: 36px; padding: 0 16px;
        border-radius: 10px; background: oklch(0.62 0.16 261); color: oklch(0.99 0.01 261);
        text-decoration: none; font-weight: 550; }
    </style>
    </head>
    <body>
      <div class="wrap">
        <div class="code">#{code}</div>
        <h1>#{title}</h1>
        <p>#{body}</p>
        <a href="/app">#{gettext("Back to eden")}</a>
      </div>
    </body>
    </html>
    """
  end
end
