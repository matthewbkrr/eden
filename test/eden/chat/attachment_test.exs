defmodule Eden.Chat.AttachmentTest do
  use Eden.DataCase, async: true

  alias Eden.Chat.Attachment

  defp base(attrs) do
    Map.merge(
      %{
        kind: "file",
        storage_key: "attachments/abc.bin",
        content_type: "application/pdf",
        byte_size: 10
      },
      attrs
    )
  end

  describe "changeset/2" do
    test "accepts each known kind" do
      for kind <- Attachment.kinds() do
        cs = Attachment.changeset(%Attachment{}, base(%{kind: kind}))
        assert cs.valid?, "expected #{kind} to be valid"
      end
    end

    test "requires kind, storage_key, content_type, byte_size" do
      cs = Attachment.changeset(%Attachment{}, %{})
      errors = errors_on(cs)
      assert errors[:kind]
      assert errors[:storage_key]
      assert errors[:content_type]
      assert errors[:byte_size]
    end

    test "rejects an unknown kind" do
      cs = Attachment.changeset(%Attachment{}, base(%{kind: "hologram"}))
      refute cs.valid?
      assert errors_on(cs)[:kind]
    end

    test "rejects non-positive byte_size and duration" do
      assert errors_on(Attachment.changeset(%Attachment{}, base(%{byte_size: 0})))[:byte_size]
      assert errors_on(Attachment.changeset(%Attachment{}, base(%{duration: 0})))[:duration]
    end

    test "sanitizes the filename to a safe basename" do
      cs =
        Attachment.changeset(
          %Attachment{},
          base(%{filename: "../../etc/pa\"ss\\wd\nname.pdf"})
        )

      assert get_change(cs, :filename) == "passwdname.pdf"
    end

    test "a filename that reduces to empty becomes nil" do
      cs = Attachment.changeset(%Attachment{}, base(%{filename: "  /  "}))
      assert get_change(cs, :filename) == nil
    end

    test "truncates an over-255-byte filename, preserving the extension (#373/R040)" do
      # Cyrillic is 2 bytes/char → 200 chars = 400 bytes, over the 255-byte column.
      long = String.duplicate("я", 200) <> ".docx"
      cs = Attachment.changeset(%Attachment{}, base(%{filename: long}))
      name = get_change(cs, :filename)

      assert cs.valid?
      assert byte_size(name) <= 255
      assert String.ends_with?(name, ".docx")
      # Truncated on WHOLE graphemes — never a split UTF-8 byte.
      assert String.valid?(name)
      # And it actually kept as much of the name as fit (not just the extension).
      assert String.length(name) > 100
    end

    test "leaves a short filename unchanged (#373/R040)" do
      cs = Attachment.changeset(%Attachment{}, base(%{filename: "notes.pdf"}))
      assert get_change(cs, :filename) == "notes.pdf"
    end
  end
end
