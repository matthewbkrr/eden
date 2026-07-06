defmodule EdenWeb.SafePath do
  @moduledoc """
  Validates a user-influenced redirect target as an app-local path (#306 review).

  String prefix checks are not enough: browsers strip ASCII tab/newline from a
  `Location` before parsing (so `"/\\t/evil.example"` becomes protocol-relative
  `//evil.example`), and treat backslashes as slashes. `URI.new/1` parses per
  RFC 3986 — it rejects control characters, spaces, and backslashes outright and
  parses `//host` into a host — so accepting only a parse with no scheme, no
  host, and no userinfo leaves exactly the app-local paths.
  """

  @doc """
  Returns `path` when it is a safe local path (starts with `/`, parses with no
  scheme/host/userinfo), otherwise `fallback`.
  """
  def local_path(path, fallback)

  def local_path("/" <> _ = path, fallback) do
    case URI.new(path) do
      {:ok, %URI{scheme: nil, host: nil, userinfo: nil}} -> path
      _ -> fallback
    end
  end

  def local_path(_other, fallback), do: fallback
end
