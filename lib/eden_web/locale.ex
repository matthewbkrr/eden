defmodule EdenWeb.Locale do
  @moduledoc """
  UI locale resolution for the browser pipeline and LiveView.

  Resolves a locale (`en`/`ru`) in priority order: the user's saved choice in the
  session, the browser `Accept-Language` header, then the default. It works both
  as a Plug (sets the Gettext locale for the request and persists the resolved
  value in the session) and as a LiveView `on_mount` hook (re-applies the session
  locale inside the LiveView process, which runs separately from the request).
  """
  import Plug.Conn

  @known ~w(en ru)
  @default "en"

  @doc "Supported locale codes."
  def known, do: @known

  @doc "Fallback locale when nothing else resolves."
  def default, do: @default

  @doc "Whether a locale code is supported."
  def supported?(locale), do: locale in @known

  # --- Plug ----------------------------------------------------------------

  def init(opts), do: opts

  def call(conn, _opts) do
    locale = session_locale(conn) || negotiate(conn) || @default
    Gettext.put_locale(locale)

    conn
    |> assign(:locale, locale)
    |> put_session(:locale, locale)
  end

  # --- LiveView on_mount ---------------------------------------------------

  @doc "Re-applies the session locale inside a LiveView process."
  def on_mount(:default, _params, session, socket) do
    Gettext.put_locale(normalize(session["locale"]))
    {:cont, socket}
  end

  # --- Internals -----------------------------------------------------------

  defp session_locale(conn), do: conn |> get_session(:locale) |> normalize_or_nil()

  defp normalize(locale), do: if(locale in @known, do: locale, else: @default)
  defp normalize_or_nil(locale), do: if(locale in @known, do: locale)

  defp negotiate(conn) do
    conn
    |> get_req_header("accept-language")
    |> List.first()
    |> parse_accept_language()
  end

  defp parse_accept_language(nil), do: nil

  defp parse_accept_language(header) do
    header
    |> String.split(",")
    |> Enum.map(fn part ->
      part |> String.split(";") |> List.first() |> String.trim() |> String.downcase()
    end)
    |> Enum.find_value(fn
      "ru" <> _ -> "ru"
      "en" <> _ -> "en"
      _ -> nil
    end)
  end
end
