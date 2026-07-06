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
    |> redirect(to: EdenWeb.SafePath.local_path(params["return_to"], ~p"/settings"))
  end
end
