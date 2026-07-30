defmodule EdenWeb.TapResponseCssTest do
  # Отклик на нажатие (#512). Tailwind preflight снимает `-webkit-tap-highlight-color`
  # глобально, а ховер на таче не работает — значит без явного `:active` точка касания
  # не отвечает НИЧЕМ до ответа сервера, и на RTT ~160 мс это читается как мёртвая кнопка.
  #
  # Что этот тест проверяет и чего НЕТ. Он держит два инварианта, которые ломаются молча:
  # правило объявлено, и у «уже выбранных» состояний есть составной вариант. Он НЕ
  # доказывает, что нажатие видно на экране — для этого нужен рендер состояния `:active`,
  # которое браузер держит только под живым пальцем. Путь через CDP `forcePseudoState`
  # я пробовал и отверг: `nodeId` устаревает, потому что LiveView перерисовывает узел
  # между запросом и форсированием, а сравнение вычисленных цветов обманчиво —
  # `rgba(0, 0, 0, 0)` и `oklab(0 0 0 / 0)` это разные строки и один и тот же прозрачный
  # цвет, из-за чего проверка давала ложную зелень. Визуальная проверка — ручная,
  # на устройстве, шаги расписаны в PR.
  use ExUnit.Case, async: true

  @css File.read!(Path.join(__DIR__, "../../assets/css/app.css"))

  # Точки касания, которых коснулся #512. Строка чата (`.ed-convo--active:active`) и
  # пузыри сообщений имели свои правила до нас и здесь не перечислены.
  @targets ~w(
    ed-btn ed-btn--icon ed-btn--secondary ed-menu__item ed-react ed-gallery-tab ed-thread-row
    ed-member-row ed-lightbox__btn ed-lightbox__nav ed-select-hit
    ed-settings-nav__item ed-seg__btn ed-admin-row ed-room ed-file
  )

  # Состояния «этот элемент уже выбран», чей фон задаётся ПОЗЖЕ общего блока и при равной
  # специфичности (0-2-0) перебивает простой `:active`: нажатие на уже открытый раздел
  # настроек, активный сегмент и выделенную строку админки не давало отклика вовсе.
  # Лечится составным селектором (0-3-0) — он выигрывает независимо от порядка строк.
  @selected_states [
    "ed-settings-nav__item.is-active",
    "ed-seg__btn.is-active",
    "ed-admin-row.is-selected"
  ]

  # Разбор с учётом вложенности (@layer/@media): объявления правила — это текст между `{`
  # и следующей фигурной скобкой в любую сторону, а селектор — чанк перед этим `{`. Наивное
  # «тело до первой `}`» приписало бы вложенные правила самому @media.
  defp rules do
    @css
    |> String.split(~r/([{}])/, include_captures: true)
    |> Enum.reduce({[], nil, nil}, fn
      # Открылся блок: селектор — предыдущий текстовый чанк, следующий станет телом.
      "{", {acc, prev, _} -> {acc, prev, :body}
      "}", {acc, _, _} -> {acc, nil, nil}
      text, {acc, sel, :body} -> {[{sel, text} | acc], String.trim(text), nil}
      text, {acc, _, _} -> {acc, String.trim(text), nil}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # Отклик — это либо фон, либо `filter`: у `.ed-btn--secondary` база уже surface-2, и
  # фоном его не выразить, поэтому и ховер, и нажатие лифтят brightness.
  defp sets_background?(body),
    do: Regex.match?(~r/(^|;|\s)(background|filter)\s*:/, body)

  # `.ed-btn` не должен совпадать с `.ed-btn--icon`: граница — не буква, не цифра, не дефис.
  defp mentions?(sel, class), do: Regex.match?(~r/\.#{Regex.escape(class)}(?![\w-])/, sel)

  test "у каждой точки касания есть правило :active, задающее фон" do
    all = rules()

    missing =
      Enum.reject(@targets, fn class ->
        Enum.any?(all, fn {sel, body} ->
          mentions?(sel, class) and String.contains?(sel, ":active") and sets_background?(body)
        end)
      end)

    assert missing == [],
           "нет правила :active с фоном у: #{Enum.join(missing, ", ")} — " <>
             "на таче эти точки не отвечают вовсе, tap-highlight снят preflight-ом"
  end

  test "у «уже выбранных» состояний есть свой :active — иначе нажатие проигрывает по каскаду" do
    all = rules()

    missing =
      Enum.reject(@selected_states, fn state ->
        Enum.any?(all, fn {sel, body} ->
          String.contains?(sel, ".#{state}:active") and sets_background?(body)
        end)
      end)

    assert missing == [],
           "нет составного :active у: #{Enum.join(missing, ", ")} — " <>
             "их фон объявлен позже общего блока и при равной специфичности перебивает " <>
             "простой :active, так что нажатие на выбранный элемент молча немо"
  end

  test "индикатор загрузки LiveView виден и не трогает строку чата" do
    # `phx-click-loading` навешивается синхронно внутри putRef, ДО отправки в сокет — это
    # единственный отклик, который вообще не зависит от RTT. У строки чата он отключён:
    # там уже есть свой мгновенный скелетон (#428), и гашение поверх него мигало.
    assert @css =~ ~r/\.phx-click-loading,\s*\n?\s*\.phx-submit-loading\s*\{/
    assert @css =~ ~r/\.ed-convo\.phx-click-loading\s*\{[^}]*opacity:\s*1/
  end

  test "нажатие не анимируется дольше кадра" do
    # Отклик обязан быть мгновенным: перехода на фоне либо нет, либо он короче ~120 мс,
    # иначе «мгновенная» подсветка сама превращается в задержку.
    long =
      rules()
      |> Enum.filter(fn {sel, body} ->
        String.contains?(sel, ":active") and
          case Regex.run(~r/transition:[^;]*?([\d.]+)s/, body) do
            [_, secs] -> String.to_float(secs) > 0.12
            _ -> false
          end
      end)

    assert long == [], "слишком долгий переход на :active: #{inspect(long)}"
  end
end
