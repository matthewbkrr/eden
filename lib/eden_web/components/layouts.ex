defmodule EdenWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use EdenWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Живой индикатор состояния сокета (#507).

  Висит в корневом layout, а значит на КАЖДОЙ авторизованной и неавторизованной
  странице — в отличие от `flash_group/1`, который жил внутри так и не отрендеренного
  скаффолдного `app/1` (см. #520), из-за чего разрыв связи не показывался нигде и
  оффлайн был неотличим от поломки: тап красил шиммер, тот мерцал 15 с и молча
  откатывался.

  Управляется классами, которые LiveView сам ставит на `<html>`: `phx-client-error`
  (сокет отвалился у клиента) и `phx-server-error` (упал сервер). Поэтому баннеру не
  нужны ни assigns, ни живой сокет — он работает именно тогда, когда сокета нет.
  Разметка статична и CSS-управляема; `aria-live="polite"` объявляет появление, не
  перебивая чтение.
  """
  def connection_banner(assigns) do
    ~H"""
    <div id="ed-conn" class="ed-conn" role="status" aria-live="polite">
      <span class="ed-conn__dot" aria-hidden="true"></span>
      <span class="ed-conn__text ed-conn__text--client">
        {gettext("No connection to ihichat")}
      </span>
      <span class="ed-conn__text ed-conn__text--server">
        {gettext("ihichat is unavailable")}
      </span>
      <span class="ed-conn__sub">{gettext("Reconnecting…")}</span>
    </div>
    """
  end
end
