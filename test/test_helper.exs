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

# Push-transport test rig (#418): throwaway keys GENERATED here (a checked-in
# private key — even a fake one — would trip gitleaks), plus Req.Test plugs so
# the APNs/FCM modules never touch the network. Written once before the suite,
# read-only after → safe under async tests.
ec_key = :public_key.generate_key({:namedCurve, :secp256r1})
ec_pem = :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, ec_key)])

Application.put_env(:eden, Eden.Notifications.APNs,
  key_p8: ec_pem,
  key_id: "TESTKEY123",
  team_id: "TESTTEAM12",
  topic: "ru.ihi.chat",
  env: :sandbox,
  req_options: [plug: {Req.Test, Eden.Notifications.APNs}]
)

rsa_key = :public_key.generate_key({:rsa, 2048, 65_537})
rsa_pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, rsa_key)])

Application.put_env(:eden, Eden.Notifications.FCM,
  service_account: %{
    "private_key" => rsa_pem,
    "client_email" => "eden-test@example.iam.gserviceaccount.com",
    "project_id" => "eden-test",
    "token_uri" => "https://oauth2.example.com/token"
  },
  req_options: [plug: {Req.Test, Eden.Notifications.FCM}]
)

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Eden.Repo, :manual)
