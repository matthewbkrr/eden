defmodule EdenWeb.ConnectionBannerTest do
  # Индикатор разрыва связи (#507). Живёт в КОРНЕВОМ layout, поэтому проверяем именно то,
  # что было сломано: он присутствует на каждой странице, а не только там, где раньше
  # рендерился скаффолдный Layouts.app — тот не рендерился нигде, из-за чего разрыв не
  # показывался вообще и оффлайн был неотличим от поломки.
  use EdenWeb.ConnCase, async: true

  import Eden.AccountsFixtures

  test "баннер есть на неавторизованной странице", %{conn: conn} do
    html = conn |> get(~p"/login") |> then(& &1.resp_body)

    assert html =~ ~s(id="ed-conn")
    assert html =~ "No connection to ihichat"
    assert html =~ "Reconnecting"
  end

  test "баннер есть на авторизованной странице", %{conn: conn} do
    html = conn |> log_in_user(user_fixture()) |> get(~p"/app") |> then(& &1.resp_body)

    assert html =~ ~s(id="ed-conn")
    assert html =~ "No connection to ihichat"
  end

  test "оба текста в разметке — выбирает CSS по классу на <html>, не сервер", %{conn: conn} do
    html = conn |> get(~p"/login") |> then(& &1.resp_body)

    # Тексты обоих состояний присутствуют всегда. Решать, какой показать, обязан CSS по
    # классу, который LiveView ставит на <html>: при разорванном сокете серверу нас уже
    # не переубедить, поэтому серверная ветка здесь была бы бесполезна.
    assert html =~ "ed-conn__text--client"
    assert html =~ "ed-conn__text--server"
    assert html =~ "ihichat is unavailable"
  end

  test "баннер объявляет себя ассистивным технологиям", %{conn: conn} do
    html = conn |> get(~p"/login") |> then(& &1.resp_body)

    assert html =~ ~s(role="status")
    assert html =~ ~s(aria-live="polite")
  end

  test "строки переведены на русский", %{conn: conn} do
    # Локаль берётся из сессии (`EdenWeb.Locale.call/2`), поэтому русский путь проверяем
    # отдельно — заодно это тест на сами msgstr, добавленные вручную в default.po.
    html =
      conn
      |> Plug.Test.init_test_session(%{"locale" => "ru"})
      |> get(~p"/login")
      |> then(& &1.resp_body)

    assert html =~ "Нет связи с ihichat"
    assert html =~ "ihichat недоступен"
    assert html =~ "Восстанавливаем соединение"
  end
end
