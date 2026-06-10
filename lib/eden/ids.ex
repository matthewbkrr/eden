defmodule Eden.Ids do
  @moduledoc """
  Normalizes externally-supplied ids (LiveView params arrive as strings) into
  integers before they reach an Ecto query — `where: x.id == ^"abc"` raises a
  CastError at runtime. Shared by contexts; returns `:error` for anything that
  isn't a clean integer so callers can fall through to `:not_found`.
  """

  def normalize(id) when is_integer(id), do: id

  def normalize(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> :error
    end
  end

  def normalize(_id), do: :error
end
