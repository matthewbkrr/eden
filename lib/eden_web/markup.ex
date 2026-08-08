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
  # `@handle`, on a word boundary so an address (`me@host`) is not a call, and exactly the
  # character set a username may have (`validate_username`) so a trailing comma or full stop ends
  # it. The same rule the CONTEXT resolves by — when the two drifted, `thanks @bob.` was resolved
  # and notified server-side while rendering as plain text (#577 review).
  @mention ~r/(?<![\p{L}\p{N}_])@([a-zA-Z0-9_]{2,})(?![\p{L}\p{N}_])/u

  @inline ~r/(\*\*(?!\s).+?(?<!\s)\*\*|`[^`]+`|(?<![\p{L}\p{N}_])_(?!\s).+?(?<!\s)_(?![\p{L}\p{N}_])|\*(?!\s).+?(?<!\s)\*|https?:\/\/[^\s<]+)/u

  @doc """
  Renders a message body to safe iodata: a heading wrapper when the body starts
  with `#`/`##`/`###`, otherwise inline formatting only.
  """
  def to_iodata(text, mentions \\ [])

  def to_iodata(text, mentions) when is_binary(text) do
    named = named_handles(mentions)

    case Regex.run(@heading, text) do
      [_, hashes, rest] ->
        {:safe, [~s(<span class="ed-md-h#{byte_size(hashes)}">), inline(rest, named), "</span>"]}

      nil ->
        {:safe, inline(text, named)}
    end
  end

  # handle-as-typed => the person's CURRENT handle. Only what the server resolved at send time
  # (#576): a bare `@word` that named nobody, or someone outside the conversation, stays text.
  defp named_handles(mentions) when is_list(mentions) do
    for %{handle: handle, user: %{id: id, username: username}} <- mentions, into: %{} do
      down = String.downcase(handle)
      # `@all` is stored as one row per person (that is how delivery works), but it names the
      # ROOM, not any of them — so it keeps its own label and opens nobody's profile (#576).
      if down == "all",
        do: {down, {"all", nil}},
        else: {down, {username, id}}
    end
  end

  defp named_handles(_), do: %{}

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

  defp inline(text, named) do
    @inline
    |> Regex.split(text, include_captures: true)
    |> Enum.map(&token(&1, named))
  end

  # A resolved `@handle` becomes a chip that opens the person's profile — the same event the
  # avatar uses. Applied only to PLAIN text, so a handle inside code or a URL is left alone.
  defp mentions(text, named) when map_size(named) == 0, do: escape(text)

  defp mentions(text, named) do
    @mention
    |> Regex.split(text, include_captures: true)
    |> Enum.map(&mention_part(&1, named))
  end

  # A part is a mention only when it IS the whole match and the handle was resolved; anything
  # else is text.
  defp mention_part(part, named) do
    with [^part, handle] <- Regex.run(@mention, part) || [],
         {:ok, {label, id}} <- Map.fetch(named, String.downcase(handle)) do
      chip(label, id)
    else
      _ -> escape(part)
    end
  end

  # The chip opens a profile by the person's ID, not by the name printed on it (#577 review): the
  # handle is renameable, so a click resolved by name could land on whoever holds that name at the
  # moment of the click. `@all` names the room rather than a person, so it is a label, not a
  # control — nothing to open.
  defp chip("all", nil), do: [~s(<span class="ed-mention ed-mention--all">@all</span>)]

  defp chip(username, id) do
    [
      ~s(<button type="button" class="ed-mention" phx-click="show_profile" phx-value-id="),
      Integer.to_string(id),
      ~s(">@),
      escape(username),
      "</button>"
    ]
  end

  defp token(t, named) do
    cond do
      # Emphasis carries the mention through: the server resolves `**@bob**` from the raw body and
      # notifies him, so rendering it as styled TEXT would ping a person who then cannot see that
      # he was named (#577 review). Code spans are the exception on purpose — inside backticks
      # everything is literal.
      wrapped?(t, "**") -> wrap("strong", slice(t, 2), named)
      wrapped?(t, "`") -> wrap("code", slice(t, 1))
      wrapped?(t, "_") -> wrap("em", slice(t, 1), named)
      wrapped?(t, "*") -> wrap("em", slice(t, 1), named)
      String.starts_with?(t, "http://") or String.starts_with?(t, "https://") -> link(t)
      true -> mentions(t, named)
    end
  end

  defp wrapped?(t, delim) do
    String.starts_with?(t, delim) and String.ends_with?(t, delim) and
      byte_size(t) > 2 * byte_size(delim)
  end

  defp slice(t, n), do: String.slice(t, n, String.length(t) - 2 * n)

  defp wrap(tag, inner), do: ["<", tag, ">", escape(inner), "</", tag, ">"]

  defp wrap(tag, inner, named), do: ["<", tag, ">", mentions(inner, named), "</", tag, ">"]

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
