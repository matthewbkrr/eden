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

  # Комментарии и строковые литералы вырезаем ДО разбора: в этом файле есть комментарий
  # с `hero-#\{ICON\}`, то есть фигурные скобки внутри комментария, и брать их за границу
  # правила нельзя (нашло ревью PR #526).
  defp stripped do
    @css
    |> String.replace(~r|/\*.*?\*/|s, "")
    |> String.replace(~r/"[^"\n]*"|'[^'\n]*'/, "\"\"")
  end

  # Разбор со СТЕКОМ вложенности. Первая версия хранила только текущий селектор и ничего
  # не знала о родителях — из-за чего `transition: none` из блока `prefers-reduced-motion`
  # (таких блоков в файле десятки) считался действующим всегда, и тест недо-сообщал:
  # мутация, снявшая отклик у десяти целей, называла пять. Родительскую цепочку теперь
  # видно, и блоки reduced-motion отбрасываются — они описывают предпочтение, которого
  # на обычном устройстве нет.
  defp rules do
    stripped()
    |> String.split(~r/([{}])/, include_captures: true)
    |> Enum.reduce({[], [], nil}, fn
      "{", {acc, stack, pending} -> {acc, [pending || "" | stack], nil}
      "}", {acc, stack, _} -> {acc, Enum.drop(stack, 1), nil}
      text, {acc, stack, _} -> {[entry(stack, text) | acc], stack, String.trim(text)}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.reject(fn {_, _, ancestors} ->
      Enum.any?(ancestors, &String.contains?(&1, "prefers-reduced-motion"))
    end)
  end

  # Текст внутри блока — объявления этого блока; его родители — остаток стека. Побочные
  # записи (селектор следующего правила, попавший сюда же) безвредны: селектор не содержит
  # ни `background:`, ни `transition:`.
  defp entry(stack, text) do
    case stack do
      [sel | ancestors] -> {sel, text, ancestors}
      [] -> {nil, text, []}
    end
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
        Enum.any?(all, fn {sel, body, _} ->
          is_binary(sel) and mentions?(sel, class) and String.contains?(sel, ":active") and
            sets_background?(body)
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
        Enum.any?(all, fn {sel, body, _} ->
          is_binary(sel) and String.contains?(sel, ".#{state}:active") and sets_background?(body)
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

  test "нажатие появляется в первом кадре, а не проявляется переходом" do
    # Самая коварная часть #512, и первая версия этого теста её НЕ ловила: переход
    # объявлен не в правиле `:active`, а на БАЗОВОМ селекторе (`.ed-admin-row
    # { transition: background 0.16s }`), и применяется в том числе к смене фона на
    # нажатии. Подсветка тогда проявляется 160 мс — тот самый лаг, против которого весь
    # #512, только в виде плавного проявления. Значит смотреть надо не в тело `:active`,
    # а на ПОБЕДИТЕЛЯ каскада для нажатого состояния.
    animated =
      Enum.filter(@targets, fn class ->
        case winning_transition(class) do
          nil -> false
          value -> animates_background?(value)
        end
      end)

    assert animated == [],
           "фон под пальцем проявляется переходом у: #{Enum.join(animated, ", ")} — " <>
             "отклик обязан быть в первом кадре; погасите переход в правиле :active"
  end

  # Победитель каскада по свойству `transition` для ПЛОСКОГО элемента в состоянии
  # `:active`: максимум по (специфичность, порядок).
  #
  # «Плоский» — существенно. Первая версия брала максимум среди всех правил, упоминающих
  # класс, и составное правило вроде `.ed-seg__btn.is-active:active` со своим `transition:
  # none` МАСКИРОВАЛО обычное нажатие: мутация, снявшая отклик у десяти целей, не называла
  # сегмент. У элемента несколько состояний, и одного победителя на класс не существует;
  # здесь проверяется самое частое — элемент без дополнительных классов и атрибутов.
  defp winning_transition(class) do
    rules()
    |> Enum.with_index()
    |> Enum.flat_map(fn {{sel, body, _}, order} ->
      with true <- is_binary(sel),
           [_ | _] = parts <- Enum.filter(String.split(sel, ","), &plain?(&1, class)),
           [_, value] <- Regex.run(~r/(?:^|;|\s)transition:\s*([^;]*)/, body) do
        [{Enum.max(Enum.map(parts, &specificity/1)), order, value}]
      else
        _ -> []
      end
    end)
    |> case do
      [] -> nil
      candidates -> candidates |> Enum.max_by(fn {spec, order, _} -> {spec, order} end) |> elem(2)
    end
  end

  # Часть селектора адресует именно этот класс и ничего сверх него: ровно один класс, ни
  # одного атрибута. Псевдоклассы (`:active`, `:not(:disabled)`) допустимы — это состояния
  # того же элемента, а не другой элемент.
  defp plain?(part, class) do
    mentions?(part, class) and
      Regex.scan(~r/\.[\w-]+/, String.replace(part, ~r/:not\([^)]*\)/, " ")) == [[".#{class}"]] and
      not Regex.match?(~r/\[/, part)
  end

  # Классы, атрибуты и псевдоклассы весят по 10; элементы и `::псевдоэлементы` — 1.
  # Идентификаторов в этом файле нет. `:not(...)` сам не считается, считается его содержимое,
  # поэтому обёртку снимаем, а внутренности оставляем.
  defp specificity(part) do
    part = String.replace(part, ~r/:not\(|\)/, " ")
    tens = Regex.scan(~r/\.[\w-]+|\[[^\]]*\]|(?<!:):(?!:)[\w-]+/, part) |> length()
    ones = Regex.scan(~r/(?<![\w.\[-])[a-z]+(?![\w-]*[(\]])|::[\w-]+/, part) |> length()
    tens * 10 + ones
  end

  # Переход трогает фон и длится дольше кадра. `transition: none` и `0s` — не трогает.
  defp animates_background?(value) do
    Regex.match?(~r/\b(background|all)\b/, value) and
      case Regex.run(~r/([\d.]+)s/, value) do
        [_, secs] -> String.to_float(secs) > 0.12
        _ -> false
      end
  end
end
