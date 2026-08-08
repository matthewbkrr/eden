defmodule EdenWeb.HookRegistryTest do
  # Every `phx-hook` in the templates names a hook that actually exists (#511).
  #
  # #510 moved forty hooks out of the LiveViews and renamed them: `phx-hook=".Lightbox"`, resolved
  # against the compiling module, became the global `phx-hook="Lightbox"`. A site missed by that
  # rename does not fail to compile and does not fail to render — LiveView writes
  # `unknown hook found for "…"` to the browser console and the element simply does nothing. Three
  # of them shipped that way, and no test in the suite could have noticed.
  #
  # So this one reads the templates and the registries and asserts they agree. It is deliberately
  # source-level: the alternative is a browser test per hook, and the failure mode is a NAME, not
  # behaviour.
  use ExUnit.Case, async: true

  @imports ["assets/js/hooks/index.js", "assets/js/shared_hooks.js"]
  @deferred "assets/js/hooks/deferred.js"

  # Names registered in JavaScript: what the eager index imports, what the signed-out bundle
  # exports, and the deferred list.
  defp global_names do
    imported =
      Enum.flat_map(@imports, fn path ->
        source = File.read!(path)

        Regex.scan(~r/^import (\w+) from "\.\/(?:hooks\/)?\w+"/m, source)
        |> Enum.map(&Enum.at(&1, 1))
        |> Enum.concat(
          Regex.scan(~r/^export (?:const|function) (\w+)/m, source)
          |> Enum.map(&Enum.at(&1, 1))
        )
      end)

    MapSet.new(imported ++ deferred_names())
  end

  # Read from the DEFERRED array alone, not from the file. Scanning every quoted string on its own
  # line took the gesture names (`"pointerdown"`, `"keydown"`, …) for registered hooks, so
  # `phx-hook="keydown"` would have passed this test (#578 review).
  defp deferred_names do
    @deferred
    |> File.read!()
    |> then(&Regex.run(~r/export const DEFERRED = \[(.*?)\]/s, &1))
    |> Enum.at(1)
    |> then(&Regex.scan(~r/"([A-Za-z0-9]+)"/, &1))
    |> Enum.map(&Enum.at(&1, 1))
  end

  # Colocated hooks still declared in an .ex file, under their full LiveView-resolved name
  # (`EdenWeb.Notifier` + `.Notifier` → `EdenWeb.Notifier.Notifier`).
  defp colocated do
    source_files()
    |> Enum.flat_map(&declared_in/1)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp declared_in(path) do
    source = File.read!(path)

    case Regex.run(~r/^defmodule ([\w.]+) do/m, source) do
      [_, module] ->
        Regex.scan(~r/ColocatedHook\}? name="\.(\w+)"/, source)
        |> Enum.map(fn [_, name] -> {module, name} end)

      _ ->
        []
    end
  end

  defp source_files do
    Path.wildcard("lib/**/*.ex") ++ Path.wildcard("lib/**/*.heex")
  end

  defp module_of(path) do
    case Regex.run(~r/^defmodule ([\w.]+) do/m, File.read!(path)) do
      [_, module] -> module
      _ -> nil
    end
  end

  test "no template names a hook that nothing registers" do
    globals = global_names()
    colocated = colocated()
    declared_full = for {mod, names} <- colocated, n <- names, do: "#{mod}.#{n}"
    declared_full = MapSet.new(declared_full)

    stale =
      for path <- source_files(),
          [_, name] <- Regex.scan(~r/phx-hook="([^"{]+)"/, File.read!(path)),
          not valid?(name, path, globals, colocated, declared_full),
          do: "#{path}: phx-hook=\"#{name}\""

    assert stale == [],
           """
           These elements name a hook nothing provides. LiveView logs `unknown hook found` and the
           element is inert — the exact way #510's rename left three of them behind:

           #{Enum.join(stale, "\n")}
           """
  end

  # A bare name has to be in the JS registry. A dotted one is colocated: a leading dot resolves
  # against THIS file's module, a full name against the module it spells out.
  defp valid?("." <> name, path, _globals, colocated, _declared_full) do
    name in Map.get(colocated, module_of(path), [])
  end

  defp valid?(name, _path, globals, _colocated, declared_full) do
    if String.contains?(name, ".") do
      MapSet.member?(declared_full, name)
    else
      MapSet.member?(globals, name)
    end
  end
end
