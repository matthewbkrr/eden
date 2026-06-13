defmodule Eden.Chat.MessageReaction do
  @moduledoc """
  A single emoji reaction by one user on one `Message` (#67). One row per
  `(message, user, emoji)` — the same emoji from the same user toggles off.
  Works for DM and room messages alike (the `Message` machinery is shared).
  """
  use Ecto.Schema
  import Ecto.Changeset

  # The quick-react row shown at the top of the message menu. ⬅ EDIT THIS to
  # change which emoji appear up front (any count; the menu lays them out in a
  # row). Each must stay a real emoji — it's also offered in the full grid.
  @quick ~w(👍 ❤️ 😂 🎉 😮)

  # The rest of the picker, revealed when the "more" chevron expands the grid.
  @more ~w(😀 😅 🙂 😉 😍 😎 🤔 😴 😢 😭 😡 👎 👌 🙏 👏 🙌 💪 🔥 ✨ 🧡 💛 💚 💙 💜 ✅ ❌ ⚡ 💡 📌 📎 🚀 👀 🤝 🎶)

  # The closed set a reaction may be — the single source of truth shared by
  # validation here and the picker the web layer renders (via
  # `Chat.allowed_reactions/0`). The `react` event carries a client-supplied
  # string, so the server enforces this set rather than trust the UI. Deduped so
  # an accidental overlap between @quick and @more can't list an emoji twice.
  @allowed Enum.uniq(@quick ++ @more)

  # How many emoji a user may keep in their personal quick-react row.
  @quick_limit 8

  @doc "The default quick-react row emoji (top of the menu)."
  def quick, do: @quick

  @doc "Max emoji a personal quick-react row may hold."
  def quick_limit, do: @quick_limit

  @doc "Every allowed reaction emoji (quick row first, then the rest)."
  def allowed, do: @allowed

  schema "message_reactions" do
    field :emoji, :string

    belongs_to :message, Eden.Chat.Message
    belongs_to :user, Eden.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(reaction, attrs) do
    reaction
    |> cast(attrs, [:emoji])
    |> update_change(:emoji, &String.trim/1)
    |> validate_required([:emoji])
    |> validate_inclusion(:emoji, @allowed)
    |> assoc_constraint(:message)
    |> assoc_constraint(:user)
    |> unique_constraint(:emoji, name: :message_reactions_message_id_user_id_emoji_index)
  end
end
