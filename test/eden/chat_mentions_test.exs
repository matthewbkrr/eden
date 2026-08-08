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

  describe "@all" do
    defp group(owner, others) do
      {:ok, conv} = Chat.create_conversation(scope(owner), Enum.map(others, & &1.id))
      conv
    end

    test "names every member, and only where there is a room to gather" do
      alice = user_fixture(%{username: "alice"})
      bob = user_fixture(%{username: "bob"})
      carol = user_fixture(%{username: "carol"})
      conv = group(alice, [bob, carol])

      {:ok, message} = Chat.create_message(scope(alice), conv.id, %{"body" => "@all standup"})

      # Rows are per-person even for `@all` — delivery and any future "mentions of me" need no
      # special case beyond the resolution itself.
      assert length(Repo.preload(message, :mentions).mentions) == 3

      # A 1:1 has nobody to gather: offering it there would be a control that does nothing.
      dm = dm(alice, bob)
      refute Enum.any?(Chat.mention_candidates(scope(alice), dm.id, ""), & &1[:everyone])
      assert Enum.any?(Chat.mention_candidates(scope(alice), conv.id, ""), & &1[:everyone])
      assert Enum.any?(Chat.mention_candidates(scope(alice), conv.id, "al"), & &1[:everyone])
      refute Enum.any?(Chat.mention_candidates(scope(alice), conv.id, "bo"), & &1[:everyone])
    end

    test "reaches someone who muted the conversation" do
      alice = user_fixture(%{username: "alice"})
      bob = user_fixture(%{username: "bob"})
      carol = user_fixture(%{username: "carol"})
      conv = group(alice, [bob, carol])

      {:ok, _} = Chat.toggle_conversation_mute(scope(bob), conv.id)
      Phoenix.PubSub.subscribe(Eden.PubSub, "user:#{bob.id}:notify")

      {:ok, _} = Chat.create_message(scope(alice), conv.id, %{"body" => "@all deploy in 5"})
      assert_receive {:notify, %{kind: "mention"}}, 500
    end

    test "the candidate list only ever holds people the sender shares the conversation with" do
      alice = user_fixture(%{username: "alice"})
      bob = user_fixture(%{username: "bob"})
      stranger = user_fixture(%{username: "stranger"})
      conv = dm(alice, bob)

      handles = Chat.mention_candidates(scope(alice), conv.id, "") |> Enum.map(& &1.handle)
      assert "bob" in handles
      refute stranger.username in handles

      assert Chat.mention_candidates(scope(stranger), conv.id, "") == [],
             "a non-member must not be able to enumerate a conversation through its @ list"
    end
  end

  describe "editing after a rename" do
    test "an untouched mention keeps the person it named, even when the handle is gone" do
      alice = user_fixture(%{username: "alice"})
      bob = user_fixture(%{username: "bob"})
      conv = dm(alice, bob)

      {:ok, message} = Chat.create_message(scope(alice), conv.id, %{"body" => "@bob ping"})
      {:ok, _} = Accounts.update_username(bob, %{"username" => "robert"})

      # The body still literally says "@bob" — that is what was typed. Re-resolving from scratch
      # would find nobody under that handle and quietly delete the mention.
      {:ok, edited} = Chat.edit_message(scope(alice), message.id, "@bob ping!")

      assert mentions_of(edited) == ["robert"],
             "an edit that never touched the mention must not un-name the person"
    end

    test "the old handle taken by someone else does not steal a historical mention" do
      alice = user_fixture(%{username: "alice"})
      bob = user_fixture(%{username: "bob"})
      carol = user_fixture(%{username: "carol"})
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id, carol.id])

      {:ok, message} = Chat.create_message(scope(alice), conv.id, %{"body" => "@bob ping"})
      {:ok, _} = Accounts.update_username(bob, %{"username" => "robert"})
      {:ok, _} = Accounts.update_username(carol, %{"username" => "bob"})

      {:ok, edited} = Chat.edit_message(scope(alice), message.id, "@bob ping!")

      assert mentions_of(edited) == ["robert"],
             "the mention names a person, and no rename by anyone can hand it to someone else"
    end

    test "a handle added by an edit still resolves" do
      alice = user_fixture(%{username: "alice"})
      bob = user_fixture(%{username: "bob"})
      carol = user_fixture(%{username: "carol"})
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id, carol.id])

      {:ok, message} = Chat.create_message(scope(alice), conv.id, %{"body" => "@bob ping"})
      {:ok, edited} = Chat.edit_message(scope(alice), message.id, "@bob @carol ping")

      assert mentions_of(edited) == ["bob", "carol"]
    end
  end

  describe "handle boundaries" do
    test "a full stop ends the handle" do
      alice = user_fixture(%{username: "alice"})
      bob = user_fixture(%{username: "bob"})
      conv = dm(alice, bob)

      {:ok, message} = Chat.create_message(scope(alice), conv.id, %{"body" => "спроси у @bob."})

      assert mentions_of(message) == ["bob"],
             "a handle at the end of a sentence is still a handle — the punctuation is not part of it"
    end
  end

  describe "@all beside a personal mention" do
    test "a person named twice is notified once" do
      alice = user_fixture(%{username: "alice"})
      bob = user_fixture(%{username: "bob"})
      carol = user_fixture(%{username: "carol"})
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id, carol.id])

      Phoenix.PubSub.subscribe(Eden.PubSub, "user:#{bob.id}:notify")
      {:ok, _} = Chat.create_message(scope(alice), conv.id, %{"body" => "@all и особенно @bob"})

      assert_receive {:notify, %{kind: "mention"}}, 500
      refute_receive {:notify, _}, 300, "being named twice is not being rung twice"
    end

    test "both are named, and both keep a span to render" do
      alice = user_fixture(%{username: "alice"})
      bob = user_fixture(%{username: "bob"})
      carol = user_fixture(%{username: "carol"})
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id, carol.id])

      {:ok, message} =
        Chat.create_message(scope(alice), conv.id, %{"body" => "@all и особенно @bob"})

      rows = Repo.preload(message, mentions: :user).mentions
      handles = rows |> Enum.map(& &1.handle) |> Enum.frequencies()

      assert handles["all"] == 3, "everyone is named"

      assert handles["bob"] == 1,
             "the personal mention has to survive next to @all — it is a second span of text, and it needs its own row to be rendered as a chip"
    end
  end
end
