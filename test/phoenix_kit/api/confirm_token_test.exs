defmodule PhoenixKit.API.ConfirmTokenTest do
  @moduledoc """
  `PhoenixKit.API.Confirm.Token`: the code string is `ct_<uuid>_<mac>`, the MAC is keyed
  from `secret_key_base`, and nothing but an untampered code verifies.
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.API.Confirm.Token

  @secret String.duplicate("s", 64)
  @uuid "0193a5e4-0000-7000-8000-000000000001"

  test "a signed code verifies and gives back the uuid" do
    assert {:ok, token} = Token.sign(@uuid, @secret)
    assert {:ok, @uuid} = Token.verify(token, @secret)
  end

  test "the code has a fixed, URL-safe shape" do
    {:ok, token} = Token.sign(@uuid, @secret)

    assert token =~ ~r/\Act_#{@uuid}_[A-Za-z0-9_-]{32}\z/
  end

  test "the same uuid always signs to the same code" do
    assert Token.sign(@uuid, @secret) == Token.sign(@uuid, @secret)
  end

  test "a code signed with another secret does not verify" do
    {:ok, token} = Token.sign(@uuid, @secret)
    assert :error = Token.verify(token, String.duplicate("t", 64))
  end

  test "a changed MAC, a changed uuid, a cut or a padded code do not verify" do
    {:ok, token} = Token.sign(@uuid, @secret)
    other_uuid = "0193a5e4-0000-7000-8000-000000000002"

    [
      String.replace(token, ~r/.$/, fn <<c>> -> if c == ?A, do: "B", else: "A" end),
      String.replace(token, @uuid, other_uuid),
      String.slice(token, 0, String.length(token) - 1),
      token <> "A",
      "ct_" <> @uuid,
      "ct_" <> @uuid <> "_",
      "CT_" <> String.replace_prefix(token, "ct_", ""),
      "x" <> token,
      ""
    ]
    |> Enum.each(fn bad -> assert :error = Token.verify(bad, @secret), inspect(bad) end)
  end

  test "anything that is not a string does not verify and does not raise" do
    for bad <- [nil, 42, %{}, [], :ct] do
      assert :error = Token.verify(bad, @secret)
    end
  end

  test "without a secret nothing is signed and nothing verifies" do
    assert {:error, :no_secret} = Token.sign(@uuid, nil)
    assert :error = Token.verify("ct_" <> @uuid <> "_" <> String.duplicate("A", 32), nil)
  end

  test "the secret is found in the application configuration" do
    previous = Application.get_env(:phoenix_kit, :secret_key_base)
    Application.put_env(:phoenix_kit, :secret_key_base, @secret)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit, :secret_key_base, previous),
        else: Application.delete_env(:phoenix_kit, :secret_key_base)
    end)

    assert Token.secret() == @secret
    assert {:ok, token} = Token.sign(@uuid)
    assert Token.sign(@uuid, @secret) == {:ok, token}
    assert {:ok, @uuid} = Token.verify(token)
  end

  test "a secret shorter than 32 bytes is not used" do
    previous = Application.get_env(:phoenix_kit, :secret_key_base)
    Application.put_env(:phoenix_kit, :secret_key_base, "short")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit, :secret_key_base, previous),
        else: Application.delete_env(:phoenix_kit, :secret_key_base)
    end)

    refute Token.secret() == "short"
  end
end
