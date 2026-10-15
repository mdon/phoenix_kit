defmodule PhoenixKit.API.CredentialRedactionTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.API.Idempotency

  test "approval storage uses the replay credential rules throughout nested JSON" do
    for key <-
          ~w(cart_token confirm_token claim_token claim_url checkout_url api_key access_token token secret) do
      value = %{"partial" => [%{"done" => 1, String.upcase(key) => "sensitive"}]}
      assert Idempotency.credential_bearing?(JSON.encode!(value))

      assert Idempotency.redact_credentials(value) ==
               %{"partial" => [%{"done" => 1, String.upcase(key) => "[REDACTED]"}]}
    end

    assert Idempotency.redact_credentials(%{
             "rows" => ["pk_secret", "https://shop.test/CHECKOUT/CLAIM/private", "ordinary"],
             "count" => 2,
             "ok" => true
           }) == %{"rows" => ["[REDACTED]", "[REDACTED]", "ordinary"], "count" => 2, "ok" => true}
  end
end
