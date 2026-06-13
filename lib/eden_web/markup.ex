defmodule EdenWeb.Markup do
  @moduledoc """
  A tiny, safe **markdown subset** for chat message bodies (#60): a line-leading
  `#` / `##` / `###` heading plus inline `**bold**`, `*italic*` / `_italic_`,
  `` `code` ``, and bare-URL auto-linking.

  Output is escaped iodata wrapped in `{:safe, _}`: every user-derived run goes
  through `html_escape` and only a fixed whitelist of tags is emitted, so there
  is no HTML-injection path (same posture as the search highlighter). Marks are
  flat (no nesting), pairs only — a lone or unclosed `*`/`_`/`` ` `` renders
  literally, and `*`/`_` that hug whitespace or sit mid-word aren't treated as
  emphasis (so `snake_case` and `a * b` stay plain).

  Messages are single-line (the composer is a text input), so the heading marker
  applies to the whole body; there is no multi-line block parsing.
  """

  @heading ~r/^(\#{1,3})\s+(.+)$/u

  # One left-to-right pass; the first complete marker pair (or URL) wins. Bold
  # (`**`) is tried before italic (`*`). Emphasis can't hug whitespace
  # ((?!\s)/(?<!\s)); `_` must sit on word boundaries so snake_case is left alone.
  @inline ~r/(\*\*(?!\s).+?(?<!\s)\*\*|`[^`]+`|(?<![\p{L}\p{N}_])_(?!\s).+?(?<!\s)_(?![\p{L}\p{N}_])|\*(?!\s).+?(?<!\s)\*|https?:\/\/[^\s<]+)/u

  @doc """
  Renders a message body to safe iodata: a heading wrapper when the body starts
  with `#`/`##`/`###`, otherwise inline formatting only.
  """
  def to_iodata(text) when is_binary(text) do
    case Regex.run(@heading, text) do
      [_, hashes, rest] ->
        {:safe, [~s(<span class="ed-md-h#{byte_size(hashes)}">), inline(rest), "</span>"]}

      nil ->
        {:safe, inline(text)}
    end
  end

  @doc """
  Plain text with markdown markers removed — for the sidebar preview and search
  snippets, where formatting would otherwise leak as raw `**`/`#` characters.
  """
  def strip(text) when is_binary(text) do
    text
    |> String.replace(@heading, "\\2")
    |> String.replace(~r/\*\*(?!\s)(.+?)(?<!\s)\*\*/u, "\\1")
    |> String.replace(~r/`([^`]+)`/u, "\\1")
    |> String.replace(~r/(?<![\p{L}\p{N}_])_(?!\s)(.+?)(?<!\s)_(?![\p{L}\p{N}_])/u, "\\1")
    |> String.replace(~r/\*(?!\s)(.+?)(?<!\s)\*/u, "\\1")
  end

  defp inline(text) do
    @inline
    |> Regex.split(text, include_captures: true)
    |> Enum.map(&token/1)
  end

  defp token(t) do
    cond do
      wrapped?(t, "**") -> wrap("strong", slice(t, 2))
      wrapped?(t, "`") -> wrap("code", slice(t, 1))
      wrapped?(t, "_") -> wrap("em", slice(t, 1))
      wrapped?(t, "*") -> wrap("em", slice(t, 1))
      String.starts_with?(t, "http://") or String.starts_with?(t, "https://") -> link(t)
      true -> escape(t)
    end
  end

  defp wrapped?(t, delim) do
    String.starts_with?(t, delim) and String.ends_with?(t, delim) and
      byte_size(t) > 2 * byte_size(delim)
  end

  defp slice(t, n), do: String.slice(t, n, String.length(t) - 2 * n)

  defp wrap(tag, inner), do: ["<", tag, ">", escape(inner), "</", tag, ">"]

  defp escape(text) do
    {:safe, escaped} = Phoenix.HTML.html_escape(text)
    escaped
  end

  defp link(url) do
    esc = escape(url)

    [
      ~s(<a class="ed-link" href="),
      esc,
      ~s(" target="_blank" rel="noopener noreferrer">),
      esc,
      "</a>"
    ]
  end
end
