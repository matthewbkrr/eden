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
