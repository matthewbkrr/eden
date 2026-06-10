defmodule Eden.Chat.ThumbnailWorker do
  @moduledoc """
  Generates an attachment's preview off the request path: a downscaled,
  metadata-stripped thumbnail for an image, or a poster frame + duration for a
  video (see `Eden.Chat.generate_thumbnail/1`). Enqueued by
  `Eden.Chat.create_attachment_message/3` after the original is stored; runs on
  the `:media` queue. Idempotent — a missing attachment or one that already has a
  preview is a no-op, so retries are safe. A permanently unprocessable input
  (corrupt media, ffmpeg unavailable) cancels rather than burning retries.
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
      attachment -> handle(Chat.generate_thumbnail(attachment))
    end
  end

  # A broken or oversized image will never succeed, so cancel instead of burning
  # retries; storage/DB hiccups are transient, so let those retry.
  defp handle(:ok), do: :ok
  defp handle({:error, {:unprocessable, _} = reason}), do: {:cancel, reason}
  defp handle({:error, reason}), do: {:error, reason}
end
