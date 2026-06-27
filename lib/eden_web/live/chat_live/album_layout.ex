defmodule EdenWeb.ChatLive.AlbumLayout do
  @moduledoc """
  Pure layout math for a message's attachment album — Telegram-style justified rows
  plus the "this photo is too extreme to show inline" classification.

  Pulled out of the (very large) `EdenWeb.ChatLive` so the recursive row-balancing has
  direct unit tests. The `.SendQueue` colocated hook mirrors `rows/1` + `aspect/1` +
  `strip_photo?/1` in JS so the optimistic upload node lays out identically to this — keep
  the two in sync (see `balanceRows`/`albumAspect`/`isStrip` in chat_live.ex).
  """

  # A photo wider/taller than this (either way) is a strip the dialog can't fit — the time
  # pill overlaps it, and a justified row would squash it to a sliver. Telegram converts such
  # images to a file; we render them as file cards.
  # Tunable: TG itself uses ~20:1, but our inline photo caps at 320px so a tighter bound fits.
  @photo_max_aspect 5.0

  # An album tile's aspect is clamped to this range so one freakish photo can't dominate a row
  # (a near-strip stays readable; a tall one keeps a floor). Strips past @photo_max_aspect never
  # reach here — they're filtered to file cards first.
  @min_aspect 0.5
  @max_aspect 2.6

  @doc """
  Lay a multi-item album out as Telegram-style justified rows.

  Returns a list of `{tiles, aspect_sum}` where `tiles` is a list of `{item, aspect}`: the tile
  takes `flex-grow = aspect`, the row's height = `album_width / aspect_sum`, so the row fills the
  width with each tile at (close to) its own aspect. Rows are balanced by aspect so they come out
  ~equal height; uniform photos still fall out as clean 2x2 / 3x3 grids.
  """
  def rows(media) do
    media
    |> chunk_rows()
    |> Enum.map(fn row ->
      tiles = Enum.map(row, &{&1, aspect(&1)})
      {tiles, tiles |> Enum.map(&elem(&1, 1)) |> Enum.sum() |> Float.round(4)}
    end)
  end

  @doc """
  Whether an attachment is a strip — a photo too wide/tall (> #{@photo_max_aspect}:1 either way)
  to show inline. Such photos render as downloadable file cards instead. Videos and photos with
  unknown dimensions are never strips (they fall back to inline).
  """
  def strip_photo?(%{kind: "image", as_file: false, width: w, height: h})
      when is_integer(w) and is_integer(h) and w > 0 and h > 0,
      do: max(w, h) / min(w, h) > @photo_max_aspect

  def strip_photo?(_attachment), do: false

  @doc "An item's display aspect (width/height), clamped to [#{@min_aspect}, #{@max_aspect}] and
  rounded to 4dp. Missing dimensions fall back to square (1.0)."
  def aspect(%{width: w, height: h})
      when is_integer(w) and is_integer(h) and w > 0 and h > 0,
      do: (w / h) |> max(@min_aspect) |> min(@max_aspect) |> Float.round(4)

  def aspect(_attachment), do: 1.0

  defp chunk_rows([]), do: []

  # Split into the same NUMBER of rows as the count plan, but distribute items so each row's
  # aspect-sum is as even as possible (→ rows of ~equal height). For uniform photos this
  # reproduces the clean count grid; for mixed aspects it groups so heights match better.
  defp chunk_rows(media), do: balance_rows(media, row_count(length(media)))

  defp balance_rows(items, r) when r <= 1, do: [items]

  defp balance_rows(items, r) do
    target = (items |> Enum.map(&aspect/1) |> Enum.sum()) / r
    {row, rest} = take_balanced_row(items, r, target, [], 0.0)
    [row | balance_rows(rest, r - 1)]
  end

  # Fill a row toward `target` aspect-sum — always take ≥1, and always leave ≥1 item for each
  # of the (r-1) remaining rows (so no row ever ends up empty).
  defp take_balanced_row([h | t], r, target, [], _sum),
    do: take_balanced_row(t, r, target, [h], aspect(h))

  defp take_balanced_row(items, r, _target, acc, _sum) when length(items) <= r - 1,
    do: {Enum.reverse(acc), items}

  defp take_balanced_row(items, _r, target, acc, sum) when sum >= target,
    do: {Enum.reverse(acc), items}

  defp take_balanced_row([h | t], r, target, acc, sum),
    do: take_balanced_row(t, r, target, [h | acc], sum + aspect(h))

  # How many rows N media split into (just the length of the count plan below).
  defp row_count(n), do: length(row_sizes(n))

  # Count plan: 1-3 on their own line, 4 as 2+2, then rows of 3 — with a trailing remainder of
  # 1 folded into 2+2 so a row never holds a single lonely tile. Only the COUNT is consumed
  # (chunk_rows re-splits by aspect); the sizes document the intended shape.
  defp row_sizes(n) when n <= 3, do: [n]
  defp row_sizes(4), do: [2, 2]

  defp row_sizes(n) do
    case rem(n, 3) do
      0 -> List.duplicate(3, div(n, 3))
      1 -> List.duplicate(3, div(n, 3) - 1) ++ [2, 2]
      2 -> List.duplicate(3, div(n, 3)) ++ [2]
    end
  end
end
