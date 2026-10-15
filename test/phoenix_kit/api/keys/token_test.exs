defmodule PhoenixKit.API.Keys.TokenTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.API.Keys.Token

  describe "generate/0" do
    test "builds pk_<8 lowercase hex>_<43 base64url> and a SHA-256 of the 32-byte secret" do
      {prefix, token, hash} = Token.generate()

      assert prefix =~ ~r/\A[0-9a-f]{8}\z/
      assert token =~ ~r/\Apk_[0-9a-f]{8}_[A-Za-z0-9_-]{43}\z/
      assert String.starts_with?(token, "pk_" <> prefix <> "_")
      assert byte_size(hash) == 32

      secret_text = String.replace_prefix(token, "pk_" <> prefix <> "_", "")
      secret = Base.url_decode64!(secret_text, padding: false)
      assert byte_size(secret) == 32
      assert hash == :crypto.hash(:sha256, secret)
    end

    test "two tokens differ" do
      {_, token_a, _} = Token.generate()
      {_, token_b, _} = Token.generate()
      refute token_a == token_b
    end
  end

  describe "parse/1" do
    test "returns the prefix and the hash that generate/0 produced" do
      {prefix, token, hash} = Token.generate()
      assert {:ok, ^prefix, ^hash} = Token.parse(token)
    end

    test "splits on the first two underscores, so a secret containing _ still parses" do
      # 32 bytes of 0xFF encode to 43 characters of "_" and "-" heavy text.
      secret = :binary.copy(<<0xFB, 0xFF>>, 16)
      text = Base.url_encode64(secret, padding: false)
      assert String.contains?(text, "_")

      assert {:ok, "0123abcd", hash} = Token.parse("pk_0123abcd_" <> text)
      assert hash == Token.hash(secret)
    end

    test "refuses everything that is not a canonical token" do
      {_, token, _} = Token.generate()
      secret_text = token |> String.split("_", parts: 3) |> List.last()

      bad = [
        "",
        "pk_",
        "pk__",
        "Bearer " <> token,
        "sk_" <> String.replace_prefix(token, "pk_", ""),
        "pk_0123ABCD_" <> secret_text,
        "pk_0123abc_" <> secret_text,
        "pk_0123abcdef_" <> secret_text,
        "pk_0123abcd_" <> String.slice(secret_text, 0, 42),
        "pk_0123abcd_" <> secret_text <> "A",
        "pk_0123abcd_" <> String.slice(secret_text, 0, 42) <> "!",
        token <> "\n",
        "pk_0123abcd_" <> String.duplicate("A", 300)
      ]

      for candidate <- bad do
        assert Token.parse(candidate) == :error, "accepted #{inspect(candidate)}"
      end

      assert Token.parse(nil) == :error
      assert Token.parse(123) == :error
    end

    test "refuses a secret whose last character carries non-zero padding bits" do
      # 43 base64url characters hold 258 bits; the last 2 bits must be zero.
      assert Token.parse("pk_0123abcd_" <> String.duplicate("A", 42) <> "A") |> elem(0) == :ok
      assert Token.parse("pk_0123abcd_" <> String.duplicate("A", 42) <> "B") == :error
    end
  end

  describe "prefix/1" do
    test "reads the prefix without checking the secret" do
      assert Token.prefix("pk_0123abcd_whatever") == "0123abcd"
      assert Token.prefix("pk_0123ABCD_whatever") == nil
      assert Token.prefix("Bearer x") == nil
      assert Token.prefix(nil) == nil
    end
  end

  describe "matches?/2" do
    test "is true only for equal hashes" do
      assert Token.matches?(Token.hash("a"), Token.hash("a"))
      refute Token.matches?(Token.hash("a"), Token.hash("b"))
      refute Token.matches?(Token.hash("a"), "short")
    end
  end
end
