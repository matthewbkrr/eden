defmodule EdenWeb.IconSpriteTest do
  # The heroicons sprite (#511). Icons used to be inlined into the render-blocking stylesheet as
  # one percent-encoded data-URI per icon — 86 rules, 89 502 raw bytes, 11 796 gzipped, i.e. 39%
  # of the whole gzipped CSS fetched before the first paint. They now live in one cacheable
  # sprite that loads in parallel.
  #
  # The failure mode a sprite invites is drift: someone writes `<.icon name="hero-new-thing" />`,
  # the symbol is missing, and the icon silently renders as nothing — no error, no warning, just
  # a blank space that only a human eye catches. That is what this test exists to prevent, and
  # why the sprite is GENERATED from a scan of the source rather than maintained by hand.
  use ExUnit.Case, async: true

  @sprite "priv/static/images/icons.svg"

  test "every icon the app references has a symbol in the sprite" do
    sprite = File.read!(@sprite)
    used = Mix.Tasks.Eden.Icons.used_icon_names()

    missing = Enum.reject(used, &String.contains?(sprite, ~s(id="#{&1}")))

    assert missing == [],
           "no symbol for: #{Enum.join(missing, ", ")} — run `mix eden.icons` " <>
             "(it is wired into assets.build, so this means the sprite was committed stale)"
  end

  test "no icon name is built at runtime — the scan can only see literals" do
    # The sprite holds what a source scan finds, so a name assembled from pieces
    # (`"hero-\#{kind}-micro"`) would be accepted by the component, missing from the sprite, and
    # render as nothing at all. Today every name is a literal — including the ones returned from
    # helper functions, which the scan still sees. This keeps it that way instead of leaving the
    # guarantee resting on nobody having tried yet (#539 review).
    offenders =
      Path.wildcard("lib/**/*.{ex,heex}")
      |> Enum.flat_map(fn file ->
        File.read!(file)
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} -> Regex.match?(~r/"hero-[^"]*\#\{/, line) end)
        |> Enum.map(fn {_, i} -> "#{file}:#{i}" end)
      end)

    assert offenders == [],
           "icon names assembled at runtime: #{Enum.join(offenders, ", ")} — " <>
             "the sprite is built from a source scan and cannot contain what it cannot see"
  end

  test "the sprite carries the attributes that make an outline icon an outline" do
    sprite = File.read!(@sprite)

    # Solid icons paint with `fill="currentColor"`; outline ones with `stroke="currentColor"` and
    # a stroke width, over `fill="none"`. Convert a <svg> to a <symbol> without carrying those and
    # every outline icon renders as a filled blob — visually wrong, structurally fine, so nothing
    # else would catch it.
    assert sprite =~ ~r/<symbol id="hero-[a-z0-9-]+" [^>]*stroke="currentColor"/,
           "no outline symbol kept its stroke — outline icons will render filled"

    assert sprite =~ ~r/<symbol id="hero-[a-z0-9-]+" [^>]*fill="currentColor"/,
           "no solid symbol kept its fill — solid icons will render invisible"

    assert sprite =~ ~r/viewBox="0 0 \d+ \d+"/, "symbols without a viewBox cannot scale"
  end

  test "the stylesheet no longer carries icon artwork" do
    css = File.read!("assets/css/app.css")

    refute css =~ ~s(@plugin "../vendor/heroicons"),
           "the icon plugin is back — 90 KB of data-URIs return to the blocking stylesheet"

    refute css =~ "data:image/svg+xml;utf8,<svg",
           "an icon is inlined into the stylesheet again"
  end
end
