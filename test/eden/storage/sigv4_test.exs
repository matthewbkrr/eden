defmodule Eden.Storage.SigV4Test do
  use ExUnit.Case, async: true

  alias Eden.Storage.SigV4

  describe "authorization/5" do
    # AWS's published "GET Object" SigV4 example
    # (docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html).
    test "matches the AWS spec example signature" do
      empty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

      headers = %{
        "host" => "examplebucket.s3.amazonaws.com",
        "range" => "bytes=0-9",
        "x-amz-content-sha256" => empty,
        "x-amz-date" => "20130524T000000Z"
      }

      auth =
        SigV4.authorization(
          :get,
          URI.parse("https://examplebucket.s3.amazonaws.com/test.txt"),
          headers,
          empty,
          amz_date: "20130524T000000Z",
          region: "us-east-1",
          service: "s3",
          access_key_id: "AKIAIOSFODNN7EXAMPLE",
          secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
        )

      assert auth =~
               "Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request"

      assert auth =~ "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date"

      assert auth =~
               "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
    end

    test "payload_hash/1 is the lowercase hex sha256 (empty string vector)" do
      assert SigV4.payload_hash("") ==
               "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    end
  end
end
