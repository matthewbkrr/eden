defmodule Eden.Notifications.Adapter do
  @moduledoc """
  Transport behaviour for delivering an **already-gated** notification to a user
  (ADR-0001). Mirrors `Eden.Storage.Adapter`: one `deliver/2` per transport,
  swappable/extendable via config with no caller changes.

  `Eden.Notifications.Web` is the in-tab reference implementation; the planned push
  transports (native desktop app, APNs, FCM, RuStore/VK) are new modules implementing
  the same callback — each resolves `user_id` to its own reach (Web → the live PubSub
  topic; a push adapter → the user's device tokens). Recipient selection is NOT an
  adapter concern: `Eden.Chat` has already decided who should hear (mute / DND /
  thread-following, #213); an adapter only delivers.
  """
  @callback deliver(user_id :: integer, payload :: map) :: :ok
end
