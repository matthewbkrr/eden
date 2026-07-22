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

  describe "Russian translations (#367)" do
    @backend EdenWeb.Gettext

    setup do
      Gettext.put_locale(@backend, "ru")
      :ok
    end

    defp t(msgid), do: Gettext.gettext(@backend, msgid)
    defp err(msgid), do: Gettext.dgettext(@backend, "errors", msgid)

    test "the six auth flashes are localized (R099)" do
      assert t("You must log in to access this page.") ==
               "Необходимо войти, чтобы открыть эту страницу."

      assert t("You don't have access to that page.") == "У вас нет доступа к этой странице."
      assert t("Turn on two-factor authentication to use the admin panel.") =~ "двухфакторную"
      assert t("Your session ended. Please sign in again.") == "Сессия завершена. Войдите снова."
      assert t("Your admin access was removed.") == "Ваши права администратора отозваны."
    end

    test "changeset errors are localized, plural forms included (R101)" do
      assert err("can't be blank") == "Обязательное поле"
      assert err("has already been taken") == "Уже занято"
      assert err("is invalid") == "Некорректное значение"

      # Russian has three plural forms (one / few / many) — cover all three buckets.
      at_least = fn n ->
        Gettext.dngettext(
          @backend,
          "errors",
          "should be at least %{count} character(s)",
          "should be at least %{count} character(s)",
          n,
          %{count: n}
        )
      end

      assert at_least.(1) == "должно быть не меньше 1 символа"
      assert at_least.(3) == "должно быть не меньше 3 символов"
      assert at_least.(8) == "должно быть не меньше 8 символов"
    end

    test "the DM/group glossary is unified to «чат» (R206/R208)" do
      assert t("New chat") == "Новый чат"
      assert t("No chat selected") == "Чат не выбран"
      assert t("Couldn't start the chat.") == "Не удалось начать чат."
    end

    test "wording is softened (R207)" do
      assert t("Skip for now") == "Пропустить"
      assert t("Reactivate account") == "Восстановить аккаунт"
    end
  end

  test "errors.po has no untranslated msgstr — guards against a future extract wiping them (R101)" do
    content = File.read!("priv/gettext/ru/LC_MESSAGES/errors.po")
    # Only the file header (the block for the empty msgid) may carry an empty msgstr.
    empties = Regex.scan(~r/^msgstr(\[\d\])? ""$/m, content)

    assert length(empties) == 1,
           "errors.po should carry only the header empty msgstr, found #{length(empties)}"
  end
end
