defmodule Eden.Chat.Attachment do
  @moduledoc """
  A photo attached to a `Message`. Stores only the storage key + metadata (never
  the bytes or a storage implementation). `thumbnail_key` is filled in
  asynchronously by the thumbnail worker; `width`/`height` once known.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "attachments" do
    field :storage_key, :string
    field :content_type, :string
    field :byte_size, :integer
    field :width, :integer
    field :height, :integer
    field :thumbnail_key, :string

    belongs_to :message, Eden.Chat.Message

    timestamps(type: :utc_datetime)
  end

  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [:storage_key, :content_type, :byte_size, :width, :height, :thumbnail_key])
    |> validate_required([:storage_key, :content_type, :byte_size])
    |> assoc_constraint(:message)
  end
end
