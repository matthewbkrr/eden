defmodule Eden.Chat.Attachment do
  @moduledoc """
  A file attached to a `Message`. Stores only the storage key + metadata (never
  the bytes or a storage implementation).

  `kind` classifies the attachment (`image | video | file | audio`) and decides
  how it renders and is served. Per-kind metadata: `width`/`height` (image,
  video), `duration` in milliseconds (video, audio), `filename` (the sanitized
  original name, shown and used for file downloads). `thumbnail_key` holds the
  image thumbnail or video poster, filled in asynchronously by the media worker.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(image video file audio)

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
      :position
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
      cleaned -> cleaned
    end
  end
end
