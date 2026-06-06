defmodule Eden.Accounts.Scope do
  @moduledoc """
  The authorization scope for a request/LiveView (Phoenix 1.8 pattern).

  Carries the authenticated `user` (or nil). Contexts take a `%Scope{}` so queries
  are always scoped to the current actor — addressing broken access control by
  construction. Build it with `for_user/1`; never assemble it ad hoc.
  """
  alias Eden.Accounts.User

  defstruct user: nil

  @doc "Builds a scope for a signed-in user, or nil when there is none."
  def for_user(%User{} = user), do: %__MODULE__{user: user}
  def for_user(nil), do: nil
end
