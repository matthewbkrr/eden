defmodule EdenWeb.SettingsLiveTest do
  use EdenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders in English when the locale is en", %{conn: conn} do
    conn = Plug.Test.init_test_session(conn, %{"locale" => "en"})
    {:ok, _view, html} = live(conn, ~p"/settings")

    assert html =~ "Settings"
    assert html =~ "Appearance"
    assert html =~ "Interface language"
    # language option labels are shown in their own language, untranslated
    assert html =~ "English"
    assert html =~ "Русский"
  end

  test "renders in Russian when the locale is ru", %{conn: conn} do
    conn = Plug.Test.init_test_session(conn, %{"locale" => "ru"})
    {:ok, _view, html} = live(conn, ~p"/settings")

    assert html =~ "Настройки"
    assert html =~ "Внешний вид"
    assert html =~ "Язык интерфейса"
  end
end
