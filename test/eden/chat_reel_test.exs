defmodule ReelTest do
  use Eden.DataCase, async: true
  import Eden.AccountsFixtures
  alias Eden.Accounts.Scope
  alias Eden.Chat

  test "the reel returns photos AND videos with their message preloaded" do
    alice = user_fixture(%{username: "reel_a"})
    bob = user_fixture(%{username: "reel_b"})
    {:ok, conv} = Chat.create_conversation(Scope.for_user(alice), [bob.id])
    png = Path.join(System.tmp_dir!(), "reel-#{System.unique_integer([:positive])}.png")
    File.write!(png, <<137, 80, 78, 71, 13, 10, 26, 10>> <> "body")
    {:ok, _} = Chat.create_attachment_message(Scope.for_user(alice), conv.id, %{path: png})

    assert {:ok, [att]} =
             Chat.list_conversation_media(Scope.for_user(bob), conv.id, ~w(image video),
               with_message: true
             )

    assert att.kind == "image"
    assert att.message.sender.username == "reel_a"
  end

  test "an unknown kind is a plain ArgumentError, not an opaque match error" do
    alice = user_fixture(%{username: "reel_k"})
    bob = user_fixture(%{username: "reel_l"})
    {:ok, conv} = Chat.create_conversation(Scope.for_user(alice), [bob.id])

    assert_raise ArgumentError, ~r/unknown media kind/, fn ->
      Chat.list_conversation_media(Scope.for_user(alice), conv.id, ~w(image sticker))
    end
  end

  test "a non-member gets not_found for a kinds list too" do
    alice = user_fixture(%{username: "reel_c"})
    bob = user_fixture(%{username: "reel_d"})
    mallory = user_fixture(%{username: "reel_m"})
    {:ok, conv} = Chat.create_conversation(Scope.for_user(alice), [bob.id])

    assert {:error, :not_found} =
             Chat.list_conversation_media(Scope.for_user(mallory), conv.id, ~w(image video))
  end
end
