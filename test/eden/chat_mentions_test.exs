defmodule Eden.ChatMentionsTest do
  @moduledoc """
  `@`-mentions (#576): who a message names, and what that survives.
  """
  use Eden.DataCase, async: true

  import Eden.AccountsFixtures

  alias Eden.{Accounts, Chat, Repo}
  alias Eden.Accounts.Scope

  defp scope(user), do: Scope.for_user(user)

  defp dm(alice, bob) do
    {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
    conv
  end

  defp mentions_of(message) do
    # force: the struct handed in may already carry a stale association from an earlier read,
    # and the point of several of these tests is what the row says NOW.
    message = Repo.preload(message, [mentions: :user], force: true)
    Enum.map(message.mentions, & &1.user.username) |> Enum.sort()
  end

  describe "resolving" do
    test "names a member of the conversation" do
      alice = user_fixture(%{username: "alice"})
      bob = user_fixture(%{username: "bob"})
      conv = dm(alice, bob)

      {:ok, message} =
        Chat.create_message(scope(alice), conv.id, %{"body" => "@bob look at this"})

      assert mentions_of(message) == ["bob"]
    end

    test "an outsider's handle stays plain text" do
      alice = user_fixture(%{username: "alice"})
      bob = user_fixture(%{username: "bob"})
      _stranger = user_fixture(%{username: "carol"})
      conv = dm(alice, bob)

      {:ok, message} = Chat.create_message(scope(alice), conv.id, %{"body" => "@carol hello"})

      assert mentions_of(message) == [],
             "a handle outside the conversation must not become a mention — it could notify someone who cannot even read the message"
    end

    test "the same handle twice names the person once" do
      alice = user_fixture(%{username: "alice"})
      bob = user_fixture(%{username: "bob"})
      conv = dm(alice, bob)

      {:ok, message} = Chat.create_message(scope(alice), conv.id, %{"body" => "@bob @bob @bob"})

      assert mentions_of(message) == ["bob"]
    end

    test "an email or a mid-word @ is not a mention" do
      alice = user_fixture(%{username: "alice"})
      bob = user_fixture(%{username: "bob"})
      conv = dm(alice, bob)

      {:ok, message} =
        Chat.create_message(scope(alice), conv.id, %{"body" => "write to me@bob.example"})

      assert mentions_of(message) == [],
             "`me@bob` is an address, not a call — the handle must start on a word boundary"
    end
  end

  describe "surviving a rename" do
    test "the mention still names the same person, under their new handle" do
      alice = user_fixture(%{username: "alice"})
      bob = user_fixture(%{username: "bob"})
      conv = dm(alice, bob)

      {:ok, message} = Chat.create_message(scope(alice), conv.id, %{"body" => "@bob ping"})
      assert mentions_of(message) == ["bob"]

      {:ok, _} = Accounts.update_username(bob, %{"username" => "robert"})

      # The body still reads "@bob" — that is what was typed — but the mention is a row against
      # the PERSON, so it now carries their current handle. Text would have followed the name.
      assert mentions_of(message) == ["robert"]
      assert Repo.reload(message).body == "@bob ping"
    end
  end

  describe "delivery" do
    setup do
      # The in-tab adapter broadcasts on the notify topic; subscribing IS how a session hears.
      :ok
    end

    defp notify_topic(user), do: "user:#{user.id}:notify"

    test "a mention reaches someone who muted the chat; an ordinary message does not" do
      alice = user_fixture(%{username: "alice"})
      bob = user_fixture(%{username: "bob"})
      conv = dm(alice, bob)

      {:ok, _} = Chat.toggle_conversation_mute(scope(bob), conv.id)
      Phoenix.PubSub.subscribe(Eden.PubSub, notify_topic(bob))

      {:ok, _} = Chat.create_message(scope(alice), conv.id, %{"body" => "just talking"})
      refute_receive {:notify, _}, 200, "mute must still silence an ordinary message"

      {:ok, _} = Chat.create_message(scope(alice), conv.id, %{"body" => "@bob look"})

      assert_receive {:notify, %{kind: "mention"}},
                     500,
                     "being called by name is exactly what mute must not swallow"
    end

    test "do-not-disturb silences a mention too" do
      alice = user_fixture(%{username: "alice"})
      bob = user_fixture(%{username: "bob"})
      conv = dm(alice, bob)

      {:ok, _} = Accounts.set_presence_status(bob, "dnd")
      Phoenix.PubSub.subscribe(Eden.PubSub, notify_topic(bob))

      {:ok, _} = Chat.create_message(scope(alice), conv.id, %{"body" => "@bob urgent"})

      refute_receive {:notify, _},
                     300,
                     "DND means \"not now, whoever you are\" — a mention does not outrank it"
    end

    test "mentioning yourself notifies nobody" do
      alice = user_fixture(%{username: "alice"})
      bob = user_fixture(%{username: "bob"})
      conv = dm(alice, bob)

      Phoenix.PubSub.subscribe(Eden.PubSub, notify_topic(alice))
      {:ok, _} = Chat.create_message(scope(alice), conv.id, %{"body" => "note to @alice"})
      refute_receive {:notify, _}, 300
    end
  end

  describe "editing" do
    test "a mention added by an edit becomes real; one edited away stops existing" do
      alice = user_fixture(%{username: "alice"})
      bob = user_fixture(%{username: "bob"})
      conv = dm(alice, bob)

      {:ok, message} = Chat.create_message(scope(alice), conv.id, %{"body" => "hello"})
      assert mentions_of(message) == []

      {:ok, edited} = Chat.edit_message(scope(alice), message.id, "hello @bob")
      assert mentions_of(edited) == ["bob"]

      {:ok, edited} = Chat.edit_message(scope(alice), message.id, "never mind")
      assert mentions_of(edited) == []
    end
  end
end
