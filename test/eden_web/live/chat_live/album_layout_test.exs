defmodule EdenWeb.ChatLive.AlbumLayoutTest do
  use ExUnit.Case, async: true

  alias EdenWeb.ChatLive.AlbumLayout

  # A fake attachment — only the fields the layout reads.
  defp att(w, h, opts \\ []),
    do: %{
      width: w,
      height: h,
      kind: Keyword.get(opts, :kind, "image"),
      as_file: Keyword.get(opts, :as_file, false)
    }

  # The intended row count per N (the count plan: 1-3 alone, 4 as 2+2, then rows of 3 with a
  # trailing 1 folded into 2+2). rows/1 must always produce exactly this many rows.
  @row_counts %{1 => 1, 2 => 1, 3 => 1, 4 => 2, 5 => 2, 6 => 2, 7 => 3, 8 => 3, 9 => 3, 10 => 4}

  describe "aspect/1" do
    test "is width/height, rounded to 4dp" do
      assert AlbumLayout.aspect(att(1600, 900)) == Float.round(1600 / 900, 4)
    end

    test "clamps to [0.5, 2.6] so one freakish photo can't dominate a row" do
      # 4:1 is past the max; 1:4 past the min — but these never reach a row (strips are
      # filtered first), so the clamp is the safety net for in-range-but-extreme tiles.
      assert AlbumLayout.aspect(att(2000, 500)) == 2.6
      assert AlbumLayout.aspect(att(500, 2000)) == 0.5
    end

    test "falls back to square when dimensions are missing or non-positive" do
      assert AlbumLayout.aspect(att(nil, nil)) == 1.0
      assert AlbumLayout.aspect(att(0, 100)) == 1.0
      assert AlbumLayout.aspect(%{}) == 1.0
    end
  end

  describe "strip_photo?/1" do
    test "true for a photo past 5:1 either way" do
      assert AlbumLayout.strip_photo?(att(1600, 150))
      assert AlbumLayout.strip_photo?(att(150, 1600))
    end

    test "false exactly at the 5:1 boundary (strictly greater)" do
      refute AlbumLayout.strip_photo?(att(1000, 200))
      assert AlbumLayout.strip_photo?(att(1001, 200))
    end

    test "false for normal aspects, videos, as_file photos and unknown dims" do
      refute AlbumLayout.strip_photo?(att(800, 600))
      refute AlbumLayout.strip_photo?(att(1600, 150, kind: "video"))
      refute AlbumLayout.strip_photo?(att(1600, 150, as_file: true))
      refute AlbumLayout.strip_photo?(att(nil, nil))
    end
  end

  describe "rows/1" do
    test "an empty album yields no rows" do
      assert AlbumLayout.rows([]) == []
    end

    test "for every 1..10, it consumes all items, leaves no empty row, and hits the row count" do
      for {n, expected_rows} <- @row_counts do
        items = for i <- 1..n, do: att(100 * i, 100)
        rows = AlbumLayout.rows(items)

        assert length(rows) == expected_rows, "n=#{n}: expected #{expected_rows} rows"
        refute Enum.any?(rows, fn {tiles, _sum} -> tiles == [] end), "n=#{n}: empty row"

        flat = Enum.flat_map(rows, fn {tiles, _sum} -> Enum.map(tiles, &elem(&1, 0)) end)
        assert length(flat) == n, "n=#{n}: items dropped/duplicated"
        # Order is preserved across the split (tiles never reshuffle).
        assert flat == items, "n=#{n}: order changed"
      end
    end

    test "uniform photos reproduce the clean count grid (5 -> [3,2], 7 -> [3,2,2])" do
      sizes = fn n ->
        for(_ <- 1..n, do: att(100, 100)) |> AlbumLayout.rows() |> Enum.map(&length(elem(&1, 0)))
      end

      assert sizes.(4) == [2, 2]
      assert sizes.(5) == [3, 2]
      assert sizes.(6) == [3, 3]
      assert sizes.(7) == [3, 2, 2]
      assert sizes.(9) == [3, 3, 3]
    end

    test "each row carries its aspect-sum (= sum of tile aspects, rounded)" do
      [{tiles, sum}] = AlbumLayout.rows([att(2000, 1000), att(1000, 1000)])
      # 2:1 clamps to 2.0, 1:1 is 1.0 -> sum 3.0.
      assert Enum.map(tiles, &elem(&1, 1)) == [2.0, 1.0]
      assert sum == 3.0
    end

    test "mixed aspects still produce a valid partition into the planned row count" do
      # One near-strip among squares: still 2 rows, all consumed, order intact.
      items = [att(2000, 800), att(100, 100), att(100, 100), att(100, 100)]
      rows = AlbumLayout.rows(items)

      assert length(rows) == 2
      refute Enum.any?(rows, fn {tiles, _} -> tiles == [] end)
      flat = Enum.flat_map(rows, fn {tiles, _} -> Enum.map(tiles, &elem(&1, 0)) end)
      assert flat == items
    end
  end
end
