# Video tests (tagged :ffmpeg) shell out to ffmpeg/ffprobe; skip them where the
# binary is absent (e.g. a dev machine without it). CI installs ffmpeg and runs them.
unless System.find_executable("ffmpeg") && System.find_executable("ffprobe") do
  ExUnit.configure(exclude: [:ffmpeg])
  IO.puts("[test] ffmpeg/ffprobe not found — excluding :ffmpeg-tagged tests")
end

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Eden.Repo, :manual)
