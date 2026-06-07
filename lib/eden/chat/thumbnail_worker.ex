defmodule Eden.Chat.ThumbnailWorker do
  @moduledoc """
  Generates a downscaled, metadata-stripped thumbnail for an attachment, off the
  request path. Enqueued by `Eden.Chat.create_photo_message/3` after the original
  is stored; runs on the `:media` queue. Idempotent — a missing attachment or one
  that already has a thumbnail is a no-op, so retries are safe.
  """
  use Oban.Worker, queue: :media, max_attempts: 3

  alias Eden.Chat
  alias Eden.Chat.Attachment
  alias Eden.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"attachment_id" => id}}) do
    case Repo.get(Attachment, id) do
      nil -> :ok
      %Attachment{thumbnail_key: key} when is_binary(key) -> :ok
      attachment -> Chat.generate_thumbnail(attachment)
    end
  end
end
