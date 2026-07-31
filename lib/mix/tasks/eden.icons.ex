defmodule Mix.Tasks.Eden.Icons do
  @shortdoc "Builds the heroicons sprite from the icons the app actually uses"

  @moduledoc """
  Writes `priv/static/images/icons.svg` — one `<symbol>` per heroicon referenced anywhere in
  `lib/`.

  Why a sprite at all (#511): the stock Tailwind plugin inlines every used icon as a percent-
  encoded data-URI inside a `mask-image` rule, and that lands in the **render-blocking**
  stylesheet. Measured on this app: 86 rules, 89 502 raw bytes, 11 796 gzipped — 39% of the whole
  gzipped CSS, downloaded before the first paint, for artwork most of which is below the fold.

  A sprite is one cacheable file fetched in parallel, and the stylesheet loses the whole block.

  Icons are collected by scanning the source rather than listed by hand, so adding
  `<.icon name="hero-…" />` cannot silently ship an icon that is missing from the sprite —
  and `EdenWeb.IconSpriteTest` fails the build if the sprite is stale.
  """

  use Mix.Task

  @source "deps/heroicons/optimized"
  @target "priv/static/images/icons.svg"

  # Suffix → heroicons directory. Longest suffix first: "-solid" must not be matched by "" first.
  @variants [
    {"-micro", "16/solid"},
    {"-mini", "20/solid"},
    {"-solid", "24/solid"},
    {"", "24/outline"}
  ]

  @impl Mix.Task
  def run(_args) do
    names = used_icon_names()
    symbols = Enum.map(names, &symbol/1)

    sprite =
      ~s(<svg xmlns="http://www.w3.org/2000/svg" style="display:none">) <>
        Enum.join(symbols, "") <> "</svg>"

    File.mkdir_p!(Path.dirname(@target))
    File.write!(@target, sprite)

    Mix.shell().info(
      "eden.icons: #{length(names)} icons -> #{@target} (#{byte_size(sprite)} bytes)"
    )
  end

  @doc "Every `hero-*` name referenced in lib/, sorted. Public so the test can compare."
  def used_icon_names do
    Path.wildcard("lib/**/*.{ex,heex}")
    |> Enum.flat_map(fn file ->
      # The QUOTES are load-bearing. A bare `hero-[a-z0-9-]+` also matches prose: this very file
      # mentions `hero-arrow-up-mini` in a comment below, and it was being shipped as a symbol
      # nobody references (#539 review). Worse, a comment naming an icon that does not exist would
      # fail the build from a line that renders nothing. Every real reference is a string literal —
      # in a template attribute or returned from a helper — so requiring the closing quote keeps
      # all of them and drops the prose. It also rules out a trailing hyphen.
      Regex.scan(~r/"(hero-[a-z0-9-]*[a-z0-9])"/, File.read!(file)) |> Enum.map(&List.last/1)
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp symbol(name) do
    svg = name |> resolve() |> File.read!()

    # Carry the root element's presentation attributes onto the symbol: solid icons paint with
    # `fill="currentColor"`, outline ones with `stroke="currentColor"` and a stroke width. Drop
    # them and every outline icon renders as a filled blob.
    [_, attrs, body] = Regex.run(~r/<svg([^>]*)>(.*)<\/svg>/s, svg)

    kept =
      ~r/(viewBox|fill|stroke|stroke-width)="[^"]*"/
      |> Regex.scan(attrs)
      |> Enum.map_join(" ", &hd/1)

    ~s(<symbol id="#{name}" #{kept}>) <> String.trim(body) <> "</symbol>"
  end

  # `hero-arrow-up-mini` -> {"20/solid", "arrow-up"}. The suffix decides the variant; what is left
  # is the file name.
  defp resolve("hero-" <> rest) do
    {dir, base} =
      Enum.find_value(@variants, fn {suffix, dir} ->
        if suffix == "" or String.ends_with?(rest, suffix) do
          {dir, String.replace_suffix(rest, suffix, "")}
        end
      end)

    path = Path.join([@source, dir, base <> ".svg"])

    # A misspelt name would otherwise surface as `File.read!` raising on a path nobody recognises,
    # halfway through an asset build (#539 review). Say what is actually wrong instead.
    unless File.exists?(path) do
      Mix.raise("""
      no heroicon named hero-#{rest} (looked for #{path}).

      Icon names are read from string literals in lib/. Check the spelling, or the variant suffix:
      no suffix = 24/outline, -solid = 24/solid, -mini = 20/solid, -micro = 16/solid.
      """)
    end

    path
  end
end
