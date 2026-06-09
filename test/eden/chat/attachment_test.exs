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
  end
end
