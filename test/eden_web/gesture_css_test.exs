defmodule EdenWeb.GestureCssTest do
  # Gesture ownership (#515). `touch-action` was declared NOWHERE in this project, so every touch
  # began life as a candidate for a native two-axis pan while every horizontal recogniser we have
  # is passive or document-level and cannot cancel it. On a swipe-to-reply the row then moves on
  # the main thread while the list keeps panning on the compositor, and the two drift apart.
  #
  # This is a presence check, and deliberately a plain one: unlike the `:active` rules of #512,
  # `touch-action` appears nowhere else in the stylesheet, so there is no cascade to resolve —
  # either the axis is declared for these elements or it is not. Whether the gesture FEELS right
  # is a device check; the PR carries the steps.
  use ExUnit.Case, async: true

  @css File.read!(Path.join(__DIR__, "../../assets/css/app.css"))

  # selector => the axis it must claim
  @axes %{
    "#message-scroll" => "pan-y",
    "#thread-scroll" => "pan-y",
    ".ed-bubble" => "pan-y",
    ".ed-flat" => "pan-y",
    ".ed-convo-wrap" => "pan-y",
    ".ed-folders" => "pan-x",
    ".ed-lightbox__strip" => "pan-x",
    ".ed-gallery-tabs" => "pan-x",
    ".ed-lightbox__stage" => "none"
  }

  # Every declaration that applies to this selector, joined. A selector appears in many rules
  # (`.ed-bubble` has a base rule, modifiers, media queries), and the first match is rarely the
  # one carrying the property — so collect them all rather than guess which.
  defp rules_for(selector) do
    ~r/([^{}]+)\{([^{}]*)\}/
    |> Regex.scan(@css)
    |> Enum.filter(fn [_, sel, _] -> mentions?(sel, selector) end)
    |> Enum.map_join("\n", fn [_, _, body] -> body end)
  end

  # `.ed-bubble` must not match `.ed-bubble--me`; `#message-scroll` must not match a longer id.
  defp mentions?(sel, target),
    do: Regex.match?(~r/#{Regex.escape(target)}(?![\w-])/, sel)

  test "every surface that competes for a touch declares which axis it owns" do
    missing =
      Enum.reject(@axes, fn {selector, axis} ->
        rules_for(selector) =~ ~r/touch-action:\s*#{Regex.escape(axis)}/
      end)

    assert missing == [],
           "no touch-action on: #{Enum.map_join(missing, ", ", &elem(&1, 0))} — " <>
             "the browser has no way to learn the horizontal axis is not its own"
  end

  test "pinch stays available where the page can be zoomed" do
    # `pan-y` alone would also kill pinch. It is preserved explicitly, and it has to be: the
    # viewport meta carries no `user-scalable=no`, so zoom is a real affordance here.
    for selector <- ["#message-scroll", ".ed-bubble", ".ed-flat", ".ed-convo-wrap"] do
      assert rules_for(selector) =~ "pinch-zoom",
             "#{selector} claims pan-y without pinch-zoom — that silently removes zoom"
    end
  end

  test "the row is promoted for the gesture only, never statically" do
    # A static `will-change: transform` on .ed-bubble/.ed-flat would give every one of ~200
    # rendered rows its own compositor layer. The hook sets it when a drag starts and clears it
    # in reset(), so the stylesheet must NOT carry it for rows.
    for selector <- [".ed-bubble", ".ed-flat"] do
      refute rules_for(selector) =~ "will-change",
             "#{selector} promotes itself statically — that is a layer per rendered row"
    end

    hooks = File.read!(Path.join(__DIR__, "../../lib/eden_web/live/chat_live.ex"))
    assert hooks =~ ~s(this.el.style.willChange = "transform")
    assert hooks =~ ~s(this.el.style.willChange = "")
  end
end
