defmodule Eden.Storage.S3Test do
  use ExUnit.Case, async: true

  alias Eden.Storage.{S3, SigV4}

  test "put_binary signs the request and PUTs the object" do
    test_pid = self()

    Req.Test.stub(S3, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:req, conn.method, conn.request_path, Map.new(conn.req_headers), body})
      Plug.Conn.resp(conn, 200, "")
    end)

    assert :ok = S3.put_binary("avatars/abc.jpg", "hello")

    assert_received {:req, "PUT", "/test-bucket/avatars/abc.jpg", headers, "hello"}
    assert headers["authorization"] =~ "AWS4-HMAC-SHA256 Credential=test/"
    assert headers["authorization"] =~ "SignedHeaders=host;x-amz-content-sha256;x-amz-date"
    assert headers["x-amz-content-sha256"] == SigV4.payload_hash("hello")
    assert headers["x-amz-date"] =~ ~r/^\d{8}T\d{6}Z$/
  end

  test "put/2 reads the file and PUTs its bytes" do
    test_pid = self()

    Req.Test.stub(S3, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:put, conn.method, conn.request_path, body})
      Plug.Conn.resp(conn, 200, "")
    end)

    path = Path.join(System.tmp_dir!(), "s3-#{System.unique_integer([:positive])}.bin")
    File.write!(path, "filebytes")
    on_exit(fn -> File.rm(path) end)

    assert :ok = S3.put("files/x.bin", path)
    assert_received {:put, "PUT", "/test-bucket/files/x.bin", "filebytes"}
  end

  test "surfaces a transport error as {:error, _}" do
    Req.Test.stub(S3, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
    assert {:error, _} = S3.read("avatars/x.jpg")
  end

  test "read returns the bytes on 200" do
    Req.Test.stub(S3, fn conn -> Plug.Conn.resp(conn, 200, "PNGDATA") end)
    assert {:ok, "PNGDATA"} = S3.read("avatars/x.jpg")
  end

  test "read surfaces a non-200 as an error" do
    Req.Test.stub(S3, fn conn -> Plug.Conn.resp(conn, 404, "") end)
    assert {:error, {:http, 404}} = S3.read("avatars/missing.jpg")
  end

  test "delete is idempotent — 2xx and 404 are both :ok" do
    Req.Test.stub(S3, fn conn -> Plug.Conn.resp(conn, 204, "") end)
    assert :ok = S3.delete("avatars/x.jpg")

    Req.Test.stub(S3, fn conn -> Plug.Conn.resp(conn, 404, "") end)
    assert :ok = S3.delete("avatars/missing.jpg")
  end

  test "exists? is true on 200, false on 404" do
    Req.Test.stub(S3, fn conn -> Plug.Conn.resp(conn, 200, "") end)
    assert S3.exists?("avatars/x.jpg")

    Req.Test.stub(S3, fn conn -> Plug.Conn.resp(conn, 404, "") end)
    refute S3.exists?("avatars/missing.jpg")
  end

  test "local_path is not implemented — the facade streams instead" do
    refute function_exported?(S3, :local_path, 1)
  end
end
