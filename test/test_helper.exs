# Some tests shell out to external media tools; skip them where the binary is absent
# (e.g. a dev machine without it). CI installs them and runs them. Build the exclude
# list once — calling ExUnit.configure(exclude:) twice would overwrite, not merge.
#   :ffmpeg — video poster/duration (ffmpeg/ffprobe)
#   :heif   — HEIC → JPEG transcode (heif-convert / libheif, #123)
media_excludes =
  [
    {:ffmpeg, System.find_executable("ffmpeg") && System.find_executable("ffprobe")},
    {:heif, System.find_executable("heif-convert")}
  ]
  |> Enum.reject(fn {_tag, present?} -> present? end)
  |> Enum.map(fn {tag, _} -> tag end)

if media_excludes != [] do
  ExUnit.configure(exclude: media_excludes)
  IO.puts("[test] missing media tools — excluding tags: #{inspect(media_excludes)}")
end

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Eden.Repo, :manual)
