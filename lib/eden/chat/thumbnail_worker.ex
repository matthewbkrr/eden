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
  def perform(%Oban.Job{args: %{"attachment_id" => id}} = job) do
    case Repo.get(Attachment, id) do
      nil -> :ok
      %Attachment{thumbnail_key: key} when is_binary(key) -> :ok
      attachment -> run(attachment, job)
    end
  end

  # A raise is a failure too, and on the last attempt it is a FINAL one — Oban discards the job
  # and nothing would ever speak for the attachment again, leaving the renderer on the pending
  # placeholder forever (#532 review). Marking happens before re-raising so Oban still records
  # the error as it always did.
  defp run(attachment, job) do
    handle(Chat.generate_thumbnail(attachment), attachment, job)
  rescue
    error ->
      if last_attempt?(job), do: Chat.mark_thumbnail_failed(attachment)
      reraise error, __STACKTRACE__
  end

  defp last_attempt?(%Oban.Job{attempt: n, max_attempts: n}), do: true
  defp last_attempt?(_job), do: false

  # A broken or oversized image will never succeed, so cancel instead of burning
  # retries; storage/DB hiccups are transient, so let those retry.
  #
  # Either way, once generation is OVER the attachment is marked (#516): until then the renderer
  # cannot tell "no thumbnail yet" from "no thumbnail ever", and it showed a placeholder for
  # both. The last attempt counts as over — Oban discards after it, and nothing would speak for
  # the attachment again (#532 review).
  defp handle(:ok, _attachment, _job), do: :ok

  defp handle({:error, {:unprocessable, _} = reason}, attachment, _job) do
    Chat.mark_thumbnail_failed(attachment)
    {:cancel, reason}
  end

  defp handle({:error, reason}, attachment, job) do
    if last_attempt?(job), do: Chat.mark_thumbnail_failed(attachment)
    {:error, reason}
  end
end
