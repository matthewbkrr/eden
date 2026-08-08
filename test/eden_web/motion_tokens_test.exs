defmodule EdenWeb.MotionTokensTest do
  # The motion system is three durations and three curves (#517). Nothing enforces that at runtime,
  # so this reads the stylesheet the way a reviewer would and keeps the count from creeping back:
  # the inventory that started this was 29 distinct literals across 122 declarations.
  use ExUnit.Case, async: true

  @css Path.join([__DIR__, "..", "..", "assets", "css", "app.css"])

  # A duration written inside a transition/animation shorthand, i.e. one that times a real change.
  # Delays (`animation-delay`, the second time in `visibility 0s 0.12s`) and infinite loops carry
  # their own meaning and are deliberately not part of the system.
  defp literal_durations(css) do
    css
    # Comments first, and as whole blocks: prose about timings ("~160ms RTT", a note quoting an old
    # declaration) is not a declaration, and a line-by-line filter misses their continuation lines.
    |> String.replace(~r{/\*.*?\*/}s, "")
    |> String.split("\n")
    |> Enum.filter(&String.match?(&1, ~r/(transition|animation)[^:]*:|var\(--ed-ease/))
    # Delays are not durations: a stagger (`animation-delay: 0.15s`) and the second time in
    # `visibility 0s 0.12s` say WHEN, not HOW LONG.
    |> Enum.reject(&String.match?(&1, ~r/(transition|animation)-delay/))
    # One duration per comma-separated part: in a shorthand the FIRST time is the duration and a
    # second one is a delay (`visibility 0s 0.12s` says "switch instantly, 120ms from now"). Taking
    # both would file delays under a rule about durations (#572 review).
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&Regex.run(~r/(?<![\w-])\d*\.?\d+m?s(?![\w-])/, &1))
    |> Enum.reject(&is_nil/1)
    |> List.flatten()
  end

  test "durations in transitions and animations come from the tokens, not from literals" do
    css = File.read!(@css)
    literals = literal_durations(css) |> Enum.frequencies()

    # What may still be written out: the suppressors, and animations that loop or hold on their own
    # clock (the clock hands, the shimmer, the typing dots, the connection pulse).
    allowed = ~w(0s 0.01s 0.01ms 1.2s 1.3s 1.4s 1.6s 19.2s 64s)

    stray = Map.drop(literals, allowed)

    assert stray == %{},
           """
           motion durations outside the token system: #{inspect(stray)}

           Use var(--ed-dur-quick | --ed-dur-move | --ed-dur-screen), or add the value to the
           allow-list above with a reason if it is genuinely its own clock.
           """
  end

  test "the token system itself is three durations and three curves" do
    css = File.read!(@css)

    for token <-
          ~w(--ed-dur-quick --ed-dur-move --ed-dur-screen --ed-ease-out --ed-ease-in --ed-ease-move) do
      assert css =~ "#{token}:", "#{token} is not defined"
    end

    # The old name is gone: it read as "the default easing" and kept landing on exits, which need
    # the opposite profile.
    refute css =~ ~r/--ed-ease:/, "--ed-ease came back; the exits will inherit an entrance curve"
  end
end
