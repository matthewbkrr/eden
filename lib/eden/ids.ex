defmodule Eden.Ids do
  @moduledoc """
  Normalizes externally-supplied ids (LiveView params arrive as strings) into
  integers before they reach an Ecto query — `where: x.id == ^"abc"` raises a
  CastError at runtime. Shared by contexts; returns `:error` for anything that
  isn't a clean integer so callers can fall through to `:not_found`.

  "Clean" includes fitting in a **bigint** (#494). `Integer.parse/1` happily returns
  99999999999999999999999999, which passes every "is it a number" check and then blows up
  one layer deeper with a `DBConnection.EncodeError` from Postgrex — the same crash this
  module exists to prevent, just further down. Anything outside the column's range cannot
  name a row, so it is `:error` here.
  """

  # Postgres bigserial / bigint bounds — the type every id column in this schema uses.
  @min -9_223_372_036_854_775_808
  @max 9_223_372_036_854_775_807

  def normalize(id) when is_integer(id) and id >= @min and id <= @max, do: id
  def normalize(id) when is_integer(id), do: :error

  def normalize(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> normalize(int)
      _ -> :error
    end
  end

  def normalize(_id), do: :error
end
