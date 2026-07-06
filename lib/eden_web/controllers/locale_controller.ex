defmodule EdenWeb.LocaleController do
  @moduledoc """
  Persists the user's UI language choice in the session, then returns them to the
  page they came from. The actual locale is applied per-request by `EdenWeb.Locale`.
  """
  use EdenWeb, :controller

  def update(conn, %{"locale" => locale} = params) do
    locale = if EdenWeb.Locale.supported?(locale), do: locale, else: EdenWeb.Locale.default()

    conn
    |> put_session(:locale, locale)
    |> redirect(to: return_to(params))
  end

  # Only allow local paths to avoid an open-redirect via `return_to`. Normalise
  # backslashes first: a browser reads "/\evil.example" as protocol-relative
  # "//evil.example", which a bare "//" check would miss.
  defp return_to(%{"return_to" => "/" <> _ = path}) do
    if path |> String.replace("\\", "/") |> String.starts_with?("//"),
      do: ~p"/settings",
      else: path
  end

  defp return_to(_params), do: ~p"/settings"
end
