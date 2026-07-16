defmodule Eden.Chat.Attachment do
  @moduledoc """
  A file attached to a `Message`. Stores only the storage key + metadata (never
  the bytes or a storage implementation).

  `kind` classifies the attachment (`image | video | file`) and decides how it
  renders and is served. Per-kind metadata: `width`/`height` (image, video),
  `duration` in milliseconds (video), `filename` (the sanitized original name,
  shown and used for file downloads). `thumbnail_key` holds the image thumbnail
  or video poster, filled in asynchronously by the media worker.

  Audio is deliberately NOT a first-class kind yet (#373): `Eden.Chat.sniff/2`
  never classifies a file as "audio", so an audio-in-ISO file (m4a) is stored and
  served as a downloadable "file". Reviving audio means adding sniff signatures +
  an inline player.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(image video file)

  schema "attachments" do
    field :kind, :string
    field :storage_key, :string
    field :content_type, :string
    field :byte_size, :integer
    field :filename, :string
    field :width, :integer
    field :height, :integer
    field :duration, :integer
    field :thumbnail_key, :string
    # Order within an album (#58); 0 for a lone attachment.
    field :position, :integer, default: 0
    # "Send as file" (#122): an uncompressed image rendered as a downloadable document
    # (with a thumbnail) rather than an inline photo.
    field :as_file, :boolean, default: false

    belongs_to :message, Eden.Chat.Message

    timestamps(type: :utc_datetime)
  end

  @doc "The recognized attachment kinds."
  def kinds, do: @kinds

  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [
      :kind,
      :storage_key,
      :content_type,
      :byte_size,
      :filename,
      :width,
      :height,
      :duration,
      :thumbnail_key,
      :position,
      :as_file
    ])
    |> validate_required([:kind, :storage_key, :content_type, :byte_size])
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:byte_size, greater_than: 0)
    |> validate_number(:duration, greater_than: 0)
    |> update_change(:filename, &sanitize_filename/1)
    |> validate_length(:filename, max: 255, count: :bytes)
    |> assoc_constraint(:message)
  end

  # Reduce a client-supplied name to a safe basename: strip any path component and
  # drop control chars (incl. NUL, CR, LF — which would also break a
  # Content-Disposition header), quotes and backslashes. Empty result becomes nil.
  defp sanitize_filename(nil), do: nil

  defp sanitize_filename(name) when is_binary(name) do
    name
    |> Path.basename()
    |> String.replace(~r/[\x00-\x1f"\\\/]/u, "")
    |> String.trim()
    |> case do
      "" -> nil
      cleaned -> truncate_to_bytes(cleaned, 255)
    end
  end

  # Truncate to `max` BYTES without splitting a UTF-8 grapheme, preserving the extension. A long
  # meaningful name (Cyrillic is 2 bytes/char, so ~127 chars already hit the 255-byte column) is
  # TRUNCATED, not rejected — the name isn't content, so cutting it beats failing the whole send
  # with a generic error (#373/R040), matching Telegram / mail clients. The `validate_length`
  # safety net in the changeset then always passes.
  defp truncate_to_bytes(name, max) when byte_size(name) <= max, do: name

  defp truncate_to_bytes(name, max) do
    ext = Path.extname(name)

    # A pathological extension that alone blows the budget → truncate the whole name.
    if byte_size(ext) >= max do
      take_bytes(name, max)
    else
      take_bytes(Path.rootname(name), max - byte_size(ext)) <> ext
    end
  end

  # The longest leading run of whole graphemes whose byte size stays within `max`.
  defp take_bytes(str, max) do
    str
    |> String.graphemes()
    |> Enum.reduce_while({"", 0}, fn g, {acc, size} ->
      next = size + byte_size(g)
      if next <= max, do: {:cont, {acc <> g, next}}, else: {:halt, {acc, size}}
    end)
    |> elem(0)
  end
end
