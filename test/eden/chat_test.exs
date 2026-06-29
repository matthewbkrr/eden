defmodule Eden.ChatTest do
  use Eden.DataCase, async: true
  use Oban.Testing, repo: Eden.Repo

  import Eden.AccountsFixtures

  alias Eden.Accounts.Scope
  alias Eden.Channels
  alias Eden.Chat

  alias Eden.Chat.{
    Attachment,
    Conversation,
    FolderPrefs,
    Membership,
    Message,
    MessageDeletion,
    MessageReaction,
    ThumbnailWorker
  }

  defp scope(user), do: Scope.for_user(user)

  defp system_metas(conversation_id) do
    Eden.Repo.all(
      from m in Message,
        where: m.conversation_id == ^conversation_id and m.kind == "system",
        select: m.meta
    )
  end

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

  # A large, CONTENT-ful photo (gaussian noise → JPEG) so #122 compression actually shrinks
  # it ≥10% — a solid-colour image wouldn't, and the win-check would keep the original.
  defp big_photo(width, height) do
    {:ok, noise} = Vix.Vips.Operation.gaussnoise(width, height)
    {:ok, u8} = Vix.Vips.Operation.cast(noise, :VIPS_FORMAT_UCHAR)
    {:ok, bytes} = Image.write(u8, :memory, suffix: ".jpg", quality: 90)
    image_path(bytes)
  end

  # A throwaway .txt file (classified as a `file`, not media) — for per-file
  # attachment tests (#149). Cleaned up after the test.
  defp tmp_text(content) do
    path = Path.join(System.tmp_dir!(), "note-#{System.unique_integer([:positive])}.txt")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  # A committed real HEIC fixture (ISO-BMFF, ftyp + "heic" brand) — the format that
  # used to be misclassified as video (#123). The bundled libvips decodes HEIC but
  # can't encode it, so this is a checked-in file rather than generated in-test.
  defp real_heic, do: Path.join([__DIR__, "..", "support", "fixtures", "sample.heic"])

  # A real 1-second 320x240 mp4 (only used by :ffmpeg-tagged tests).
  defp real_mp4 do
    path = Path.join(System.tmp_dir!(), "vid-#{System.unique_integer([:positive])}.mp4")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-nostdin -v error -y -f lavfi -i testsrc=duration=1:size=320x240:rate=10 -pix_fmt yuv420p) ++
          [path]
      )

    on_exit(fn -> File.rm(path) end)
    path
  end

  # A real 1-second audio-only mp4 (ftyp → classified video, but no video stream).
  defp audio_mp4 do
    path = Path.join(System.tmp_dir!(), "aud-#{System.unique_integer([:positive])}.mp4")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-nostdin -v error -y -f lavfi -i anullsrc=r=44100:cl=mono -t 1 -c:a aac) ++ [path]
      )

    on_exit(fn -> File.rm(path) end)
    path
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

    test "preloaded memberships keep a stable order across reloads", %{alice: alice, bob: bob} do
      carol = user_fixture(%{username: "carol"})
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id, carol.id], title: "Trip")

      order = fn ->
        {:ok, c} = Chat.get_conversation(scope(alice), conv.id)
        Enum.map(c.memberships, & &1.id)
      end

      ids = order.()
      assert ids == Enum.sort(ids)
      # Re-preloading yields the same order (no reshuffling group titles/members).
      assert ids == order.()
    end
  end

  describe "get_shared_user/2" do
    test "returns a user sharing a conversation, with profile fields", %{alice: alice, bob: bob} do
      {:ok, _conv} = Chat.create_conversation(scope(alice), [bob.id])

      assert {:ok, fetched} = Chat.get_shared_user(scope(alice), bob.id)
      assert fetched.id == bob.id
      assert fetched.display_name == "Bob"
      # bio/avatar_key are loaded (the profile fields the modal renders)
      assert Map.has_key?(fetched, :bio)
      assert Map.has_key?(fetched, :avatar_key)
    end

    test "is symmetric and accepts a string id", %{alice: alice, bob: bob} do
      {:ok, _conv} = Chat.create_conversation(scope(alice), [bob.id])
      assert {:ok, %{id: id}} = Chat.get_shared_user(scope(bob), to_string(alice.id))
      assert id == alice.id
    end

    test "denies a user you share no conversation with", %{alice: alice, bob: bob} do
      {:ok, _conv} = Chat.create_conversation(scope(alice), [bob.id])
      dave = user_fixture(%{username: "dave"})

      assert {:error, :not_found} = Chat.get_shared_user(scope(alice), dave.id)
      assert {:error, :not_found} = Chat.get_shared_user(scope(dave), bob.id)
    end

    test "returns not_found for unknown or non-numeric ids", %{alice: alice} do
      assert {:error, :not_found} = Chat.get_shared_user(scope(alice), 999_999)
      assert {:error, :not_found} = Chat.get_shared_user(scope(alice), "abc")
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

    test "rejects an over-long body (the split limit's server backstop, #68)", %{
      alice: alice,
      conv: conv
    } do
      over = String.duplicate("x", Message.max_body() + 1)

      assert {:error, %Ecto.Changeset{}} =
               Chat.create_message(scope(alice), conv.id, %{"body" => over})

      # A part at exactly the limit (what the client splits to) is accepted.
      assert {:ok, _} =
               Chat.create_message(scope(alice), conv.id, %{
                 "body" => String.duplicate("x", Message.max_body())
               })
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

  describe "idempotent sends (client_id)" do
    setup %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      %{conv: conv}
    end

    test "a resend with the same client_id returns the original, no duplicate row", %{
      alice: alice,
      conv: conv
    } do
      cid = "11111111-1111-1111-1111-111111111111"

      assert {:ok, first} =
               Chat.create_message(scope(alice), conv.id, %{"body" => "hi", "client_id" => cid})

      assert {:ok, second} =
               Chat.create_message(scope(alice), conv.id, %{
                 "body" => "resent",
                 "client_id" => cid
               })

      assert first.id == second.id
      # The original wins; the resend's (possibly mutated) body is ignored.
      assert second.body == "hi"
      assert Repo.aggregate(Message, :count) == 1
    end

    test "the duplicate resend does not re-broadcast", %{alice: alice, conv: conv} do
      Chat.subscribe(conv.id)
      cid = "22222222-2222-2222-2222-222222222222"

      {:ok, _} =
        Chat.create_message(scope(alice), conv.id, %{"body" => "once", "client_id" => cid})

      assert_receive {:new_message, _}

      {:ok, _} =
        Chat.create_message(scope(alice), conv.id, %{"body" => "once", "client_id" => cid})

      refute_receive {:new_message, _}, 50
    end

    test "rejects an over-long client_id with a changeset error (no crash)", %{
      alice: alice,
      conv: conv
    } do
      big = String.duplicate("x", 5000)

      assert {:error, %Ecto.Changeset{}} =
               Chat.create_message(scope(alice), conv.id, %{"body" => "hi", "client_id" => big})
    end

    test "messages without a client_id are never deduped", %{alice: alice, conv: conv} do
      {:ok, _} = Chat.create_message(scope(alice), conv.id, %{"body" => "a"})
      {:ok, _} = Chat.create_message(scope(alice), conv.id, %{"body" => "b"})
      assert Repo.aggregate(Message, :count) == 2
    end

    test "the same client_id from different senders is not a collision", %{
      alice: alice,
      bob: bob,
      conv: conv
    } do
      cid = "33333333-3333-3333-3333-333333333333"
      {:ok, _} = Chat.create_message(scope(alice), conv.id, %{"body" => "a", "client_id" => cid})
      {:ok, _} = Chat.create_message(scope(bob), conv.id, %{"body" => "b", "client_id" => cid})
      assert Repo.aggregate(Message, :count) == 2
    end

    test "a burst of sends with interleaved resends yields a clean, ordered history", %{
      alice: alice,
      conv: conv
    } do
      # Each message is sent and then "resent" (as the outbound queue would after a
      # reconnect). History must stay complete, ordered, and free of duplicates.
      for n <- 1..3 do
        cid = "burst-#{n}"
        attrs = %{"body" => "m#{n}", "client_id" => cid}
        {:ok, _} = Chat.create_message(scope(alice), conv.id, attrs)
        {:ok, _} = Chat.create_message(scope(alice), conv.id, attrs)
      end

      {:ok, messages} = Chat.list_messages(scope(alice), conv.id)
      assert Enum.map(messages, & &1.body) == ["m1", "m2", "m3"]
      assert Repo.aggregate(Message, :count) == 3
    end

    test "a photo resend with the same client_id dedups and drops the duplicate blob", %{
      alice: alice,
      conv: conv
    } do
      cid = "44444444-4444-4444-4444-444444444444"

      {:ok, first} =
        Chat.create_attachment_message(scope(alice), conv.id, %{path: real_png(), client_id: cid})

      {:ok, second} =
        Chat.create_attachment_message(scope(alice), conv.id, %{path: real_png(), client_id: cid})

      assert first.id == second.id
      assert Repo.aggregate(Message, :count) == 1
      assert Repo.aggregate(Attachment, :count) == 1
    end

    @tag :heif
    test "a HEIC photo is stored as an image (transcoded to JPEG), never a video (#123)", %{
      alice: alice,
      conv: conv
    } do
      cid = "55555555-5555-5555-5555-555555555555"

      {:ok, _msg} =
        Chat.create_attachment_message(scope(alice), conv.id, %{path: real_heic(), client_id: cid})

      att = Repo.one(Attachment)
      # The core bug: a HEIC's ftyp magic used to classify it as video/mp4.
      assert att.kind == "image"
      refute att.kind == "video"
      # And it's transcoded to a universal JPEG (heif-convert/libheif decodes HEVC),
      # so it renders everywhere, not just Safari.
      assert att.content_type == "image/jpeg"
    end

    test "a non-decodable heic-branded upload falls back to an image, never crashes (#123)", %{
      alice: alice,
      conv: conv
    } do
      # ftyp + "heic" brand but garbage content: heif-convert can't decode it, so the
      # transcode can't run. The send must NOT crash (review B1 — heic_to_jpeg's `with`
      # normalizes every failure to {:error, _}, so no partial result falls through as
      # an unmatched value) and must store an image, never a video. heif-convert isn't
      # needed here — this is the fallback path.
      fake = Path.join(System.tmp_dir!(), "fake-#{System.unique_integer([:positive])}.heic")
      File.write!(fake, <<0, 0, 0, 24>> <> "ftyp" <> "heic" <> <<0, 0, 0, 0>> <> "garbagegarbage")
      on_exit(fn -> File.rm(fake) end)

      {:ok, _msg} =
        Chat.create_attachment_message(scope(alice), conv.id, %{
          path: fake,
          client_id: "66666666-6666-6666-6666-666666666666"
        })

      att = Repo.one(Attachment)
      assert att.kind == "image"
      refute att.kind == "video"
    end
  end

  describe "photo compression (#122)" do
    setup %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      %{conv: conv}
    end

    test "compress_photo downscales a large image + re-encodes a JPEG" do
      # huge orig_size forces the win-check to accept, isolating the downscale/encode logic.
      assert {:ok, jpeg, w, h} = Eden.Images.compress_photo(big_photo(2400, 1600), 100_000_000)
      assert max(w, h) == 1600 and min(w, h) <= 1600
      assert {:ok, _img} = Image.from_binary(jpeg)
    end

    test "compress_photo keeps the original when a re-encode wouldn't meaningfully shrink it" do
      # orig_size = 1 byte → no JPEG can be ≤90% of it → keep the original as-is.
      assert :keep = Eden.Images.compress_photo(big_photo(400, 300), 1)
    end

    test "a photo is compressed for weight by default (downscaled, stored as JPEG)", %{
      alice: alice,
      conv: conv
    } do
      {:ok, _} =
        Chat.create_attachments(scope(alice), conv.id, [
          %{path: big_photo(2400, 1600), filename: "p.png"}
        ])

      att = Repo.one(Attachment)
      assert att.kind == "image"
      assert att.content_type == "image/jpeg"
      # downscaled to the cap (the win-check passed for this large noisy photo)
      assert att.width <= 1600 and att.height <= 1600
    end

    test "the Original flag stores the photo as-is, uncompressed", %{alice: alice, conv: conv} do
      {:ok, _} =
        Chat.create_attachments(
          scope(alice),
          conv.id,
          [%{path: big_photo(2400, 1600), filename: "p.jpg"}],
          %{original: true}
        )

      att = Repo.one(Attachment)
      # full original dimensions kept (NOT downscaled to 1600) → compression was skipped.
      assert att.width == 2400 and att.height == 1600
    end

    test "Send as file stores the photo uncompressed and flags it as_file", %{
      alice: alice,
      conv: conv
    } do
      {:ok, _} =
        Chat.create_attachments(
          scope(alice),
          conv.id,
          [%{path: big_photo(2400, 1600), filename: "p.jpg"}],
          %{as_file: true}
        )

      att = Repo.one(Attachment)
      # kind stays image (so the worker still thumbnails it), but it's stored uncompressed
      # (full dimensions) and flagged to render as a downloadable document (#122).
      assert att.as_file
      assert att.kind == "image"
      assert att.width == 2400 and att.height == 1600
    end

    test "a pick past the album cap splits into a sequence of albums of 10 (#193)", %{
      alice: alice,
      conv: conv
    } do
      # 12 photos in one send → 2 albums (10 + 2), in order. The caption and the optimistic
      # client_id ride the FIRST album; the rest are plain and stream in.
      sources = for i <- 1..12, do: %{path: big_photo(80, 60), filename: "p#{i}.jpg"}

      {:ok, messages} =
        Chat.create_attachments(scope(alice), conv.id, sources, %{
          body: "look",
          client_id: "cid-1"
        })

      assert length(messages) == 2
      [first, second] = messages
      assert first.body == "look" and first.client_id == "cid-1"
      assert second.body == "" and is_nil(second.client_id)

      counts = Enum.map(messages, &length(Repo.preload(&1, :attachments).attachments))
      assert counts == [10, 2]
    end

    test "each split album is stamped with its OWN client_id from the list (#193)", %{
      alice: alice,
      conv: conv
    } do
      # The per-batch optimistic mints one client_id per album and sends them as a list; each
      # album must carry its matching id so EVERY optimistic node swaps (not just the first).
      sources = for i <- 1..12, do: %{path: big_photo(80, 60), filename: "p#{i}.jpg"}

      {:ok, [first, second]} =
        Chat.create_attachments(scope(alice), conv.id, sources, %{
          body: "look",
          client_id: ["a", "b"]
        })

      assert first.client_id == "a"
      assert second.client_id == "b"
    end

    test "client album-cap and server staging-cap stay aligned (#193)", %{} do
      # The per-batch optimistic relies on the client (data-max-album) and the server both
      # chunking by max_album_entries — diverging the two would misalign the per-album
      # client_ids. And the staging cap must hold at least one album's worth.
      assert Chat.max_album_entries() == 10
      assert Chat.max_staged_entries() >= Chat.max_album_entries()
    end
  end

  describe "list_conversation_media/4 (#136)" do
    setup %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      %{conv: conv}
    end

    test "returns attachments of the kind, newest first", %{alice: alice, conv: conv} do
      {:ok, _} =
        Chat.create_attachments(scope(alice), conv.id, [%{path: real_png(), filename: "a.png"}])

      {:ok, _} =
        Chat.create_attachments(scope(alice), conv.id, [%{path: real_png(), filename: "b.png"}])

      {:ok, images} = Chat.list_conversation_media(scope(alice), conv.id, "image")
      assert [%{filename: "b.png"}, %{filename: "a.png"}] = images
    end

    test "filters by kind (image vs file)", %{alice: alice, conv: conv} do
      {:ok, _} =
        Chat.create_attachments(scope(alice), conv.id, [%{path: real_png(), filename: "a.png"}])

      {:ok, _} =
        Chat.create_attachments(scope(alice), conv.id, [
          %{path: tmp_text("hi"), filename: "n.txt"}
        ])

      assert {:ok, [%{kind: "image"}]} =
               Chat.list_conversation_media(scope(alice), conv.id, "image")

      assert {:ok, [%{kind: "file"}]} =
               Chat.list_conversation_media(scope(alice), conv.id, "file")
    end

    test "excludes deleted-for-both and per-user-hidden messages", %{
      alice: alice,
      bob: bob,
      conv: conv
    } do
      {:ok, _} =
        Chat.create_attachments(scope(alice), conv.id, [%{path: real_png(), filename: "keep.png"}])

      {:ok, [gone]} =
        Chat.create_attachments(scope(alice), conv.id, [%{path: real_png(), filename: "gone.png"}])

      {:ok, [hide]} =
        Chat.create_attachments(scope(alice), conv.id, [%{path: real_png(), filename: "hide.png"}])

      :ok = Chat.delete_message_for_both(scope(alice), gone.id)
      :ok = Chat.delete_message_for_me(scope(alice), hide.id)

      # Alice: tombstone gone for everyone, hide hidden only for her → just keep.
      assert {:ok, [%{filename: "keep.png"}]} =
               Chat.list_conversation_media(scope(alice), conv.id, "image")

      # Bob still sees hide (her per-user hide doesn't affect him); gone is gone for both.
      {:ok, bob_imgs} = Chat.list_conversation_media(scope(bob), conv.id, "image")
      assert Enum.map(bob_imgs, & &1.filename) == ["hide.png", "keep.png"]
    end

    test "non-member gets :not_found", %{conv: conv} do
      carol = user_fixture(%{username: "carol_g"})
      assert {:error, :not_found} = Chat.list_conversation_media(scope(carol), conv.id, "image")
    end

    test "paginates with :before and :limit", %{alice: alice, conv: conv} do
      for n <- 1..3 do
        {:ok, _} =
          Chat.create_attachments(scope(alice), conv.id, [
            %{path: real_png(), filename: "p#{n}.png"}
          ])
      end

      {:ok, [first]} = Chat.list_conversation_media(scope(alice), conv.id, "image", limit: 1)

      {:ok, [next]} =
        Chat.list_conversation_media(scope(alice), conv.id, "image", before: first.id, limit: 1)

      assert next.id < first.id
    end
  end

  describe "delete_message_for_me/2" do
    setup %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      {:ok, msg} = Chat.create_message(scope(alice), conv.id, %{"body" => "secret"})
      %{conv: conv, msg: msg}
    end

    test "hides the message for that user only", %{alice: alice, bob: bob, conv: conv, msg: msg} do
      assert :ok = Chat.delete_message_for_me(scope(bob), msg.id)

      {:ok, for_bob} = Chat.list_messages(scope(bob), conv.id)
      assert for_bob == []

      {:ok, for_alice} = Chat.list_messages(scope(alice), conv.id)
      assert [%{id: id}] = for_alice
      assert id == msg.id
    end

    test "is idempotent", %{bob: bob, msg: msg} do
      assert :ok = Chat.delete_message_for_me(scope(bob), msg.id)
      assert :ok = Chat.delete_message_for_me(scope(bob), msg.id)
      assert Repo.aggregate(MessageDeletion, :count) == 1
    end

    test "broadcasts to the user's own sessions", %{bob: bob, conv: conv, msg: msg} do
      Chat.subscribe_user(scope(bob))
      :ok = Chat.delete_message_for_me(scope(bob), msg.id)
      assert_receive {:message_hidden, conversation_id, message_id}
      assert conversation_id == conv.id
      assert message_id == msg.id
    end

    test "a non-member cannot hide", %{conv: conv, msg: msg} do
      dave = user_fixture(%{username: "davedel"})
      assert {:error, :not_found} = Chat.delete_message_for_me(scope(dave), msg.id)
      # nothing in the conv to begin with, but the point is no row was written
      assert Repo.aggregate(MessageDeletion, :count) == 0
      _ = conv
    end
  end

  describe "delete_message_for_both/2" do
    setup %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      %{conv: conv}
    end

    test "removes the message from the thread for everyone", %{alice: alice, conv: conv} do
      {:ok, msg} = Chat.create_message(scope(alice), conv.id, %{"body" => "oops"})

      assert :ok = Chat.delete_message_for_both(scope(alice), msg.id)

      # The row is kept soft-deleted (for blob cleanup / forward attribution) but
      # no longer appears in the conversation for anyone.
      reloaded = Repo.get!(Message, msg.id)
      assert reloaded.deleted_at
      assert reloaded.body == ""
      assert {:ok, []} = Chat.list_messages(scope(alice), conv.id)
    end

    test "a non-sender cannot delete for both", %{alice: alice, bob: bob, conv: conv} do
      {:ok, msg} = Chat.create_message(scope(alice), conv.id, %{"body" => "mine"})
      assert {:error, :forbidden} = Chat.delete_message_for_both(scope(bob), msg.id)
      refute Repo.get!(Message, msg.id).deleted_at
    end

    test "broadcasts a tombstone", %{alice: alice, conv: conv} do
      {:ok, msg} = Chat.create_message(scope(alice), conv.id, %{"body" => "bye"})
      Chat.subscribe(conv.id)
      :ok = Chat.delete_message_for_both(scope(alice), msg.id)
      assert_receive {:message_deleted, tombstone}
      assert tombstone.id == msg.id
      assert Message.deleted?(tombstone)
    end

    test "deletes the attachment row and blob", %{alice: alice, conv: conv} do
      {:ok, msg} = Chat.create_attachment_message(scope(alice), conv.id, %{path: real_png()})
      key = hd(msg.attachments).storage_key
      assert Eden.Storage.exists?(key)

      assert :ok = Chat.delete_message_for_both(scope(alice), msg.id)

      refute Eden.Storage.exists?(key)
      assert Repo.aggregate(Attachment, :count) == 0
    end
  end

  describe "resolve_room_access/1 (#41 matrix)" do
    test "a room member just opens it, regardless of visibility" do
      assert :member = Chat.resolve_room_access(%{room_member?: true, visibility: "open"})
      assert :member = Chat.resolve_room_access(%{room_member?: true, visibility: "private"})
    end

    test "a non-member auto-joins an open room and knocks on a private one" do
      assert :open_join = Chat.resolve_room_access(%{room_member?: false, visibility: "open"})
      assert :knock = Chat.resolve_room_access(%{room_member?: false, visibility: "private"})
    end

    test "an unexpected/nil visibility denies by default (no crash)" do
      assert :knock = Chat.resolve_room_access(%{room_member?: false, visibility: nil})
      assert :knock = Chat.resolve_room_access(%{room_member?: false, visibility: "bogus"})
    end
  end

  describe "room visibility" do
    setup %{alice: alice} do
      {:ok, channel} = Eden.Channels.create_channel(scope(alice), %{"name" => "Vis"})
      %{channel: channel}
    end

    test "create_room defaults to open and accepts private", %{alice: alice, channel: channel} do
      {:ok, [general]} = Eden.Channels.list_rooms(scope(alice), channel.id)
      assert general.visibility == "open"

      {:ok, open} = Chat.create_room(channel.id, %{"name" => "open-room"}, [alice.id])
      assert open.visibility == "open"

      {:ok, priv} =
        Chat.create_room(channel.id, %{"name" => "secret", "visibility" => "private"}, [alice.id])

      assert priv.visibility == "private"
    end

    test "an invalid visibility is rejected", %{channel: channel, alice: alice} do
      assert {:error, %Ecto.Changeset{} = cs} =
               Chat.create_room(channel.id, %{"name" => "x", "visibility" => "secret"}, [alice.id])

      assert "is invalid" in errors_on(cs).visibility
    end
  end

  describe "threads" do
    # Threads are a corporate-room feature (#26): the root lives in a room, not a DM.
    setup %{alice: alice, bob: bob} do
      {:ok, channel} = Channels.create_channel(scope(alice), %{"name" => "Team"})
      {:ok, room} = Channels.create_room(scope(alice), channel.id, %{"name" => "talk"})
      :ok = Chat.join_room(room.id, bob.id)
      {:ok, root} = Chat.create_message(scope(alice), room.id, %{"body" => "root post"})
      %{conv: room, root: root}
    end

    test "create_reply bumps counters, broadcasts, and stays out of the main stream", %{
      alice: alice,
      bob: bob,
      conv: conv,
      root: root
    } do
      Chat.subscribe(conv.id)

      assert {:ok, reply} = Chat.create_reply(scope(bob), root.id, %{"body" => "a reply"})
      assert reply.root_id == root.id

      assert_receive {:thread_reply, fresh_root, ^reply}
      assert fresh_root.reply_count == 1
      assert fresh_root.last_reply_at == reply.inserted_at

      # Main stream and unread badges ignore replies.
      {:ok, messages} = Chat.list_messages(scope(alice), conv.id)
      refute Enum.any?(messages, &(&1.id == reply.id))
      # alice authored the root; bob's reply is excluded from unread counts.
      assert Chat.channel_unread_counts(scope(alice)) == %{}
    end

    test "create_album_reply attaches an album to a thread reply, delivered as a reply (#104)", %{
      alice: alice,
      bob: bob,
      conv: conv,
      root: root
    } do
      Chat.subscribe(conv.id)

      assert {:ok, reply} =
               Chat.create_album_reply(
                 scope(bob),
                 root.id,
                 [%{path: real_png(), filename: "a.png"}, %{path: real_png(), filename: "b.png"}],
                 %{body: "look"}
               )

      assert reply.root_id == root.id
      assert reply.body == "look"
      assert length(reply.attachments) == 2

      # Delivered as a thread reply (bumps the root), not into the main stream.
      assert_receive {:thread_reply, fresh_root, ^reply}
      assert fresh_root.reply_count == 1
      {:ok, messages} = Chat.list_messages(scope(alice), conv.id)
      refute Enum.any?(messages, &(&1.id == reply.id))

      # Same thread auth as create_reply: a non-member can't attach a reply.
      outsider = user_fixture(%{username: "outsider_104"})

      assert {:error, :not_found} =
               Chat.create_album_reply(scope(outsider), root.id, [%{path: real_png()}], %{})
    end

    test "create_album_reply enforces the flat rule + rejects a tombstoned root (#104)", %{
      alice: alice,
      bob: bob,
      conv: conv,
      root: root
    } do
      # A reply can't itself root an album thread.
      {:ok, reply} = Chat.create_reply(scope(bob), root.id, %{"body" => "level 1"})

      assert {:error, :not_a_root} =
               Chat.create_album_reply(scope(alice), reply.id, [%{path: real_png()}], %{})

      # A tombstoned root rejects album replies (ensure_not_deleted, before ensure_root).
      {:ok, lone} = Chat.create_message(scope(alice), conv.id, %{"body" => "to delete"})
      :ok = Chat.delete_message_for_both(scope(alice), lone.id)

      assert {:error, :deleted} =
               Chat.create_album_reply(scope(bob), lone.id, [%{path: real_png()}], %{})
    end

    test "create_album_reply rolls back every stored blob when one source is too large (#104)", %{
      bob: bob,
      root: root
    } do
      big = @png_signature <> :binary.copy("x", 8 * 1024 * 1024 + 1)

      sources = [
        %{path: image_path(@png_signature <> "ok"), filename: "ok.png"},
        %{path: image_path(big), filename: "huge.png"}
      ]

      assert {:error, :too_large} = Chat.create_album_reply(scope(bob), root.id, sources, %{})
      # prepare_album fails before delivery: no attachment row leaks, root unbumped.
      assert Repo.aggregate(Attachment, :count) == 0
      assert {:ok, %{reply_count: 0}, []} = Chat.list_thread(scope(bob), root.id)
    end

    test "flat rule: a reply can't root another thread; tombstoned roots reject replies", %{
      alice: alice,
      bob: bob,
      root: root
    } do
      {:ok, reply} = Chat.create_reply(scope(bob), root.id, %{"body" => "level 1"})
      assert {:error, :not_a_root} = Chat.create_reply(scope(alice), reply.id, %{"body" => "no"})

      {:ok, lone} =
        Chat.create_message(scope(alice), root.conversation_id, %{"body" => "to delete"})

      :ok = Chat.delete_message_for_both(scope(alice), lone.id)
      assert {:error, :deleted} = Chat.create_reply(scope(bob), lone.id, %{"body" => "no"})
    end

    test "non-members can't reply or read a thread", %{bob: bob, root: root} do
      carol = user_fixture(%{username: "carolt"})
      assert {:error, :not_found} = Chat.create_reply(scope(carol), root.id, %{"body" => "hi"})
      assert {:error, :not_found} = Chat.list_thread(scope(carol), root.id)

      {:ok, _} = Chat.create_reply(scope(bob), root.id, %{"body" => "ok"})
      assert {:ok, _root, [_reply]} = Chat.list_thread(scope(bob), root.id)
    end

    test "list_thread hides per-user-deleted and tombstoned replies", %{
      alice: alice,
      bob: bob,
      root: root
    } do
      {:ok, r1} = Chat.create_reply(scope(bob), root.id, %{"body" => "one"})
      {:ok, r2} = Chat.create_reply(scope(bob), root.id, %{"body" => "two"})
      {:ok, _r3} = Chat.create_reply(scope(alice), root.id, %{"body" => "three"})

      :ok = Chat.delete_message_for_me(scope(alice), r1.id)
      :ok = Chat.delete_message_for_both(scope(bob), r2.id)

      assert {:ok, _root, replies} = Chat.list_thread(scope(alice), root.id)
      assert ["three"] == Enum.map(replies, & &1.body)

      # The for-both delete decremented the root's counter (one visible-to-all
      # delete out of three replies).
      assert {:ok, %{reply_count: 2}, _} = Chat.list_thread(scope(bob), root.id)
    end

    test "a root with replies refuses delete-for-both; replies delete fine", %{
      alice: alice,
      bob: bob,
      root: root
    } do
      {:ok, reply} = Chat.create_reply(scope(bob), root.id, %{"body" => "keeps root alive"})

      assert {:error, :has_replies} = Chat.delete_message_for_both(scope(alice), root.id)
      assert :ok = Chat.delete_message_for_both(scope(bob), reply.id)
      assert {:ok, %{reply_count: 0}, []} = Chat.list_thread(scope(alice), root.id)
    end

    test "thread_root_for routes permalinks; forwarding a reply drops the thread", %{
      alice: alice,
      bob: bob,
      root: root
    } do
      {:ok, reply} = Chat.create_reply(scope(bob), root.id, %{"body" => "fwd me"})

      assert {:ok, root_id} = Chat.thread_root_for(scope(alice), reply.id)
      assert root_id == root.id
      assert :none = Chat.thread_root_for(scope(alice), root.id)

      carol = user_fixture(%{username: "carolfw"})
      {:ok, dm} = Chat.create_conversation(scope(alice), [carol.id])
      {:ok, forwarded} = Chat.forward_message(scope(alice), reply.id, dm.id)
      assert forwarded.root_id == nil
    end

    test "thread_participants builds the facepile per root", %{
      alice: alice,
      bob: bob,
      conv: conv,
      root: root
    } do
      {:ok, _} = Chat.create_reply(scope(bob), root.id, %{"body" => "b1"})
      {:ok, _} = Chat.create_reply(scope(alice), root.id, %{"body" => "a1"})
      {:ok, _} = Chat.create_reply(scope(bob), root.id, %{"body" => "b2"})

      participants = Chat.thread_participants(scope(alice), conv.id, [root.id])
      # Distinct repliers, most recent first: bob (b2), then alice.
      assert [bob.id, alice.id] == Enum.map(participants[root.id], & &1.id)

      # Non-member sees nothing.
      carol = user_fixture(%{username: "carolpp"})
      assert %{} == Chat.thread_participants(scope(carol), conv.id, [root.id])
    end

    test "replies dedup on client_id like top-level messages", %{bob: bob, root: root} do
      cid = Ecto.UUID.generate()

      {:ok, first} =
        Chat.create_reply(scope(bob), root.id, %{"body" => "once", "client_id" => cid})

      {:ok, again} =
        Chat.create_reply(scope(bob), root.id, %{"body" => "once", "client_id" => cid})

      assert first.id == again.id
      assert {:ok, %{reply_count: 1}, _} = Chat.list_thread(scope(bob), root.id)
    end
  end

  describe "thread following (#57)" do
    setup %{alice: alice, bob: bob} do
      {:ok, channel} = Channels.create_channel(scope(alice), %{"name" => "Team"})
      {:ok, room} = Channels.create_room(scope(alice), channel.id, %{"name" => "talk"})
      :ok = Chat.join_room(room.id, bob.id)
      carol = user_fixture(%{username: "carolf"})
      :ok = Chat.join_room(room.id, carol.id)
      {:ok, root} = Chat.create_message(scope(alice), room.id, %{"body" => "root post"})
      %{conv: room, root: root, carol: carol}
    end

    test "a reply auto-follows the replier and pulls in the root author with an unread", %{
      alice: alice,
      bob: bob,
      root: root
    } do
      {:ok, _} = Chat.create_reply(scope(bob), root.id, %{"body" => "hi"})

      # The replier follows and has, by definition, seen their own reply.
      assert %{following: true, unread: 0} = Chat.thread_follow_state(scope(bob), root.id)
      # The root author is pulled in and owes one unread.
      assert %{following: true, unread: 1} = Chat.thread_follow_state(scope(alice), root.id)
    end

    test "every other follower's unread increments; the replier's own does not", %{
      alice: alice,
      bob: bob,
      carol: carol,
      root: root
    } do
      {:ok, :following} = Chat.follow_thread(scope(carol), root.id)

      {:ok, _} = Chat.create_reply(scope(bob), root.id, %{"body" => "one"})
      {:ok, _} = Chat.create_reply(scope(bob), root.id, %{"body" => "two"})

      # bob authored both replies — stays at zero.
      assert %{following: true, unread: 0} = Chat.thread_follow_state(scope(bob), root.id)
      # alice (root author) + carol (opted-in follower) each counted both.
      assert %{following: true, unread: 2} = Chat.thread_follow_state(scope(alice), root.id)
      assert %{following: true, unread: 2} = Chat.thread_follow_state(scope(carol), root.id)
    end

    test "opening a thread resets the viewer's unread (mark_thread_read)", %{
      alice: alice,
      bob: bob,
      root: root
    } do
      {:ok, _} = Chat.create_reply(scope(bob), root.id, %{"body" => "ping"})
      assert %{unread: 1} = Chat.thread_follow_state(scope(alice), root.id)

      assert :ok = Chat.mark_thread_read(scope(alice), root.id)
      assert %{following: true, unread: 0} = Chat.thread_follow_state(scope(alice), root.id)
    end

    test "unfollow stops counting; a later reply does not re-subscribe", %{
      alice: alice,
      bob: bob,
      root: root
    } do
      {:ok, _} = Chat.create_reply(scope(bob), root.id, %{"body" => "first"})
      assert {:ok, :unfollowed} = Chat.unfollow_thread(scope(alice), root.id)
      assert %{following: false, unread: 0} = Chat.thread_follow_state(scope(alice), root.id)

      {:ok, _} = Chat.create_reply(scope(bob), root.id, %{"body" => "second"})
      # An explicit unfollow is sticky — still not following, still zero.
      assert %{following: false, unread: 0} = Chat.thread_follow_state(scope(alice), root.id)
    end

    test "follow_thread is idempotent and never clobbers an existing unread", %{
      alice: alice,
      bob: bob,
      root: root
    } do
      {:ok, _} = Chat.create_reply(scope(bob), root.id, %{"body" => "ping"})
      assert %{following: true, unread: 1} = Chat.thread_follow_state(scope(alice), root.id)

      assert {:ok, :following} = Chat.follow_thread(scope(alice), root.id)
      assert %{following: true, unread: 1} = Chat.thread_follow_state(scope(alice), root.id)
    end

    test "thread_unread_counts and list_followed_threads are per-user and scoped", %{
      alice: alice,
      bob: bob,
      carol: carol,
      conv: conv,
      root: root
    } do
      {:ok, _} = Chat.create_reply(scope(bob), root.id, %{"body" => "ping"})

      # carol never followed → no row at all.
      assert %{} == Chat.thread_unread_counts(scope(carol), conv.id)
      # alice (root author) owes one; bob (replier) follows at zero.
      assert %{root.id => 1} == Chat.thread_unread_counts(scope(alice), conv.id)
      assert %{root.id => 0} == Chat.thread_unread_counts(scope(bob), conv.id)

      assert [{%{id: root_id}, 1}] = Chat.list_followed_threads(scope(alice), conv.id)
      assert root_id == root.id

      # Non-member sees nothing.
      dave = user_fixture(%{username: "davef"})
      assert %{} == Chat.thread_unread_counts(scope(dave), conv.id)
      assert [] == Chat.list_followed_threads(scope(dave), conv.id)
    end

    test "deleting an unread reply decrements the follower's count (no phantom unread)", %{
      alice: alice,
      bob: bob,
      root: root
    } do
      {:ok, r1} = Chat.create_reply(scope(bob), root.id, %{"body" => "one"})
      {:ok, _r2} = Chat.create_reply(scope(bob), root.id, %{"body" => "two"})
      # alice (root author) owes two unread.
      assert %{unread: 2} = Chat.thread_follow_state(scope(alice), root.id)

      # bob deletes one reply for everyone → it stops counting against alice.
      :ok = Chat.delete_message_for_both(scope(bob), r1.id)
      assert %{unread: 1} = Chat.thread_follow_state(scope(alice), root.id)
    end

    test "a root the viewer deleted-for-me drops from their list and counts", %{
      alice: alice,
      bob: bob,
      conv: conv,
      root: root
    } do
      {:ok, _} = Chat.create_reply(scope(bob), root.id, %{"body" => "hi"})
      assert %{root.id => 1} == Chat.thread_unread_counts(scope(alice), conv.id)

      :ok = Chat.delete_message_for_me(scope(alice), root.id)
      assert %{} == Chat.thread_unread_counts(scope(alice), conv.id)
      assert [] == Chat.list_followed_threads(scope(alice), conv.id)
      # bob (also a follower) still sees it.
      assert %{root.id => 0} == Chat.thread_unread_counts(scope(bob), conv.id)
    end

    test "followed reply-less threads sort after active ones", %{
      alice: alice,
      bob: bob,
      conv: conv,
      root: root
    } do
      {:ok, _} = Chat.create_reply(scope(bob), root.id, %{"body" => "active"})
      {:ok, empty} = Chat.create_message(scope(alice), conv.id, %{"body" => "lonely root"})
      {:ok, :following} = Chat.follow_thread(scope(alice), empty.id)

      ids = Chat.list_followed_threads(scope(alice), conv.id) |> Enum.map(fn {r, _} -> r.id end)
      # The active thread (has last_reply_at) first; the reply-less root last
      # (not first, as a naive DESC NULLS-FIRST would put it).
      assert ids == [root.id, empty.id]
    end

    test "follow/mark reject non-roots, non-rooms, and non-members", %{
      alice: alice,
      bob: bob,
      root: root
    } do
      {:ok, reply} = Chat.create_reply(scope(bob), root.id, %{"body" => "r"})
      assert {:error, :not_a_root} = Chat.follow_thread(scope(alice), reply.id)

      # DM root: threads are rooms-only (#26).
      eve = user_fixture(%{username: "evef"})
      {:ok, dm} = Chat.create_conversation(scope(alice), [eve.id])
      {:ok, dm_msg} = Chat.create_message(scope(alice), dm.id, %{"body" => "hey"})
      assert {:error, :not_found} = Chat.follow_thread(scope(alice), dm_msg.id)

      # Non-member.
      mallory = user_fixture(%{username: "malloryf"})
      assert {:error, :not_found} = Chat.follow_thread(scope(mallory), root.id)
      assert {:error, :not_found} = Chat.mark_thread_read(scope(mallory), root.id)
    end
  end

  describe "reactions (#67)" do
    setup %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      {:ok, msg} = Chat.create_message(scope(alice), conv.id, %{"body" => "react to me"})
      %{conv: conv, msg: msg}
    end

    test "toggling adds then removes, idempotently; broadcasts", %{
      alice: alice,
      conv: conv,
      msg: msg
    } do
      Chat.subscribe(conv.id)

      assert {:ok, m1} = Chat.toggle_reaction(scope(alice), msg.id, "👍")
      assert [%{emoji: "👍", user_id: uid}] = m1.reactions
      assert uid == alice.id
      assert_receive {:reaction_changed, %{id: id}} when id == msg.id

      # Same emoji again toggles it off.
      assert {:ok, m2} = Chat.toggle_reaction(scope(alice), msg.id, "👍")
      assert m2.reactions == []
    end

    test "different emoji and different users coexist", %{alice: alice, bob: bob, msg: msg} do
      {:ok, _} = Chat.toggle_reaction(scope(alice), msg.id, "👍")
      {:ok, _} = Chat.toggle_reaction(scope(bob), msg.id, "👍")
      {:ok, m} = Chat.toggle_reaction(scope(alice), msg.id, "❤️")

      emojis = Enum.frequencies_by(m.reactions, & &1.emoji)
      assert emojis == %{"👍" => 2, "❤️" => 1}
    end

    test "non-members can't react", %{msg: msg} do
      carol = user_fixture(%{username: "carol_react"})
      assert {:error, :not_found} = Chat.toggle_reaction(scope(carol), msg.id, "👍")
    end

    test "a member who has left the conversation can't react", %{
      alice: alice,
      bob: bob,
      conv: conv,
      msg: msg
    } do
      # Alice leaves (left_at set); bob stays, so the chat isn't GC'd.
      :ok = Chat.delete_conversation(scope(alice), conv.id)
      assert {:error, :not_found} = Chat.toggle_reaction(scope(alice), msg.id, "👍")
      # An active member still can.
      assert {:ok, _} = Chat.toggle_reaction(scope(bob), msg.id, "👍")
    end

    test "rejects an emoji outside the allowed set", %{alice: alice, msg: msg} do
      assert {:error, %Ecto.Changeset{}} = Chat.toggle_reaction(scope(alice), msg.id, "lol")
      assert Repo.aggregate(MessageReaction, :count) == 0
      # An allowed one still goes through.
      assert {:ok, _} = Chat.toggle_reaction(scope(alice), msg.id, hd(Chat.allowed_reactions()))
    end

    test "a tombstoned message rejects reactions", %{alice: alice, msg: msg} do
      :ok = Chat.delete_message_for_both(scope(alice), msg.id)
      assert {:error, :deleted} = Chat.toggle_reaction(scope(alice), msg.id, "👍")
    end

    test "deleting the message cascades its reactions", %{alice: alice, msg: msg} do
      {:ok, _} = Chat.toggle_reaction(scope(alice), msg.id, "👍")
      assert Repo.aggregate(MessageReaction, :count) == 1

      :ok = Chat.delete_message_for_both(scope(alice), msg.id)
      assert Repo.aggregate(MessageReaction, :count) == 0
    end

    test "list_messages preloads reactions", %{alice: alice, conv: conv, msg: msg} do
      {:ok, _} = Chat.toggle_reaction(scope(alice), msg.id, "🎉")
      {:ok, messages} = Chat.list_messages(scope(alice), conv.id)
      reacted = Enum.find(messages, &(&1.id == msg.id))
      assert [%{emoji: "🎉"}] = reacted.reactions
    end

    test "a personal quick-react row defaults until set, then persists", %{alice: alice} do
      assert Chat.quick_reactions(scope(alice)) == MessageReaction.quick()

      {:ok, saved} = Chat.set_quick_reactions(scope(alice), ["🔥", "👀"])
      assert saved == ["🔥", "👀"]
      assert Chat.quick_reactions(scope(alice)) == ["🔥", "👀"]
    end

    test "the double-click reaction defaults to the first quick reaction, then persists (#106)",
         %{alice: alice} do
      # Unset → the first of the (default) quick row.
      assert Chat.dbl_click_reaction(scope(alice)) == hd(MessageReaction.quick())

      # It tracks the quick row while unset.
      {:ok, _} = Chat.set_quick_reactions(scope(alice), ["🔥", "👀"])
      assert Chat.dbl_click_reaction(scope(alice)) == "🔥"

      # An explicit pick wins and survives a quick-row change.
      {:ok, saved} = Chat.set_dbl_click_reaction(scope(alice), "❤️")
      assert saved == "❤️"
      {:ok, _} = Chat.set_quick_reactions(scope(alice), ["😂", "🎉"])
      assert Chat.dbl_click_reaction(scope(alice)) == "❤️"
    end

    test "set_dbl_click_reaction rejects a non-allowed emoji back to the default (#106)",
         %{alice: alice} do
      {:ok, eff} = Chat.set_dbl_click_reaction(scope(alice), "not-an-emoji")
      assert eff == hd(MessageReaction.quick())
      assert Chat.dbl_click_reaction(scope(alice)) == hd(MessageReaction.quick())

      # nil clears an earlier explicit pick.
      {:ok, _} = Chat.set_dbl_click_reaction(scope(alice), "❤️")
      {:ok, cleared} = Chat.set_dbl_click_reaction(scope(alice), nil)
      assert cleared == hd(MessageReaction.quick())
    end

    test "set_quick_reactions drops non-allowed, dedups, and caps", %{alice: alice} do
      limit = Chat.quick_reaction_limit()
      {:ok, saved} = Chat.set_quick_reactions(scope(alice), ["🔥", "not-emoji", "🔥", "👀"])
      assert saved == ["🔥", "👀"]

      # More than the cap is truncated to the limit.
      too_many = Enum.take(Chat.allowed_reactions(), limit + 3)
      {:ok, capped} = Chat.set_quick_reactions(scope(alice), too_many)
      assert length(capped) == limit
    end

    test "clearing the quick row reverts to the default", %{alice: alice} do
      {:ok, _} = Chat.set_quick_reactions(scope(alice), ["🔥"])
      {:ok, reverted} = Chat.set_quick_reactions(scope(alice), [])
      assert reverted == MessageReaction.quick()
    end

    test "a stored emoji no longer in the allowed set is dropped on read", %{alice: alice} do
      # Simulate a set curated down after the user saved: write past the API.
      Repo.insert!(%FolderPrefs{user_id: alice.id, quick_reactions: ["🔥", "💀"]},
        on_conflict: [set: [quick_reactions: ["🔥", "💀"]]],
        conflict_target: :user_id
      )

      # 💀 isn't allowed → silently dropped; the valid one survives.
      assert Chat.quick_reactions(scope(alice)) == ["🔥"]
    end

    test "quick rows are per-user", %{alice: alice, bob: bob} do
      {:ok, _} = Chat.set_quick_reactions(scope(alice), ["🔥"])
      assert Chat.quick_reactions(scope(alice)) == ["🔥"]
      assert Chat.quick_reactions(scope(bob)) == MessageReaction.quick()
    end
  end

  describe "notification prefs (#214)" do
    test "default to sound-on / desktop-off until set, then persist", %{alice: alice} do
      assert Chat.notification_prefs(scope(alice)) == %{sound: true, desktop: false}

      {:ok, false} = Chat.set_notify_sound(scope(alice), false)
      assert Chat.notification_prefs(scope(alice)) == %{sound: false, desktop: false}

      {:ok, true} = Chat.set_notify_desktop(scope(alice), true)
      assert Chat.notification_prefs(scope(alice)) == %{sound: false, desktop: true}
    end

    test "setting one toggle doesn't clobber the other or the reaction prefs", %{alice: alice} do
      {:ok, _} = Chat.set_quick_reactions(scope(alice), ["🔥"])
      {:ok, _} = Chat.set_notify_desktop(scope(alice), true)

      # notify_sound keeps its default; the shared FolderPrefs row's quick_reactions survive.
      assert Chat.notification_prefs(scope(alice)) == %{sound: true, desktop: true}
      assert Chat.quick_reactions(scope(alice)) == ["🔥"]
    end
  end

  describe "quote-reply (#71)" do
    setup %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      {:ok, target} = Chat.create_message(scope(bob), conv.id, %{"body" => "original"})
      %{conv: conv, target: target}
    end

    test "a reply quotes the target and preloads it with its sender", %{
      alice: alice,
      conv: conv,
      target: target
    } do
      {:ok, reply} =
        Chat.create_message(scope(alice), conv.id, %{
          "body" => "answer",
          "reply_to_id" => target.id
        })

      assert reply.reply_to_id == target.id
      assert %{id: tid, sender: %{display_name: "Bob"}} = reply.reply_to
      assert tid == target.id
    end

    test "a reply_to_id from another conversation is dropped", %{alice: alice, conv: conv} do
      carol = user_fixture(%{username: "carol_qr"})
      {:ok, other} = Chat.create_conversation(scope(alice), [carol.id])
      {:ok, foreign} = Chat.create_message(scope(alice), other.id, %{"body" => "elsewhere"})

      {:ok, reply} =
        Chat.create_message(scope(alice), conv.id, %{
          "body" => "x",
          "reply_to_id" => foreign.id
        })

      assert is_nil(reply.reply_to_id)
    end

    test "replying to a deleted-for-everyone message drops the quote", %{
      alice: alice,
      bob: bob,
      conv: conv,
      target: target
    } do
      :ok = Chat.delete_message_for_both(scope(bob), target.id)

      {:ok, reply} =
        Chat.create_message(scope(alice), conv.id, %{"body" => "x", "reply_to_id" => target.id})

      assert is_nil(reply.reply_to_id)
    end

    test "replying to a message you hid for yourself drops the quote", %{
      alice: alice,
      conv: conv,
      target: target
    } do
      :ok = Chat.delete_message_for_me(scope(alice), target.id)

      {:ok, reply} =
        Chat.create_message(scope(alice), conv.id, %{"body" => "x", "reply_to_id" => target.id})

      assert is_nil(reply.reply_to_id)
    end

    test "an album message can quote a target", %{alice: alice, conv: conv, target: target} do
      {:ok, [msg]} =
        Chat.create_attachments(scope(alice), conv.id, [%{path: real_png()}], %{
          reply_to_id: target.id
        })

      assert msg.reply_to_id == target.id
    end

    test "create_attachments stamps the album message with the client_id (#95)", %{
      alice: alice,
      conv: conv
    } do
      cid = "fa739712-e09f-4445-a36a-01c6fc01af40"

      {:ok, [msg]} =
        Chat.create_attachments(scope(alice), conv.id, [%{path: real_png()}], %{client_id: cid})

      # Threads create_attachments → send_attachment_steps → create_album_message
      # → persist_album so the real message swaps the hook's optimistic twin.
      assert msg.client_id == cid
    end

    test "the client_id stamps only the album, not trailing per-file messages (#95 review)", %{
      alice: alice,
      conv: conv
    } do
      cid = "c0ffee00-0000-0000-0000-000000000001"
      file = Path.join(System.tmp_dir!(), "note-#{System.unique_integer([:positive])}.txt")
      File.write!(file, "just a note")
      on_exit(fn -> File.rm(file) end)

      {:ok, messages} =
        Chat.create_attachments(scope(alice), conv.id, [%{path: real_png()}, %{path: file}], %{
          client_id: cid
        })

      # First message = the media album (carries the id); the non-media file is its
      # own message and must NOT claim the optimistic twin (i==0-only, #95 review).
      assert [%{client_id: ^cid} | rest] = messages
      assert rest != []
      assert Enum.all?(rest, &is_nil(&1.client_id))
    end

    test "each file message is stamped with its source's own client_id (#149)", %{
      alice: alice,
      conv: conv
    } do
      album_cid = "a11ce000-0000-0000-0000-000000000aaa"
      f1_cid = "f11e0001-0000-0000-0000-000000000001"
      f2_cid = "f11e0002-0000-0000-0000-000000000002"
      {file1, file2} = {tmp_text("one"), tmp_text("two")}

      {:ok, messages} =
        Chat.create_attachments(
          scope(alice),
          conv.id,
          [
            %{path: real_png()},
            %{path: file1, client_id: f1_cid},
            %{path: file2, client_id: f2_cid}
          ],
          %{client_id: album_cid}
        )

      # The media album carries the album-level id; EACH file message carries its
      # OWN source client_id (keyed by upload ref upstream) so its in-stream
      # optimistic card swaps per file, not just the first (#149).
      assert [%{client_id: ^album_cid}, %{client_id: ^f1_cid}, %{client_id: ^f2_cid}] = messages
    end

    test "files-only: the caption rides the first file, each file keeps its own client_id (#149)",
         %{
           alice: alice,
           conv: conv
         } do
      f1_cid = "f11e0001-0000-0000-0000-0000000000a1"
      f2_cid = "f11e0002-0000-0000-0000-0000000000a2"
      {file1, file2} = {tmp_text("one"), tmp_text("two")}

      {:ok, messages} =
        Chat.create_attachments(
          scope(alice),
          conv.id,
          [%{path: file1, client_id: f1_cid}, %{path: file2, client_id: f2_cid}],
          # No media: the album-level client_id is irrelevant; the first file's own
          # id stamps it and the caption rides it (attachment_steps).
          %{body: "the caption", client_id: "ignored-no-media"}
        )

      assert [
               %{client_id: ^f1_cid, body: "the caption"},
               %{client_id: ^f2_cid, body: ""}
             ] = messages
    end

    test "get_message stages a visible target but not a deleted/hidden one", %{
      alice: alice,
      bob: bob,
      target: target
    } do
      assert %{id: tid} = Chat.get_message(scope(alice), target.id)
      assert tid == target.id

      # Hidden-for-the-requester → not stageable.
      :ok = Chat.delete_message_for_me(scope(alice), target.id)
      assert is_nil(Chat.get_message(scope(alice), target.id))

      # Deleted-for-everyone → not stageable for anyone.
      :ok = Chat.delete_message_for_both(scope(bob), target.id)
      assert is_nil(Chat.get_message(scope(bob), target.id))
    end

    test "hard-deleting the quoted message nilifies the reply's reply_to_id", %{
      alice: alice,
      conv: conv,
      target: target
    } do
      {:ok, reply} =
        Chat.create_message(scope(alice), conv.id, %{"body" => "re", "reply_to_id" => target.id})

      assert reply.reply_to_id == target.id

      # A hard delete (as a conversation GC cascade would) nilifies, not orphans.
      Repo.delete!(Repo.get(Message, target.id))
      assert %{reply_to_id: nil} = Repo.get(Message, reply.id)
    end
  end

  describe "forward_message/3" do
    setup %{alice: alice, bob: bob} do
      carol = user_fixture(%{username: "carol_fwd"})
      {:ok, source_conv} = Chat.create_conversation(scope(alice), [bob.id])
      {:ok, target_conv} = Chat.create_conversation(scope(alice), [carol.id])
      %{carol: carol, source_conv: source_conv, target_conv: target_conv}
    end

    test "copies a text message into the target, attributed to the forwarder", ctx do
      %{alice: alice, source_conv: src, target_conv: tgt} = ctx
      {:ok, original} = Chat.create_message(scope(alice), src.id, %{"body" => "look at this"})

      assert {:ok, forwarded} = Chat.forward_message(scope(alice), original.id, tgt.id)
      assert forwarded.conversation_id == tgt.id
      assert forwarded.body == "look at this"
      assert forwarded.forwarded_from_id == original.id
      assert forwarded.sender_id == alice.id

      {:ok, [listed]} = Chat.list_messages(scope(alice), tgt.id)
      assert listed.id == forwarded.id
    end

    test "copies the attachment by re-referencing the same blob", ctx do
      %{alice: alice, source_conv: src, target_conv: tgt} = ctx
      {:ok, original} = Chat.create_attachment_message(scope(alice), src.id, %{path: real_png()})

      assert {:ok, forwarded} = Chat.forward_message(scope(alice), original.id, tgt.id)
      forwarded = Repo.preload(forwarded, :attachments)

      assert hd(forwarded.attachments).id != hd(original.attachments).id
      assert hd(forwarded.attachments).storage_key == hd(original.attachments).storage_key
      assert Repo.aggregate(Attachment, :count) == 2
    end

    test "preserves the as_file flag on a forwarded photo (#122)", ctx do
      %{alice: alice, source_conv: src, target_conv: tgt} = ctx

      {:ok, [original]} =
        Chat.create_attachments(
          scope(alice),
          src.id,
          [%{path: real_png(), filename: "p.png"}],
          %{as_file: true}
        )

      assert {:ok, forwarded} = Chat.forward_message(scope(alice), original.id, tgt.id)
      forwarded = Repo.preload(forwarded, :attachments)
      # The forwarded copy must still render as a document, not an inline photo.
      assert hd(forwarded.attachments).as_file
    end

    test "keeps the shared blob until the last referencing message is deleted", ctx do
      %{alice: alice, source_conv: src, target_conv: tgt} = ctx
      {:ok, original} = Chat.create_attachment_message(scope(alice), src.id, %{path: real_png()})
      key = hd(original.attachments).storage_key
      {:ok, forwarded} = Chat.forward_message(scope(alice), original.id, tgt.id)

      # Deleting the original must NOT remove the blob the forward still references.
      assert :ok = Chat.delete_message_for_both(scope(alice), original.id)
      assert Eden.Storage.exists?(key)

      # Deleting the last referencing message removes it.
      assert :ok = Chat.delete_message_for_both(scope(alice), forwarded.id)
      refute Eden.Storage.exists?(key)
    end

    test "refuses to forward a deleted message", ctx do
      %{alice: alice, source_conv: src, target_conv: tgt} = ctx
      {:ok, original} = Chat.create_message(scope(alice), src.id, %{"body" => "gone"})
      :ok = Chat.delete_message_for_both(scope(alice), original.id)

      assert {:error, :deleted} = Chat.forward_message(scope(alice), original.id, tgt.id)
    end

    test "refuses a target the user does not belong to", ctx do
      %{alice: alice, bob: bob, source_conv: src} = ctx
      {:ok, original} = Chat.create_message(scope(alice), src.id, %{"body" => "hi"})
      {:ok, other} = Chat.create_conversation(scope(bob), [ctx.carol.id])

      assert {:error, :not_found} = Chat.forward_message(scope(alice), original.id, other.id)
    end

    test "forwarding a forward keeps the original as the attribution root", ctx do
      %{alice: alice, source_conv: src, target_conv: tgt} = ctx
      {:ok, original} = Chat.create_message(scope(alice), src.id, %{"body" => "root"})
      {:ok, first} = Chat.forward_message(scope(alice), original.id, tgt.id)
      assert first.forwarded_from_id == original.id

      {:ok, second} = Chat.forward_message(scope(alice), first.id, src.id)
      # Attribution points at the original author, not the intermediate forward.
      assert second.forwarded_from_id == original.id
    end
  end

  describe "delete_conversation/2" do
    test "hides the conversation for the actor only", %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      {:ok, _} = Chat.create_message(scope(alice), conv.id, %{"body" => "hi"})

      assert :ok = Chat.delete_conversation(scope(alice), conv.id)
      assert [] == Chat.list_conversations(scope(alice))
      assert [%{id: id}] = Chat.list_conversations(scope(bob))
      assert id == conv.id
    end

    test "re-surfaces on new activity", %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      :ok = Chat.delete_conversation(scope(alice), conv.id)
      assert [] == Chat.list_conversations(scope(alice))

      {:ok, _} = Chat.create_message(scope(bob), conv.id, %{"body" => "you there?"})
      assert [%{id: id}] = Chat.list_conversations(scope(alice))
      assert id == conv.id
    end

    test "broadcasts to the actor's own sessions", %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      Chat.subscribe_user(scope(alice))
      :ok = Chat.delete_conversation(scope(alice), conv.id)
      assert_receive {:conversation_left, id}
      assert id == conv.id
    end

    test "garbage-collects the conversation when the last member leaves", %{
      alice: alice,
      bob: bob
    } do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      {:ok, msg} = Chat.create_attachment_message(scope(alice), conv.id, %{path: real_png()})
      key = hd(msg.attachments).storage_key
      assert Eden.Storage.exists?(key)

      :ok = Chat.delete_conversation(scope(alice), conv.id)
      refute is_nil(Repo.get(Conversation, conv.id))

      :ok = Chat.delete_conversation(scope(bob), conv.id)
      assert is_nil(Repo.get(Conversation, conv.id))
      assert Repo.aggregate(Message, :count) == 0
      refute Eden.Storage.exists?(key)
    end

    test "GC spares a blob a forward elsewhere still references", %{alice: alice, bob: bob} do
      carol = user_fixture(%{username: "carolgc"})
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      {:ok, other} = Chat.create_conversation(scope(alice), [carol.id])
      {:ok, msg} = Chat.create_attachment_message(scope(alice), conv.id, %{path: real_png()})
      key = hd(msg.attachments).storage_key
      {:ok, _fwd} = Chat.forward_message(scope(alice), msg.id, other.id)

      :ok = Chat.delete_conversation(scope(alice), conv.id)
      :ok = Chat.delete_conversation(scope(bob), conv.id)

      assert is_nil(Repo.get(Conversation, conv.id))
      assert Eden.Storage.exists?(key)
    end

    test "a non-member gets :not_found", %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      dave = user_fixture(%{username: "davedc"})
      assert {:error, :not_found} = Chat.delete_conversation(scope(dave), conv.id)
    end

    test "leaving a group is permanent — new activity does not bring it back", %{
      alice: alice,
      bob: bob
    } do
      carol = user_fixture(%{username: "carolleave"})
      # alice creates the group (so she's the owner); a plain member (bob) leaves —
      # the owner can't leave while others remain (#165), tested separately.
      {:ok, group} = Chat.create_conversation(scope(alice), [bob.id, carol.id], title: "Trip")

      :ok = Chat.delete_conversation(scope(bob), group.id)
      assert [] == Chat.list_conversations(scope(bob))

      {:ok, _} = Chat.create_message(scope(alice), group.id, %{"body" => "still on?"})
      assert [] == Chat.list_conversations(scope(bob))
      assert [%{id: id}] = Chat.list_conversations(scope(alice))
      assert id == group.id
    end

    test "a member who left is not pinged about new activity", %{alice: alice, bob: bob} do
      carol = user_fixture(%{username: "carolping"})
      {:ok, group} = Chat.create_conversation(scope(alice), [bob.id, carol.id], title: "Trip")
      :ok = Chat.delete_conversation(scope(bob), group.id)

      Chat.subscribe_user(scope(bob))
      {:ok, _} = Chat.create_message(scope(alice), group.id, %{"body" => "yo"})
      refute_receive {:conversation_activity, _}
    end
  end

  describe "group roles & member management (#165)" do
    setup %{alice: alice, bob: bob} do
      carol = user_fixture(%{username: "carol_roles"})
      # alice creates → owner; bob + carol → member.
      {:ok, group} = Chat.create_conversation(scope(alice), [bob.id, carol.id], title: "Crew")
      %{group: group, carol: carol}
    end

    test "creator is owner, others are members", %{alice: alice, bob: bob, group: group} do
      assert Chat.group_role(scope(alice), group.id) == "owner"
      assert Chat.group_role(scope(bob), group.id) == "member"
    end

    test "owner promotes a member to admin and back", %{alice: alice, bob: bob, group: group} do
      assert :ok = Chat.set_group_member_role(scope(alice), group.id, bob.id, "admin")
      assert Chat.group_role(scope(bob), group.id) == "admin"
      assert :ok = Chat.set_group_member_role(scope(alice), group.id, bob.id, "member")
      assert Chat.group_role(scope(bob), group.id) == "member"
    end

    test "only the owner sets roles; an admin cannot", %{
      alice: alice,
      bob: bob,
      carol: carol,
      group: group
    } do
      :ok = Chat.set_group_member_role(scope(alice), group.id, bob.id, "admin")

      assert {:error, :forbidden} =
               Chat.set_group_member_role(scope(bob), group.id, carol.id, "admin")
    end

    test "the owner's role can't be changed, nor your own", %{alice: alice, group: group} do
      # alice (owner) targeting herself
      assert {:error, :self} =
               Chat.set_group_member_role(scope(alice), group.id, alice.id, "admin")
    end

    test "a hand-crafted role is rejected, not a crash", %{alice: alice, bob: bob, group: group} do
      assert {:error, :invalid_role} =
               Chat.set_group_member_role(scope(alice), group.id, bob.id, "owner")
    end

    test "owner removes a member; they're pinged and the group vanishes for them", %{
      alice: alice,
      bob: bob,
      group: group
    } do
      Chat.subscribe_user(scope(bob))
      assert :ok = Chat.remove_group_member(scope(alice), group.id, bob.id)
      assert_receive {:removed_from_conversation, id} when id == group.id
      assert [] == Chat.list_conversations(scope(bob))
      # still alive for the others
      assert [%{id: ^id}] = Chat.list_conversations(scope(alice))
    end

    test "owner removes an admin; admin removes a member; neither removes up the chain", %{
      alice: alice,
      bob: bob,
      carol: carol,
      group: group
    } do
      :ok = Chat.set_group_member_role(scope(alice), group.id, bob.id, "admin")
      # admin (bob) removes a plain member (carol)
      assert :ok = Chat.remove_group_member(scope(bob), group.id, carol.id)
      # owner removes the admin (bob)
      assert :ok = Chat.remove_group_member(scope(alice), group.id, bob.id)
    end

    test "an admin can't remove another admin or the owner", %{
      alice: alice,
      bob: bob,
      carol: carol,
      group: group
    } do
      :ok = Chat.set_group_member_role(scope(alice), group.id, bob.id, "admin")
      :ok = Chat.set_group_member_role(scope(alice), group.id, carol.id, "admin")
      assert {:error, :forbidden} = Chat.remove_group_member(scope(bob), group.id, carol.id)
      assert {:error, :forbidden} = Chat.remove_group_member(scope(bob), group.id, alice.id)
    end

    test "a plain member can remove no one", %{bob: bob, carol: carol, group: group} do
      assert {:error, :forbidden} = Chat.remove_group_member(scope(bob), group.id, carol.id)
    end

    test "you can't remove yourself, and non-members get :not_found", %{
      alice: alice,
      bob: bob,
      group: group
    } do
      assert {:error, :self} = Chat.remove_group_member(scope(alice), group.id, alice.id)
      dave = user_fixture(%{username: "dave_roles"})
      assert {:error, :not_found} = Chat.remove_group_member(scope(dave), group.id, bob.id)
    end

    test "owner can't leave while others remain, but can after transferring", %{
      alice: alice,
      bob: bob,
      group: group
    } do
      assert {:error, :owner} = Chat.delete_conversation(scope(alice), group.id)
      assert :ok = Chat.transfer_group_ownership(scope(alice), group.id, bob.id)
      assert Chat.group_role(scope(bob), group.id) == "owner"
      assert Chat.group_role(scope(alice), group.id) == "admin"
      # now the ex-owner (alice, an admin) can leave
      assert :ok = Chat.delete_conversation(scope(alice), group.id)
    end

    test "only the owner transfers ownership; not to self", %{
      alice: alice,
      bob: bob,
      carol: carol,
      group: group
    } do
      assert {:error, :self} = Chat.transfer_group_ownership(scope(alice), group.id, alice.id)
      assert {:error, :forbidden} = Chat.transfer_group_ownership(scope(bob), group.id, carol.id)
    end

    test "non-group conversations (1:1) reject role ops", %{alice: alice, bob: bob} do
      {:ok, dm} = Chat.create_conversation(scope(alice), [bob.id])
      assert {:error, :not_found} = Chat.remove_group_member(scope(alice), dm.id, bob.id)
      assert {:error, :not_found} = Chat.transfer_group_ownership(scope(alice), dm.id, bob.id)
    end

    test "owner adds a new member and a system notice is posted", %{alice: alice, group: group} do
      dave = user_fixture(%{username: "dave_add"})
      assert {:ok, [added]} = Chat.add_group_members(scope(alice), group.id, [dave.id])
      assert added.id == dave.id
      assert Chat.group_role(scope(dave), group.id) == "member"
      assert system_metas(group.id) |> Enum.any?(&match?(%{"action" => "member_added"}, &1))
    end

    test "an admin can add members; a plain member cannot", %{
      alice: alice,
      bob: bob,
      carol: carol,
      group: group
    } do
      dave = user_fixture(%{username: "dave_add2"})
      ervin = user_fixture(%{username: "ervin_add"})
      :ok = Chat.set_group_member_role(scope(alice), group.id, bob.id, "admin")
      assert {:ok, [_]} = Chat.add_group_members(scope(bob), group.id, [dave.id])
      assert {:error, :forbidden} = Chat.add_group_members(scope(carol), group.id, [ervin.id])
    end

    test "adding re-activates a previously removed member", %{
      alice: alice,
      carol: carol,
      group: group
    } do
      :ok = Chat.remove_group_member(scope(alice), group.id, carol.id)
      assert is_nil(Chat.group_role(scope(carol), group.id))
      assert {:ok, [back]} = Chat.add_group_members(scope(alice), group.id, [carol.id])
      assert back.id == carol.id
      assert Chat.group_role(scope(carol), group.id) == "member"
    end

    test "removing a member posts a removed system notice", %{
      alice: alice,
      carol: carol,
      group: group
    } do
      :ok = Chat.remove_group_member(scope(alice), group.id, carol.id)
      name = carol.display_name

      assert system_metas(group.id)
             |> Enum.any?(&match?(%{"action" => "member_removed", "name" => ^name}, &1))
    end

    test "a group system message doesn't count as unread", %{
      alice: alice,
      bob: bob,
      carol: carol,
      group: group
    } do
      Chat.mark_read(scope(bob), group.id)
      # Removing carol posts a system message; it must not bump bob's unread badge.
      :ok = Chat.remove_group_member(scope(alice), group.id, carol.id)
      for_bob = Chat.list_conversations(scope(bob)) |> Enum.find(&(&1.id == group.id))
      assert for_bob.unread_count == 0
    end

    test "a member removal doesn't blank the group's sidebar preview", %{
      alice: alice,
      bob: bob,
      carol: carol,
      group: group
    } do
      {:ok, _} = Chat.create_message(scope(alice), group.id, %{"body" => "real message"})
      # The removal posts a system notice (empty body) — the preview must still show the
      # last REAL message, not fall back to "no messages".
      :ok = Chat.remove_group_member(scope(alice), group.id, carol.id)
      for_bob = Chat.list_conversations(scope(bob)) |> Enum.find(&(&1.id == group.id))
      assert for_bob.last_message_body == "real message"
    end

    test "owner/admin can rename the group; a member cannot", %{
      alice: alice,
      bob: bob,
      group: group
    } do
      assert {:ok, renamed} = Chat.rename_group(scope(alice), group.id, "Expedition")
      assert renamed.title == "Expedition"
      assert {:error, :forbidden} = Chat.rename_group(scope(bob), group.id, "Hijacked")
    end

    test "renaming with a blank title reverts to the auto name", %{alice: alice, group: group} do
      {:ok, _} = Chat.rename_group(scope(alice), group.id, "Temp")
      assert {:ok, reverted} = Chat.rename_group(scope(alice), group.id, "   ")
      assert is_nil(reverted.title)
    end

    test "re-adding a previously-removed admin returns them as a plain member", %{
      alice: alice,
      bob: bob,
      group: group
    } do
      :ok = Chat.set_group_member_role(scope(alice), group.id, bob.id, "admin")
      :ok = Chat.remove_group_member(scope(alice), group.id, bob.id)
      assert {:ok, [_]} = Chat.add_group_members(scope(alice), group.id, [bob.id])
      assert Chat.group_role(scope(bob), group.id) == "member"
    end
  end

  describe "create_attachment_message/3" do
    setup %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      %{conv: conv}
    end

    test "stores the image and creates a message with an attachment", %{alice: alice, conv: conv} do
      path = image_path(@png_signature <> "fake-png-body")

      assert {:ok, message} =
               Chat.create_attachment_message(scope(alice), conv.id, %{path: path, body: "look"})

      assert message.body == "look"
      assert hd(message.attachments).kind == "image"
      assert hd(message.attachments).content_type == "image/png"
      assert hd(message.attachments).byte_size > 0
      assert Eden.Storage.exists?(hd(message.attachments).storage_key)
    end

    test "allows a photo with no caption", %{alice: alice, conv: conv} do
      path = image_path(@png_signature <> "x")
      assert {:ok, message} = Chat.create_attachment_message(scope(alice), conv.id, %{path: path})
      assert message.body == ""
      assert hd(message.attachments)
    end

    test "accepts an arbitrary file as kind=file with a safe type and sanitized name", %{
      alice: alice,
      conv: conv
    } do
      path = image_path("just plain text, not an image")

      assert {:ok, message} =
               Chat.create_attachment_message(scope(alice), conv.id, %{
                 path: path,
                 filename: "../notes.txt"
               })

      assert hd(message.attachments).kind == "file"
      assert hd(message.attachments).content_type == "application/octet-stream"
      assert hd(message.attachments).filename == "notes.txt"
    end

    test "detects an mp4 video by magic bytes", %{alice: alice, conv: conv} do
      path = image_path(<<0, 0, 0, 0x18>> <> "ftypisom" <> :binary.copy("0", 16))

      assert {:ok, message} = Chat.create_attachment_message(scope(alice), conv.id, %{path: path})
      assert hd(message.attachments).kind == "video"
      assert hd(message.attachments).content_type == "video/mp4"
    end

    test "detects a webm video by magic bytes", %{alice: alice, conv: conv} do
      path = image_path(<<0x1A, 0x45, 0xDF, 0xA3>> <> :binary.copy("0", 16))

      assert {:ok, message} = Chat.create_attachment_message(scope(alice), conv.id, %{path: path})
      assert hd(message.attachments).kind == "video"
      assert hd(message.attachments).content_type == "video/webm"
    end

    test "detects a pdf as a file", %{alice: alice, conv: conv} do
      path = image_path("%PDF-1.7\n" <> :binary.copy("0", 16))

      assert {:ok, message} =
               Chat.create_attachment_message(scope(alice), conv.id, %{
                 path: path,
                 filename: "report.pdf"
               })

      assert hd(message.attachments).kind == "file"
      assert hd(message.attachments).content_type == "application/pdf"
    end

    test "rejects an empty (0-byte) upload", %{alice: alice, conv: conv} do
      path = image_path("")

      assert {:error, :empty} =
               Chat.create_attachment_message(scope(alice), conv.id, %{
                 path: path,
                 filename: "x.txt"
               })
    end

    test "rejects an image over the image cap", %{alice: alice, conv: conv} do
      path = image_path(@png_signature <> :binary.copy("x", 8 * 1024 * 1024 + 1))

      assert {:error, :too_large} =
               Chat.create_attachment_message(scope(alice), conv.id, %{path: path})
    end

    test "allows a video larger than the image cap (per-kind limits)", %{alice: alice, conv: conv} do
      # 9 MB exceeds the 8 MB image cap but is well under the 50 MB video cap.
      body = <<0, 0, 0, 0x18>> <> "ftypisom" <> :binary.copy("v", 9 * 1024 * 1024)
      path = image_path(body)

      assert {:ok, message} = Chat.create_attachment_message(scope(alice), conv.id, %{path: path})
      assert hd(message.attachments).kind == "video"
    end

    test "non-members cannot post a photo", %{conv: conv} do
      dave = user_fixture(%{username: "davephoto"})
      path = image_path(@png_signature <> "x")

      assert {:error, :not_found} =
               Chat.create_attachment_message(scope(dave), conv.id, %{path: path})
    end

    test "broadcasts the photo message with the attachment preloaded", %{alice: alice, conv: conv} do
      Chat.subscribe(conv.id)
      path = image_path(@png_signature <> "x")
      {:ok, _} = Chat.create_attachment_message(scope(alice), conv.id, %{path: path})
      assert_receive {:new_message, message}
      assert hd(message.attachments).content_type == "image/png"
    end

    test "enqueues a thumbnail job on the media queue", %{alice: alice, conv: conv} do
      {:ok, message} = Chat.create_attachment_message(scope(alice), conv.id, %{path: real_png()})

      assert_enqueued(
        worker: ThumbnailWorker,
        queue: :media,
        args: %{attachment_id: hd(message.attachments).id}
      )
    end

    test "enqueues a media job for a video too", %{alice: alice, conv: conv} do
      path = image_path(<<0, 0, 0, 0x18>> <> "ftypisom" <> :binary.copy("0", 16))
      {:ok, message} = Chat.create_attachment_message(scope(alice), conv.id, %{path: path})

      assert hd(message.attachments).kind == "video"
      assert_enqueued(worker: ThumbnailWorker, args: %{attachment_id: hd(message.attachments).id})
    end

    test "does not enqueue a media job for a plain file", %{alice: alice, conv: conv} do
      path = image_path("just some text")

      {:ok, message} =
        Chat.create_attachment_message(scope(alice), conv.id, %{path: path, filename: "a.txt"})

      assert hd(message.attachments).kind == "file"
      refute_enqueued(worker: ThumbnailWorker, args: %{attachment_id: hd(message.attachments).id})
    end
  end

  describe "create_album_message/4 (#58)" do
    setup %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      %{conv: conv}
    end

    test "stores several attachments in order on one message", %{alice: alice, conv: conv} do
      sources = [
        %{path: image_path(@png_signature <> "a"), filename: "1.png"},
        %{path: image_path("plain text"), filename: "notes.txt"},
        %{path: image_path(@png_signature <> "c"), filename: "3.png"}
      ]

      assert {:ok, message} =
               Chat.create_album_message(scope(alice), conv.id, sources, %{body: "trip"})

      assert message.body == "trip"
      kinds = Enum.map(message.attachments, & &1.kind)
      assert kinds == ["image", "file", "image"]
      assert Enum.map(message.attachments, & &1.position) == [0, 1, 2]
      assert Enum.all?(message.attachments, &Eden.Storage.exists?(&1.storage_key))
    end

    test "enqueues media processing per image/video, not for files", %{alice: alice, conv: conv} do
      sources = [
        %{path: image_path(@png_signature <> "a"), filename: "1.png"},
        %{path: image_path("plain text"), filename: "notes.txt"}
      ]

      {:ok, message} = Chat.create_album_message(scope(alice), conv.id, sources, %{})
      [img, file] = message.attachments
      assert_enqueued(worker: ThumbnailWorker, args: %{attachment_id: img.id})
      refute_enqueued(worker: ThumbnailWorker, args: %{attachment_id: file.id})
    end

    test "rejects an empty list and an over-cap album", %{alice: alice, conv: conv} do
      assert {:error, :empty} = Chat.create_album_message(scope(alice), conv.id, [], %{})

      too_many =
        for i <- 1..11, do: %{path: image_path(@png_signature <> "#{i}"), filename: "#{i}.png"}

      assert {:error, :too_many} = Chat.create_album_message(scope(alice), conv.id, too_many, %{})
    end

    test "rolls back every stored blob when one source is too large", %{alice: alice, conv: conv} do
      big = @png_signature <> :binary.copy("x", 8 * 1024 * 1024 + 1)

      sources = [
        %{path: image_path(@png_signature <> "ok"), filename: "ok.png"},
        %{path: image_path(big), filename: "huge.png"}
      ]

      assert {:error, :too_large} = Chat.create_album_message(scope(alice), conv.id, sources, %{})
      # The first blob, stored before the failure, must not leak.
      assert Repo.aggregate(Attachment, :count) == 0
    end

    test "forwarding an album copies every attachment, sharing blobs", %{
      alice: alice,
      bob: bob,
      conv: conv
    } do
      {:ok, other} = Chat.create_conversation(scope(alice), [bob.id])

      sources = [
        %{path: image_path(@png_signature <> "a"), filename: "1.png"},
        %{path: image_path(@png_signature <> "b"), filename: "2.png"}
      ]

      {:ok, original} = Chat.create_album_message(scope(alice), conv.id, sources, %{})
      {:ok, forwarded} = Chat.forward_message(scope(alice), original.id, other.id)
      forwarded = Repo.preload(forwarded, :attachments)

      assert length(forwarded.attachments) == 2
      assert Enum.map(forwarded.attachments, & &1.position) == [0, 1]

      assert Enum.map(forwarded.attachments, & &1.storage_key) ==
               Enum.map(original.attachments, & &1.storage_key)
    end

    test "delete-for-both removes every unshared blob of the album", %{alice: alice, conv: conv} do
      sources = [
        %{path: image_path(@png_signature <> "a"), filename: "1.png"},
        %{path: image_path(@png_signature <> "b"), filename: "2.png"}
      ]

      {:ok, message} = Chat.create_album_message(scope(alice), conv.id, sources, %{})
      keys = Enum.map(message.attachments, & &1.storage_key)
      assert Enum.all?(keys, &Eden.Storage.exists?/1)

      :ok = Chat.delete_message_for_both(scope(alice), message.id)
      refute Enum.any?(keys, &Eden.Storage.exists?/1)
      assert Repo.aggregate(Attachment, :count) == 0
    end
  end

  describe "create_attachments/4 — media album + separate files (#58)" do
    setup %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      %{conv: conv}
    end

    test "photos group into one album; each file is its own message", %{alice: alice, conv: conv} do
      sources = [
        %{path: image_path(@png_signature <> "a"), filename: "1.png"},
        %{path: image_path("plain doc one"), filename: "a.txt"},
        %{path: image_path(@png_signature <> "b"), filename: "2.png"},
        %{path: image_path("plain doc two"), filename: "b.txt"}
      ]

      assert {:ok, messages} =
               Chat.create_attachments(scope(alice), conv.id, sources, %{body: "trip"})

      # 1 album (2 photos) + 2 file messages = 3 messages.
      assert length(messages) == 3
      [album | files] = messages

      # The album holds only the photos, in order, with the caption.
      assert album.body == "trip"
      assert Enum.map(album.attachments, & &1.kind) == ["image", "image"]

      # Each file is a standalone single-attachment message; no file in the album.
      assert Enum.all?(files, fn m ->
               [a] = m.attachments
               a.kind == "file"
             end)

      refute Enum.any?(album.attachments, &(&1.kind == "file"))
    end

    test "files only: caption rides the first file, the rest are plain", %{
      alice: alice,
      conv: conv
    } do
      sources = [
        %{path: image_path("doc one"), filename: "a.txt"},
        %{path: image_path("doc two"), filename: "b.txt"}
      ]

      assert {:ok, [first, second]} =
               Chat.create_attachments(scope(alice), conv.id, sources, %{body: "here"})

      assert first.body == "here"
      assert second.body == ""
    end

    test "media only: a single album message", %{alice: alice, conv: conv} do
      sources = [
        %{path: image_path(@png_signature <> "a"), filename: "1.png"},
        %{path: image_path(@png_signature <> "b"), filename: "2.png"}
      ]

      assert {:ok, [album]} = Chat.create_attachments(scope(alice), conv.id, sources, %{})
      assert length(album.attachments) == 2
    end

    test "one oversized file fails the whole batch — nothing is sent", %{alice: alice, conv: conv} do
      big = @png_signature <> :binary.copy("x", 8 * 1024 * 1024 + 1)

      sources = [
        %{path: image_path(@png_signature <> "ok"), filename: "ok.png"},
        %{path: image_path(big), filename: "huge.png"}
      ]

      assert {:error, :too_large} = Chat.create_attachments(scope(alice), conv.id, sources, %{})
      # Preflight rejects before any message/blob is created (no partial album).
      assert Repo.aggregate(Message, :count) == 0
      assert Repo.aggregate(Attachment, :count) == 0
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
        Chat.create_attachment_message(scope(alice), conv.id, %{path: real_png(1200, 800)})

      # Original dimensions are known immediately (before any thumbnail), so the
      # first render can reserve layout space.
      assert hd(message.attachments).width == 1200
      assert hd(message.attachments).height == 800

      assert :ok = Chat.generate_thumbnail(hd(message.attachments))

      attachment = Repo.get(Attachment, hd(message.attachments).id)
      assert is_binary(attachment.thumbnail_key)
      assert attachment.width == 1200
      assert attachment.height == 800
      assert Eden.Storage.exists?(attachment.thumbnail_key)

      {:ok, thumb_bytes} = Eden.Storage.read(attachment.thumbnail_key)
      {:ok, thumb} = Image.from_binary(thumb_bytes)
      assert max(Image.width(thumb), Image.height(thumb)) == 800

      assert_receive {:thumbnail_ready, broadcast}
      assert hd(broadcast.attachments).thumbnail_key == attachment.thumbnail_key
    end

    test "never upscales an image smaller than the target", %{alice: alice, conv: conv} do
      {:ok, message} =
        Chat.create_attachment_message(scope(alice), conv.id, %{path: real_png(300, 200)})

      assert :ok = Chat.generate_thumbnail(hd(message.attachments))

      attachment = Repo.get(Attachment, hd(message.attachments).id)
      {:ok, thumb_bytes} = Eden.Storage.read(attachment.thumbnail_key)
      {:ok, thumb} = Image.from_binary(thumb_bytes)
      assert Image.width(thumb) == 300
      assert Image.height(thumb) == 200
    end

    test "the worker generates the thumbnail and is idempotent", %{alice: alice, conv: conv} do
      {:ok, message} = Chat.create_attachment_message(scope(alice), conv.id, %{path: real_png()})
      args = %{attachment_id: hd(message.attachments).id}

      assert :ok = perform_job(ThumbnailWorker, args)
      first_key = Repo.get(Attachment, hd(message.attachments).id).thumbnail_key
      assert is_binary(first_key)

      assert :ok = perform_job(ThumbnailWorker, args)
      assert Repo.get(Attachment, hd(message.attachments).id).thumbnail_key == first_key
    end

    test "the worker is a no-op for a missing attachment" do
      assert :ok = perform_job(ThumbnailWorker, %{attachment_id: 999_999})
    end

    test "a corrupt image fails gracefully and the worker cancels (no retries)",
         %{alice: alice, conv: conv} do
      # Valid PNG magic bytes (passes upload detection) but not a decodable image.
      path = image_path(@png_signature <> "not actually a png body")
      {:ok, message} = Chat.create_attachment_message(scope(alice), conv.id, %{path: path})

      assert {:error, {:unprocessable, _}} = Chat.generate_thumbnail(hd(message.attachments))

      assert {:cancel, {:unprocessable, _}} =
               perform_job(ThumbnailWorker, %{attachment_id: hd(message.attachments).id})

      refute Repo.get(Attachment, hd(message.attachments).id).thumbnail_key
    end

    @tag :ffmpeg
    test "generates a poster frame and reads a video's duration + dimensions",
         %{alice: alice, conv: conv} do
      Chat.subscribe(conv.id)

      {:ok, message} =
        Chat.create_attachment_message(scope(alice), conv.id, %{
          path: real_mp4(),
          filename: "clip.mp4"
        })

      assert hd(message.attachments).kind == "video"
      # Video dimensions/duration are unknown until the worker probes the file.
      assert is_nil(hd(message.attachments).thumbnail_key)
      assert is_nil(hd(message.attachments).duration)

      assert :ok = perform_job(ThumbnailWorker, %{attachment_id: hd(message.attachments).id})

      attachment = Repo.get(Attachment, hd(message.attachments).id)
      assert is_binary(attachment.thumbnail_key)
      assert Eden.Storage.exists?(attachment.thumbnail_key)
      assert attachment.width == 320
      assert attachment.height == 240
      # The test clip is 1 second.
      assert attachment.duration in 800..1300

      # The stored poster is a real, downscaled JPEG.
      {:ok, poster_bytes} = Eden.Storage.read(attachment.thumbnail_key)
      {:ok, poster} = Image.from_binary(poster_bytes)
      assert max(Image.width(poster), Image.height(poster)) <= 800

      assert_receive {:thumbnail_ready, _broadcast}
    end

    @tag :ffmpeg
    test "records duration even when no poster frame can be extracted (audio-only mp4)",
         %{alice: alice, conv: conv} do
      {:ok, message} =
        Chat.create_attachment_message(scope(alice), conv.id, %{
          path: audio_mp4(),
          filename: "voice.mp4"
        })

      assert hd(message.attachments).kind == "video"
      assert :ok = perform_job(ThumbnailWorker, %{attachment_id: hd(message.attachments).id})

      attachment = Repo.get(Attachment, hd(message.attachments).id)
      # No video stream → no poster, but the duration is still saved.
      assert is_nil(attachment.thumbnail_key)
      assert attachment.duration in 800..1300
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

  describe "list_messages_around/3 (#jump)" do
    setup %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      # More than the default page (50) so the oldest rows fall OUTSIDE the page
      # the stream loads by default — the exact condition the window load exists for.
      msgs =
        for n <- 1..55 do
          {:ok, m} = Chat.create_message(scope(alice), conv.id, %{"body" => "m#{n}"})
          m
        end

      %{conv: conv, msgs: msgs}
    end

    test "loads a window that includes an anchor older than the default page", %{
      alice: alice,
      conv: conv,
      msgs: msgs
    } do
      oldest = hd(msgs)

      # The default page is the 50 newest, so the oldest message is NOT in it.
      {:ok, page} = Chat.list_messages(scope(alice), conv.id)
      refute Enum.any?(page, &(&1.id == oldest.id))

      # The window around it includes it, oldest-first, sender preloaded.
      {:ok, around, _has_more} = Chat.list_messages_around(scope(alice), conv.id, oldest.id)
      assert Enum.any?(around, &(&1.id == oldest.id))
      assert hd(around).id == oldest.id
      assert hd(around).sender.display_name == "Alice"
    end

    test "has_more reflects whether older messages exist before the window", %{
      alice: alice,
      conv: conv,
      msgs: msgs
    } do
      # Anchor near the newest → the 50-row newest window leaves the oldest 5 behind.
      recent = Enum.at(msgs, 52)
      {:ok, _window, has_more} = Chat.list_messages_around(scope(alice), conv.id, recent.id)
      assert has_more

      # Anchor at the very oldest → the window reaches it, nothing older remains.
      {:ok, _all, has_more2} = Chat.list_messages_around(scope(alice), conv.id, hd(msgs).id)
      refute has_more2
    end

    test "non-members cannot read", %{conv: conv} do
      dave = user_fixture(%{username: "dave_jump"})
      assert {:error, :not_found} = Chat.list_messages_around(scope(dave), conv.id, 1)
    end

    test "a non-numeric anchor returns :not_found instead of raising (#168 regression)", %{
      alice: alice,
      conv: conv
    } do
      assert {:error, :not_found} = Chat.list_messages_around(scope(alice), conv.id, "abc")
      assert {:error, :not_found} = Chat.list_messages_around(scope(alice), conv.id, nil)
    end

    test "a deep jump (> the window cap above latest) loads an anchor-anchored window", %{
      alice: alice,
      bob: bob
    } do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      # Cross the @jump_window cap (300) so the anchor-anchored branch runs. insert_all to
      # keep it cheap; ids are serial so the natural order matches list_messages_around's.
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      rows =
        for n <- 1..320 do
          %{
            body: "b#{n}",
            kind: "user",
            meta: %{},
            reply_count: 0,
            conversation_id: conv.id,
            sender_id: alice.id,
            inserted_at: now,
            updated_at: now
          }
        end

      {320, inserted} = Eden.Repo.insert_all(Message, rows, returning: [:id])
      ids = inserted |> Enum.map(& &1.id) |> Enum.sort()
      # 2nd-oldest: > 300 messages at-or-after it (deep branch) AND one older remains.
      anchor = Enum.at(ids, 1)

      {:ok, window, has_more} = Chat.list_messages_around(scope(alice), conv.id, anchor)

      window_ids = Enum.map(window, & &1.id)
      assert length(window) == 300, "window is capped at @jump_window"
      assert hd(window).id == anchor, "anchor-anchored: it's the oldest loaded row"
      assert window_ids == Enum.sort(window_ids), "oldest-first"
      assert has_more, "the one older message still exists before the window"
    end
  end

  describe "main_stream_message?/3 (#jump)" do
    setup %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      {:ok, m} = Chat.create_message(scope(alice), conv.id, %{"body" => "hi"})
      %{conv: conv, m: m}
    end

    test "true for a live, visible main-stream message", %{alice: alice, conv: conv, m: m} do
      assert Chat.main_stream_message?(scope(alice), conv.id, m.id)
    end

    test "false for a message the viewer hid (delete for me)", %{
      alice: alice,
      bob: bob,
      conv: conv,
      m: m
    } do
      :ok = Chat.delete_message_for_me(scope(bob), m.id)
      refute Chat.main_stream_message?(scope(bob), conv.id, m.id)
      # Still visible to the other member, who didn't hide it.
      assert Chat.main_stream_message?(scope(alice), conv.id, m.id)
    end

    test "false once soft-deleted for everyone", %{alice: alice, conv: conv, m: m} do
      :ok = Chat.delete_message_for_both(scope(alice), m.id)
      refute Chat.main_stream_message?(scope(alice), conv.id, m.id)
    end

    test "false for an unknown id and for non-members", %{alice: alice, conv: conv} do
      refute Chat.main_stream_message?(scope(alice), conv.id, 9_999_999)
      # A non-numeric id (raw URL / crafted event string) must degrade to false, not raise
      # Ecto.Query.CastError and crash the LiveView (#168 jump regression).
      refute Chat.main_stream_message?(scope(alice), conv.id, "abc")
      refute Chat.main_stream_message?(scope(alice), conv.id, nil)
      dave = user_fixture(%{username: "dave_msg"})
      refute Chat.main_stream_message?(scope(dave), conv.id, 1)
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

    test "sets last_message_kind when the last message is an attachment", %{
      alice: alice,
      bob: bob
    } do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      {:ok, _} = Chat.create_message(scope(alice), conv.id, %{"body" => "hi"})
      {:ok, _} = Chat.create_attachment_message(scope(alice), conv.id, %{path: real_png()})

      [listed] = Chat.list_conversations(scope(alice))
      assert listed.last_message_kind == "image"
      assert listed.last_message_body == ""

      # get_conversation_summary mirrors the same enrichment
      {:ok, summary} = Chat.get_conversation_summary(scope(alice), conv.id)
      assert summary.last_message_kind == "image"

      # A plain text message leaves it nil.
      {:ok, _} = Chat.create_message(scope(alice), conv.id, %{"body" => "back to text"})
      [text_last] = Chat.list_conversations(scope(alice))
      assert is_nil(text_last.last_message_kind)
    end

    test "the preview skips a message the user deleted for themselves", %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      {:ok, _first} = Chat.create_message(scope(alice), conv.id, %{"body" => "first"})
      {:ok, last} = Chat.create_message(scope(alice), conv.id, %{"body" => "last"})

      :ok = Chat.delete_message_for_me(scope(bob), last.id)

      # Bob's preview falls back to the message before the one he hid.
      assert [%{last_message_body: "first"}] = Chat.list_conversations(scope(bob))
      # Alice still sees the latest.
      assert [%{last_message_body: "last"}] = Chat.list_conversations(scope(alice))
    end

    test "the preview skips a deleted-for-both last message", %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      {:ok, _first} = Chat.create_message(scope(alice), conv.id, %{"body" => "keep"})
      {:ok, last} = Chat.create_message(scope(alice), conv.id, %{"body" => "remove"})
      :ok = Chat.delete_message_for_both(scope(alice), last.id)

      # Falls back to the message before the deleted one.
      assert [%{last_message_body: "keep"}] = Chat.list_conversations(scope(bob))
    end

    test "unread skips tombstones and self-hidden messages", %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      {:ok, _one} = Chat.create_message(scope(alice), conv.id, %{"body" => "1"})
      {:ok, two} = Chat.create_message(scope(alice), conv.id, %{"body" => "2"})
      {:ok, three} = Chat.create_message(scope(alice), conv.id, %{"body" => "3"})

      assert [%{unread_count: 3}] = Chat.list_conversations(scope(bob))

      :ok = Chat.delete_message_for_both(scope(alice), two.id)
      :ok = Chat.delete_message_for_me(scope(bob), three.id)

      assert [%{unread_count: 1}] = Chat.list_conversations(scope(bob))
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

  describe "folders" do
    test "create, list (ordered), rename, and delete", %{alice: alice} do
      {:ok, work} = Chat.create_folder(scope(alice), %{"name" => "Work"})
      {:ok, _fam} = Chat.create_folder(scope(alice), %{"name" => "Family"})

      assert ["Work", "Family"] == Enum.map(Chat.list_folders(scope(alice)), & &1.name)

      {:ok, renamed} = Chat.rename_folder(scope(alice), work.id, "Job")
      assert renamed.name == "Job"

      assert :ok = Chat.delete_folder(scope(alice), work.id)
      assert ["Family"] == Enum.map(Chat.list_folders(scope(alice)), & &1.name)
    end

    test "name is trimmed and length-capped", %{alice: alice} do
      {:ok, f} = Chat.create_folder(scope(alice), %{"name" => "  Trips  "})
      assert f.name == "Trips"

      too_long = String.duplicate("x", Eden.Chat.Folder.max_name() + 1)
      assert {:error, %Ecto.Changeset{}} = Chat.create_folder(scope(alice), %{"name" => too_long})
    end

    test "folder count is capped", %{alice: alice} do
      for n <- 1..Chat.max_folders() do
        {:ok, _} = Chat.create_folder(scope(alice), %{"name" => "F#{n}"})
      end

      assert {:error, :limit} = Chat.create_folder(scope(alice), %{"name" => "One more"})
    end

    test "toggle survives the row vanishing concurrently", %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      {:ok, folder} = Chat.create_folder(scope(alice), %{"name" => "Work"})
      {:ok, :added} = Chat.toggle_conversation_folder(scope(alice), conv.id, folder.id)

      # Simulate another session removing the membership between the read and
      # the delete: delete_all must not raise (Repo.delete would).
      Repo.delete_all(Eden.Chat.FolderMembership)
      assert {:ok, :added} = Chat.toggle_conversation_folder(scope(alice), conv.id, folder.id)
    end

    test "reorder reassigns positions and ignores foreign ids", %{alice: alice, bob: bob} do
      {:ok, a} = Chat.create_folder(scope(alice), %{"name" => "A"})
      {:ok, b} = Chat.create_folder(scope(alice), %{"name" => "B"})
      {:ok, c} = Chat.create_folder(scope(alice), %{"name" => "C"})
      {:ok, foreign} = Chat.create_folder(scope(bob), %{"name" => "Bob"})

      :ok = Chat.reorder_folders(scope(alice), [c.id, a.id, b.id, foreign.id])
      assert ["C", "A", "B"] == Enum.map(Chat.list_folders(scope(alice)), & &1.name)
      # Bob's folder is untouched.
      assert ["Bob"] == Enum.map(Chat.list_folders(scope(bob)), & &1.name)
    end

    test "the virtual All Chats tab can be reordered (but has no row)", %{alice: alice} do
      {:ok, a} = Chat.create_folder(scope(alice), %{"name" => "A"})
      {:ok, b} = Chat.create_folder(scope(alice), %{"name" => "B"})

      # Defaults to first.
      assert 0 == Chat.all_chats_position(scope(alice))

      :ok = Chat.reorder_folders(scope(alice), [to_string(a.id), "all", to_string(b.id)])
      assert 1 == Chat.all_chats_position(scope(alice))
      assert ["A", "B"] == Enum.map(Chat.list_folders(scope(alice)), & &1.name)

      # Reordering again overwrites (upsert), and folder order still applies.
      :ok = Chat.reorder_folders(scope(alice), [to_string(b.id), to_string(a.id), "all"])
      assert 2 == Chat.all_chats_position(scope(alice))
      assert ["B", "A"] == Enum.map(Chat.list_folders(scope(alice)), & &1.name)
    end

    test "toggle adds then removes a chat; conversation_folder_ids reflects it", %{
      alice: alice,
      bob: bob
    } do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      {:ok, folder} = Chat.create_folder(scope(alice), %{"name" => "Work"})

      assert {:ok, :added} = Chat.toggle_conversation_folder(scope(alice), conv.id, folder.id)
      assert [folder.id] == Chat.conversation_folder_ids(scope(alice), conv.id)

      assert {:ok, :removed} = Chat.toggle_conversation_folder(scope(alice), conv.id, folder.id)
      assert [] == Chat.conversation_folder_ids(scope(alice), conv.id)
    end

    test "list_conversations filters by folder; All Chats shows everything", %{
      alice: alice,
      bob: bob
    } do
      carol = user_fixture(%{username: "carolf"})
      {:ok, c1} = Chat.create_conversation(scope(alice), [bob.id])
      {:ok, _c2} = Chat.create_conversation(scope(alice), [carol.id])
      {:ok, folder} = Chat.create_folder(scope(alice), %{"name" => "Work"})
      {:ok, :added} = Chat.toggle_conversation_folder(scope(alice), c1.id, folder.id)

      assert [c1.id] == Enum.map(Chat.list_conversations(scope(alice), folder.id), & &1.id)
      assert 2 == length(Chat.list_conversations(scope(alice), nil))
    end

    test "per-folder unread badge counts only the folder's chats", %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      {:ok, folder} = Chat.create_folder(scope(alice), %{"name" => "Work"})
      {:ok, :added} = Chat.toggle_conversation_folder(scope(alice), conv.id, folder.id)

      {:ok, _} = Chat.create_message(scope(bob), conv.id, %{"body" => "ping"})
      {:ok, _} = Chat.create_message(scope(bob), conv.id, %{"body" => "ping2"})

      assert [%{unread_count: 2}] = Chat.list_folders(scope(alice))
    end

    test "deleting a folder keeps the conversations", %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      {:ok, folder} = Chat.create_folder(scope(alice), %{"name" => "Work"})
      {:ok, :added} = Chat.toggle_conversation_folder(scope(alice), conv.id, folder.id)

      :ok = Chat.delete_folder(scope(alice), folder.id)
      assert [%{id: id}] = Chat.list_conversations(scope(alice))
      assert id == conv.id
    end

    test "deleting a conversation drops it from its folders", %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      {:ok, folder} = Chat.create_folder(scope(alice), %{"name" => "Work"})
      {:ok, :added} = Chat.toggle_conversation_folder(scope(alice), conv.id, folder.id)

      # Both members leave -> GC hard-deletes the conversation, cascading the join.
      :ok = Chat.delete_conversation(scope(alice), conv.id)
      :ok = Chat.delete_conversation(scope(bob), conv.id)

      assert [] == Chat.conversation_folder_ids(scope(alice), conv.id)
    end

    test "is per-user: foreign folder/conversation ids are rejected", %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      {:ok, folder} = Chat.create_folder(scope(alice), %{"name" => "Work"})

      # Bob can't file Alice's-only folder, nor toggle a chat he's a member of into it.
      assert {:error, :not_found} =
               Chat.toggle_conversation_folder(scope(bob), conv.id, folder.id)

      assert {:error, :not_found} = Chat.rename_folder(scope(bob), folder.id, "Hack")
      assert {:error, :not_found} = Chat.delete_folder(scope(bob), folder.id)
    end
  end

  describe "mute" do
    test "toggling a chat mutes it for that user only", %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])

      assert {:ok, :muted} = Chat.toggle_conversation_mute(scope(alice), conv.id)
      assert [%{muted: true}] = Chat.list_conversations(scope(alice))
      assert [%{muted: false}] = Chat.list_conversations(scope(bob))

      assert {:ok, :unmuted} = Chat.toggle_conversation_mute(scope(alice), conv.id)
      assert [%{muted: false}] = Chat.list_conversations(scope(alice))
    end

    test "a non-member cannot mute", %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      carol = user_fixture(%{username: "carolmute"})
      assert {:error, :not_found} = Chat.toggle_conversation_mute(scope(carol), conv.id)
    end

    test "a muted chat stops counting toward folder badges", %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      {:ok, folder} = Chat.create_folder(scope(alice), %{"name" => "Work"})
      {:ok, :added} = Chat.toggle_conversation_folder(scope(alice), conv.id, folder.id)
      {:ok, _} = Chat.create_message(scope(bob), conv.id, %{"body" => "ping"})

      assert [%{unread_count: 1}] = Chat.list_folders(scope(alice))

      {:ok, :muted} = Chat.toggle_conversation_mute(scope(alice), conv.id)
      assert [%{unread_count: 0}] = Chat.list_folders(scope(alice))
      # The chat's own unread is still tracked (just de-emphasized in the UI).
      assert [%{unread_count: 1, muted: true}] = Chat.list_conversations(scope(alice))
    end

    test "muting a folder mutes its chats everywhere", %{alice: alice, bob: bob} do
      carol = user_fixture(%{username: "carolfm"})
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      {:ok, _other} = Chat.create_conversation(scope(alice), [carol.id])
      {:ok, muted_folder} = Chat.create_folder(scope(alice), %{"name" => "Muted"})
      {:ok, other_folder} = Chat.create_folder(scope(alice), %{"name" => "Other"})
      {:ok, :added} = Chat.toggle_conversation_folder(scope(alice), conv.id, muted_folder.id)
      {:ok, :added} = Chat.toggle_conversation_folder(scope(alice), conv.id, other_folder.id)
      {:ok, _} = Chat.create_message(scope(bob), conv.id, %{"body" => "ping"})

      assert {:ok, :muted} = Chat.toggle_folder_mute(scope(alice), muted_folder.id)

      # The chat is effectively muted, and contributes to NO folder badge —
      # including the other, unmuted folder it also lives in.
      muted_ids =
        Chat.list_conversations(scope(alice)) |> Enum.filter(& &1.muted) |> Enum.map(& &1.id)

      assert muted_ids == [conv.id]
      assert Enum.all?(Chat.list_folders(scope(alice)), &(&1.unread_count == 0))
    end

    test "un-muting a folder keeps a direct chat mute", %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      {:ok, folder} = Chat.create_folder(scope(alice), %{"name" => "Work"})
      {:ok, :added} = Chat.toggle_conversation_folder(scope(alice), conv.id, folder.id)

      {:ok, :muted} = Chat.toggle_conversation_mute(scope(alice), conv.id)
      {:ok, :muted} = Chat.toggle_folder_mute(scope(alice), folder.id)
      {:ok, :unmuted} = Chat.toggle_folder_mute(scope(alice), folder.id)

      assert [%{muted: true}] = Chat.list_conversations(scope(alice))
    end

    test "a foreign folder cannot be muted", %{alice: alice, bob: _bob} do
      {:ok, folder} = Chat.create_folder(scope(alice), %{"name" => "Mine"})
      dave = user_fixture(%{username: "davemute"})
      assert {:error, :not_found} = Chat.toggle_folder_mute(scope(dave), folder.id)
    end
  end

  describe "search/2" do
    test "finds messages by content, scoped to own conversations", %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      {:ok, msg} = Chat.create_message(scope(bob), conv.id, %{"body" => "secret rendezvous"})

      # Dave shares nothing with them — must see no results.
      dave = user_fixture(%{username: "daves"})

      assert %{messages: [found]} = Chat.search(scope(alice), "rendezvous")
      assert found.id == msg.id
      assert found.conversation.id == conv.id

      assert %{messages: [], conversations: []} = Chat.search(scope(dave), "rendezvous")
    end

    test "finds conversations by participant name, username, and group title", %{
      alice: alice,
      bob: bob
    } do
      carol = user_fixture(%{username: "carolsrch", display_name: "Carol Searchova"})
      {:ok, direct} = Chat.create_conversation(scope(alice), [carol.id])

      {:ok, group} =
        Chat.create_conversation(scope(alice), [bob.id, carol.id], title: "Expedition")

      # Carol is in both the 1:1 and the group — both surface.
      assert %{conversations: convs} = Chat.search(scope(alice), "Searchova")
      assert Enum.sort(Enum.map(convs, & &1.id)) == Enum.sort([direct.id, group.id])

      assert %{conversations: by_username} = Chat.search(scope(alice), "carolsrch")
      assert Enum.sort(Enum.map(by_username, & &1.id)) == Enum.sort([direct.id, group.id])

      assert %{conversations: [by_title]} = Chat.search(scope(alice), "Expedi")
      assert by_title.id == group.id
    end

    test "your own name never matches a conversation", %{alice: alice, bob: bob} do
      {:ok, _conv} = Chat.create_conversation(scope(alice), [bob.id])
      assert %{conversations: []} = Chat.search(scope(alice), "Alice")
    end

    test "blank or single-character queries return nothing", %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      {:ok, _} = Chat.create_message(scope(bob), conv.id, %{"body" => "x marks the spot"})

      assert %{conversations: [], messages: []} = Chat.search(scope(alice), "")
      assert %{conversations: [], messages: []} = Chat.search(scope(alice), "   ")
      assert %{conversations: [], messages: []} = Chat.search(scope(alice), "x")
    end

    test "ILIKE metacharacters match literally", %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      {:ok, _} = Chat.create_message(scope(bob), conv.id, %{"body" => "discount 100% off"})
      {:ok, _} = Chat.create_message(scope(bob), conv.id, %{"body" => "underscore_name here"})
      {:ok, _} = Chat.create_message(scope(bob), conv.id, %{"body" => "plain text"})

      assert %{messages: [m]} = Chat.search(scope(alice), "100%")
      assert m.body == "discount 100% off"

      # "_" must not act as a single-char wildcard ("plain" would match "pl_in").
      assert %{messages: [u]} = Chat.search(scope(alice), "score_name")
      assert u.body == "underscore_name here"
    end

    test "deleted, hidden, and left-chat messages never match", %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      {:ok, gone} = Chat.create_message(scope(bob), conv.id, %{"body" => "needle gone"})
      {:ok, hidden} = Chat.create_message(scope(bob), conv.id, %{"body" => "needle hidden"})
      :ok = Chat.delete_message_for_both(scope(bob), gone.id)
      :ok = Chat.delete_message_for_me(scope(alice), hidden.id)

      assert %{messages: []} = Chat.search(scope(alice), "needle")

      # Leaving the chat removes its messages from search too.
      {:ok, _} = Chat.create_message(scope(bob), conv.id, %{"body" => "needle fresh"})
      :ok = Chat.delete_conversation(scope(alice), conv.id)
      assert %{messages: []} = Chat.search(scope(alice), "needle")
    end

    test "message results are capped", %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])

      for n <- 1..25 do
        {:ok, _} = Chat.create_message(scope(bob), conv.id, %{"body" => "haystack #{n}"})
      end

      assert %{messages: messages} = Chat.search(scope(alice), "haystack")
      assert length(messages) == 20
    end

    test "trigram search tolerates a typo (#56 fuzzy match)", %{alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      {:ok, msg} = Chat.create_message(scope(bob), conv.id, %{"body" => "the rendezvous point"})

      # A one-letter typo is NOT a substring, but word-similarity still finds it.
      assert %{messages: [found]} = Chat.search(scope(alice), "rendezous")
      assert found.id == msg.id

      # A short / metacharacter term stays exact-substring (no fuzzy noise).
      assert %{messages: []} = Chat.search(scope(alice), "rzv")
    end

    test "the pinned threshold matches typos the 0.6 default would miss, but not noise (#56)", %{
      alice: alice,
      bob: bob
    } do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      {:ok, doc} = Chat.create_message(scope(bob), conv.id, %{"body" => "обновили документацию"})
      {:ok, _} = Chat.create_message(scope(bob), conv.id, %{"body" => "помещение свободно"})

      # "докуметация" (dropped н) scores word_similarity ≈ 0.53 — BELOW the server
      # default 0.6, so this only matches because run_search pins the threshold to
      # 0.5. Reverting the pin would make this assertion fail: a real guard.
      assert %{messages: [found]} = Chat.search(scope(alice), "докуметация")
      assert found.id == doc.id

      # "помощь" vs "помещение" share a prefix and score ≈ 0.43 — below 0.5, so the
      # threshold rejects this unrelated-word noise (guards against over-loosening).
      assert %{messages: []} = Chat.search(scope(alice), "помощь")
    end

    test "fuzzy search never leaks across conversations (#56)", %{alice: alice, bob: bob} do
      carol = user_fixture(%{username: "carolfz"})
      # bob ↔ carol share a chat; alice is NOT a member.
      {:ok, conv} = Chat.create_conversation(scope(bob), [carol.id])
      {:ok, _} = Chat.create_message(scope(bob), conv.id, %{"body" => "the rendezvous point"})

      # The typo would match the body, but the OR fuzzy branch is still scoped by
      # membership — alice sees nothing.
      assert %{messages: []} = Chat.search(scope(alice), "rendezous")
    end

    test "a trigram GIN index backs message-body search (#56)", %{alice: alice} do
      defs =
        Eden.Repo.query!(
          "SELECT indexdef FROM pg_indexes WHERE indexname = 'messages_body_trgm_idx'"
        ).rows

      assert [[indexdef]] = defs
      assert indexdef =~ "gin"
      assert indexdef =~ "gin_trgm_ops"
      # Sanity: alice's scope still works against the indexed column.
      assert %{messages: _} = Chat.search(scope(alice), "anything")
    end
  end
end
