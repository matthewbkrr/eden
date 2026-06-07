defmodule Eden.ChatTest do
  use Eden.DataCase, async: true
  use Oban.Testing, repo: Eden.Repo

  import Eden.AccountsFixtures

  alias Eden.Accounts.Scope
  alias Eden.Chat
  alias Eden.Chat.{Attachment, Conversation, Membership, ThumbnailWorker}

  defp scope(user), do: Scope.for_user(user)

  @png_signature <<137, 80, 78, 71, 13, 10, 26, 10>>

  defp image_path(bytes) do
    path = Path.join(System.tmp_dir!(), "img-#{System.unique_integer([:positive])}")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    path
  end

  # A real, decodable PNG (the magic-byte stubs above can't be thumbnailed).
  defp real_png(width \\ 1200, height \\ 800) do
    {:ok, img} = Image.new(width, height, color: [120, 80, 200])
    {:ok, bytes} = Image.write(img, :memory, suffix: ".png")
    image_path(bytes)
  end

  setup do
    alice = user_fixture(%{username: "alice", display_name: "Alice"})
    bob = user_fixture(%{username: "bob", display_name: "Bob"})
    %{alice: alice, bob: bob}
  end

  describe "create_conversation/3 (1:1)" do
    test "creates a direct conversation with both members, creator as owner", %{
      alice: alice,
      bob: bob
    } do
      assert {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      refute conv.is_group
      roles = Map.new(conv.memberships, &{&1.user_id, &1.role})
      assert roles[alice.id] == "owner"
      assert roles[bob.id] == "member"
      assert length(conv.memberships) == 2
    end

    test "reuses an existing 1:1 instead of creating a duplicate", %{alice: alice, bob: bob} do
      assert {:ok, first} = Chat.create_conversation(scope(alice), [bob.id])
      assert {:ok, second} = Chat.create_conversation(scope(bob), [alice.id])
      assert first.id == second.id
      assert Repo.aggregate(Conversation, :count) == 1
    end

    test "rejects an empty member list", %{alice: alice} do
      assert {:error, :no_members} = Chat.create_conversation(scope(alice), [])
      assert {:error, :no_members} = Chat.create_conversation(scope(alice), [alice.id])
    end
  end

  describe "create_conversation/3 (group)" do
    test "creates a titled group with all members", %{alice: alice, bob: bob} do
      carol = user_fixture(%{username: "carol"})

      assert {:ok, conv} =
               Chat.create_conversation(scope(alice), [bob.id, carol.id], title: "Trip")

      assert conv.is_group
      assert conv.title == "Trip"
      assert length(conv.memberships) == 3
    end
  end

  describe "scoping" do
    test "list/get only expose conversations the user belongs to", %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      dave = user_fixture(%{username: "dave"})

      assert [listed] = Chat.list_conversations(scope(alice))
      assert listed.id == conv.id
      assert [] == Chat.list_conversations(scope(dave))

      assert {:ok, _} = Chat.get_conversation(scope(bob), conv.id)
      assert {:error, :not_found} = Chat.get_conversation(scope(dave), conv.id)
    end
  end

  describe "create_message/3" do
    setup %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      %{conv: conv}
    end

    test "a member posts; sender is set and the conversation is touched", %{
      alice: alice,
      conv: conv
    } do
      assert {:ok, message} = Chat.create_message(scope(alice), conv.id, %{"body" => "hello"})
      assert message.sender_id == alice.id
      assert message.sender.display_name == "Alice"
      assert Repo.get!(Conversation, conv.id).last_message_at
    end

    test "strips NUL bytes and trims, rejecting blank bodies", %{alice: alice, conv: conv} do
      assert {:ok, message} =
               Chat.create_message(scope(alice), conv.id, %{"body" => "a" <> <<0>> <> "b "})

      assert message.body == "ab"

      assert {:error, %Ecto.Changeset{}} =
               Chat.create_message(scope(alice), conv.id, %{"body" => "   "})
    end

    test "rejects an over-long body", %{alice: alice, conv: conv} do
      assert {:error, %Ecto.Changeset{}} =
               Chat.create_message(scope(alice), conv.id, %{"body" => String.duplicate("x", 4001)})
    end

    test "non-members cannot post", %{conv: conv} do
      dave = user_fixture(%{username: "dave2"})
      assert {:error, :not_found} = Chat.create_message(scope(dave), conv.id, %{"body" => "hi"})
    end

    test "broadcasts new messages to subscribers", %{alice: alice, conv: conv} do
      Chat.subscribe(conv.id)
      {:ok, message} = Chat.create_message(scope(alice), conv.id, %{"body" => "ping"})
      assert_receive {:new_message, ^message}
    end

    test "notifies each member of activity on their per-user topic", %{
      alice: alice,
      bob: bob,
      conv: conv
    } do
      Chat.subscribe_user(scope(bob))
      {:ok, _} = Chat.create_message(scope(alice), conv.id, %{"body" => "hey"})
      assert_receive {:conversation_activity, conversation_id}
      assert conversation_id == conv.id
    end

    test "mark_read broadcasts a read receipt", %{bob: bob, conv: conv} do
      Chat.subscribe(conv.id)
      :ok = Chat.mark_read(scope(bob), conv.id)
      assert_receive {:read, reader_id, %DateTime{}}
      assert reader_id == bob.id
    end
  end

  describe "create_photo_message/3" do
    setup %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      %{conv: conv}
    end

    test "stores the image and creates a message with an attachment", %{alice: alice, conv: conv} do
      path = image_path(@png_signature <> "fake-png-body")

      assert {:ok, message} =
               Chat.create_photo_message(scope(alice), conv.id, %{path: path, body: "look"})

      assert message.body == "look"
      assert message.attachment.content_type == "image/png"
      assert message.attachment.byte_size > 0
      assert Eden.Storage.exists?(message.attachment.storage_key)
    end

    test "allows a photo with no caption", %{alice: alice, conv: conv} do
      path = image_path(@png_signature <> "x")
      assert {:ok, message} = Chat.create_photo_message(scope(alice), conv.id, %{path: path})
      assert message.body == ""
      assert message.attachment
    end

    test "rejects a non-image by magic bytes regardless of claimed type", %{
      alice: alice,
      conv: conv
    } do
      path = image_path("just plain text, not an image")

      assert {:error, :unsupported_type} =
               Chat.create_photo_message(scope(alice), conv.id, %{path: path})
    end

    test "rejects an oversize file", %{alice: alice, conv: conv} do
      path = image_path(@png_signature <> :binary.copy("x", 8 * 1024 * 1024 + 1))

      assert {:error, :too_large} =
               Chat.create_photo_message(scope(alice), conv.id, %{path: path})
    end

    test "non-members cannot post a photo", %{conv: conv} do
      dave = user_fixture(%{username: "davephoto"})
      path = image_path(@png_signature <> "x")
      assert {:error, :not_found} = Chat.create_photo_message(scope(dave), conv.id, %{path: path})
    end

    test "broadcasts the photo message with the attachment preloaded", %{alice: alice, conv: conv} do
      Chat.subscribe(conv.id)
      path = image_path(@png_signature <> "x")
      {:ok, _} = Chat.create_photo_message(scope(alice), conv.id, %{path: path})
      assert_receive {:new_message, message}
      assert message.attachment.content_type == "image/png"
    end

    test "enqueues a thumbnail job on the media queue", %{alice: alice, conv: conv} do
      {:ok, message} = Chat.create_photo_message(scope(alice), conv.id, %{path: real_png()})

      assert_enqueued(
        worker: ThumbnailWorker,
        queue: :media,
        args: %{attachment_id: message.attachment.id}
      )
    end
  end

  describe "generate_thumbnail/1" do
    setup %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      %{conv: conv}
    end

    test "captures dimensions at upload, downsizes the thumbnail, and broadcasts",
         %{alice: alice, conv: conv} do
      Chat.subscribe(conv.id)

      {:ok, message} =
        Chat.create_photo_message(scope(alice), conv.id, %{path: real_png(1200, 800)})

      # Original dimensions are known immediately (before any thumbnail), so the
      # first render can reserve layout space.
      assert message.attachment.width == 1200
      assert message.attachment.height == 800

      assert :ok = Chat.generate_thumbnail(message.attachment)

      attachment = Repo.get(Attachment, message.attachment.id)
      assert is_binary(attachment.thumbnail_key)
      assert attachment.width == 1200
      assert attachment.height == 800
      assert Eden.Storage.exists?(attachment.thumbnail_key)

      {:ok, thumb_bytes} = Eden.Storage.read(attachment.thumbnail_key)
      {:ok, thumb} = Image.from_binary(thumb_bytes)
      assert max(Image.width(thumb), Image.height(thumb)) == 800

      assert_receive {:thumbnail_ready, broadcast}
      assert broadcast.attachment.thumbnail_key == attachment.thumbnail_key
    end

    test "never upscales an image smaller than the target", %{alice: alice, conv: conv} do
      {:ok, message} =
        Chat.create_photo_message(scope(alice), conv.id, %{path: real_png(300, 200)})

      assert :ok = Chat.generate_thumbnail(message.attachment)

      attachment = Repo.get(Attachment, message.attachment.id)
      {:ok, thumb_bytes} = Eden.Storage.read(attachment.thumbnail_key)
      {:ok, thumb} = Image.from_binary(thumb_bytes)
      assert Image.width(thumb) == 300
      assert Image.height(thumb) == 200
    end

    test "the worker generates the thumbnail and is idempotent", %{alice: alice, conv: conv} do
      {:ok, message} = Chat.create_photo_message(scope(alice), conv.id, %{path: real_png()})
      args = %{attachment_id: message.attachment.id}

      assert :ok = perform_job(ThumbnailWorker, args)
      first_key = Repo.get(Attachment, message.attachment.id).thumbnail_key
      assert is_binary(first_key)

      assert :ok = perform_job(ThumbnailWorker, args)
      assert Repo.get(Attachment, message.attachment.id).thumbnail_key == first_key
    end

    test "the worker is a no-op for a missing attachment" do
      assert :ok = perform_job(ThumbnailWorker, %{attachment_id: 999_999})
    end

    test "a corrupt image fails gracefully and the worker cancels (no retries)",
         %{alice: alice, conv: conv} do
      # Valid PNG magic bytes (passes upload detection) but not a decodable image.
      path = image_path(@png_signature <> "not actually a png body")
      {:ok, message} = Chat.create_photo_message(scope(alice), conv.id, %{path: path})

      assert {:error, {:unprocessable, _}} = Chat.generate_thumbnail(message.attachment)

      assert {:cancel, {:unprocessable, _}} =
               perform_job(ThumbnailWorker, %{attachment_id: message.attachment.id})

      refute Repo.get(Attachment, message.attachment.id).thumbnail_key
    end
  end

  describe "list_messages/3" do
    setup %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])

      messages =
        for n <- 1..5 do
          {:ok, m} = Chat.create_message(scope(alice), conv.id, %{"body" => "m#{n}"})
          m
        end

      %{conv: conv, messages: messages}
    end

    test "returns oldest-first with the sender preloaded", %{alice: alice, conv: conv} do
      assert {:ok, msgs} = Chat.list_messages(scope(alice), conv.id)
      assert Enum.map(msgs, & &1.body) == ~w(m1 m2 m3 m4 m5)
      assert hd(msgs).sender.display_name == "Alice"
    end

    test "paginates backwards with limit and before", %{alice: alice, conv: conv} do
      assert {:ok, page} = Chat.list_messages(scope(alice), conv.id, limit: 2)
      assert Enum.map(page, & &1.body) == ~w(m4 m5)

      oldest_loaded = hd(page)

      assert {:ok, older} =
               Chat.list_messages(scope(alice), conv.id, limit: 2, before: oldest_loaded.id)

      assert Enum.map(older, & &1.body) == ~w(m2 m3)
    end

    test "non-members cannot read", %{conv: conv} do
      dave = user_fixture(%{username: "dave3"})
      assert {:error, :not_found} = Chat.list_messages(scope(dave), conv.id)
    end
  end

  describe "list_conversations/1 enrichment" do
    test "fills last_message_body and per-user unread_count", %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      {:ok, _} = Chat.create_message(scope(alice), conv.id, %{"body" => "first"})
      {:ok, _} = Chat.create_message(scope(alice), conv.id, %{"body" => "second"})

      [for_bob] = Chat.list_conversations(scope(bob))
      assert for_bob.last_message_body == "second"
      assert for_bob.unread_count == 2

      # the sender's own messages are never unread for the sender
      [for_alice] = Chat.list_conversations(scope(alice))
      assert for_alice.unread_count == 0

      Chat.mark_read(scope(bob), conv.id)
      [after_read] = Chat.list_conversations(scope(bob))
      assert after_read.unread_count == 0
    end
  end

  describe "mark_read/2" do
    test "sets last_read_at for the member", %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      assert :ok = Chat.mark_read(scope(alice), conv.id)

      membership = Repo.get_by!(Membership, conversation_id: conv.id, user_id: alice.id)
      assert membership.last_read_at
    end
  end
end
