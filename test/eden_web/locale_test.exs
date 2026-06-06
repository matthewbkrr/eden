defmodule EdenWeb.LocaleTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias EdenWeb.Locale

  defp build(headers, session) do
    conn = init_test_session(conn(:get, "/"), session)
    Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
  end

  describe "helpers" do
    test "known/0 and default/0" do
      assert Locale.known() == ~w(en ru)
      assert Locale.default() == "en"
    end

    test "supported?/1" do
      assert Locale.supported?("ru")
      assert Locale.supported?("en")
      refute Locale.supported?("de")
    end
  end

  describe "call/2" do
    test "a saved session choice wins over Accept-Language" do
      conn = Locale.call(build([{"accept-language", "ru"}], %{"locale" => "en"}), [])
      assert conn.assigns.locale == "en"
      assert get_session(conn, :locale) == "en"
    end

    test "negotiates ru from Accept-Language when no choice is saved" do
      conn = Locale.call(build([{"accept-language", "ru-RU,ru;q=0.9,en;q=0.8"}], %{}), [])
      assert conn.assigns.locale == "ru"
      assert get_session(conn, :locale) == "ru"
    end

    test "negotiates en from Accept-Language" do
      conn = Locale.call(build([{"accept-language", "en-US,en;q=0.9"}], %{}), [])
      assert conn.assigns.locale == "en"
    end

    test "falls back to the default for an unknown Accept-Language" do
      conn = Locale.call(build([{"accept-language", "de-DE,fr;q=0.9"}], %{}), [])
      assert conn.assigns.locale == "en"
    end

    test "ignores an unsupported saved locale and re-negotiates" do
      conn = Locale.call(build([{"accept-language", "ru"}], %{"locale" => "de"}), [])
      assert conn.assigns.locale == "ru"
    end

    test "defaults when there is neither a header nor a choice" do
      conn = Locale.call(build([], %{}), [])
      assert conn.assigns.locale == "en"
    end

    test "applies the resolved locale to Gettext" do
      Locale.call(build([{"accept-language", "ru"}], %{}), [])
      assert Gettext.get_locale() == "ru"
    end
  end

  describe "on_mount/4" do
    test "applies the session locale inside the LiveView process" do
      assert {:cont, _socket} = Locale.on_mount(:default, %{}, %{"locale" => "ru"}, %{})
      assert Gettext.get_locale() == "ru"
    end

    test "falls back to the default when the session has no locale" do
      Gettext.put_locale("ru")
      assert {:cont, _socket} = Locale.on_mount(:default, %{}, %{}, %{})
      assert Gettext.get_locale() == "en"
    end
  end
end
