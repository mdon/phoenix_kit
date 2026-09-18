defmodule PhoenixKit.Integrations.CheckNotesTest do
  @moduledoc """
  What a connection check's extra text is for, and what happens to it.

  A **fact** is a standing property of the connection — the account it belongs
  to, the bot it is, a permission it lacks — so it is stored and shown with the
  connection. A **reading** is a figure at the moment of the check — a
  balance, remaining credits, a send quota — and a stored figure reads as
  current however it is stamped (Max, 2026-09-18, on the balance still showing
  $1.00 after 7½¢ of searches: *"if its displayed there (even after a refresh)
  then you would expect it to be live"*). So a reading is reported to whoever
  asked and never stored; a page that wants one asks with `reading/2`.
  """
  # async: false — registers a fixture provider, which is global state.
  use PhoenixKit.DataCase, async: false

  import PhoenixKitWeb.Components.Core.IntegrationsUI, only: [validation_note_style: 1]

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Providers
  alias PhoenixKit.ModuleRegistry

  # A provider with no connection check at all, so `reading/2` can be exercised
  # without a request leaving the test. Same shape as the fixture in
  # `integration_form_unverified_test.exs`.
  defmodule FixtureProvider do
    @moduledoc false
    def integration_providers do
      [
        %{
          key: "fixture_reading",
          name: "Fixture Reading",
          description: "Test-only provider with no connection check",
          icon: "hero-beaker",
          auth_type: :credentials,
          oauth_config: nil,
          setup_fields: [
            %{
              key: "api_secret",
              label: "API Secret",
              type: :password,
              required: true,
              placeholder: "...",
              help: nil,
              options: nil
            }
          ],
          capabilities: [],
          scopes: [:system]
        }
      ]
    end
  end

  setup do
    ModuleRegistry.register(FixtureProvider)
    Providers.clear_cache()

    on_exit(fn ->
      ModuleRegistry.unregister(FixtureProvider)
      Providers.clear_cache()
    end)

    :ok
  end

  defp connect(provider, fields) do
    {:ok, %{uuid: uuid}} = Integrations.add_connection(provider, "test")
    {:ok, _} = Integrations.save_setup(uuid, fields)
    uuid
  end

  defp stored(uuid) do
    {:ok, %{data: data}} = Integrations.get_integration_by_uuid(uuid, :system)
    data
  end

  describe "what gets stored" do
    test "a reading is not stored — the connection reads as connected, nothing more" do
      uuid = connect("dataforseo", %{"login" => "you@example.com", "password" => "secret"})

      :ok = Integrations.record_validation(uuid, {:ok, %{reading: "Balance: $1.00"}})

      data = stored(uuid)
      assert data["status"] == "connected"
      assert data["validation_status"] == "ok"
    end

    test "a fact is stored, so it stays on screen with the connection" do
      uuid = connect("telegram", %{"bot_token" => "123:abc"})

      :ok = Integrations.record_validation(uuid, {:ok, %{fact: "Connected as @toppbot"}})

      assert stored(uuid)["validation_status"] == "Connected as @toppbot"
    end

    test "a note with both keeps the fact and forgets the reading" do
      uuid = connect("serpapi", %{"api_key" => "serp-key"})

      :ok =
        Integrations.record_validation(
          uuid,
          {:ok, %{fact: "Account status: Suspended", reading: "Free Plan · searches left: 0"}}
        )

      assert stored(uuid)["validation_status"] == "Account status: Suspended"
    end

    test "a bare string is still read as a fact, as validators used to return" do
      uuid = connect("telegram", %{"bot_token" => "123:abc"})

      :ok = Integrations.record_validation(uuid, {:ok, "Something standing"})

      assert stored(uuid)["validation_status"] == "Something standing"
    end

    test "an error is still an error, and says why" do
      uuid = connect("serpapi", %{"api_key" => "wrong"})

      :ok = Integrations.record_validation(uuid, {:error, "Invalid API key"})

      data = stored(uuid)
      assert data["status"] == "error"
      assert data["validation_status"] =~ "Invalid API key"
    end
  end

  describe "note_text/1 — what a person is told after a check" do
    test "the fact and the reading, in that order" do
      assert Integrations.note_text({:ok, %{fact: "Account 1", reading: "Quota: 1/200"}}) ==
               "Account 1 · Quota: 1/200"

      assert Integrations.note_text({:ok, %{reading: "Balance: $0.92"}}) == "Balance: $0.92"
      assert Integrations.note_text({:ok, %{fact: "Connected as @bot"}}) == "Connected as @bot"
      assert Integrations.note_text({:ok, "a bare string"}) == "a bare string"
    end

    test "nothing to say is nil, not an empty dot" do
      assert Integrations.note_text({:ok, %{}}) == nil
      assert Integrations.note_text({:ok, %{fact: "", reading: nil}}) == nil
      assert Integrations.note_text(:ok) == nil
      assert Integrations.note_text({:error, "no"}) == nil
    end
  end

  # `reading/2` is `reading_of/1` applied to a fresh check, and the mapping is
  # where the figure is actually picked out — testable without a request.
  describe "reading_of/1 — the figure in a result" do
    test "a reading is the figure; a fact alone is not one" do
      assert Integrations.reading_of({:ok, %{reading: "Balance: $0.92"}}) ==
               {:ok, "Balance: $0.92"}

      assert Integrations.reading_of({:ok, %{fact: "Free Plan", reading: "Searches left: 9"}}) ==
               {:ok, "Searches left: 9"}

      assert Integrations.reading_of({:ok, %{fact: "Connected as @bot"}}) == :none
    end

    test "a check that had nothing to report has no figure" do
      assert Integrations.reading_of(:ok) == :none
      assert Integrations.reading_of({:ok, %{}}) == :none
      assert Integrations.reading_of({:ok, %{reading: ""}}) == :none
      assert Integrations.reading_of({:ok, "a bare string is a fact"}) == :none
      assert Integrations.reading_of(:unverified) == :none
    end

    test "a failure is passed through, rendered" do
      assert Integrations.reading_of({:error, "Invalid API key"}) == {:error, "Invalid API key"}
      assert {:error, message} = Integrations.reading_of({:error, :token_refresh_failed})
      assert message =~ "refresh"
    end
  end

  describe "reading/2 — asking for a current figure" do
    test "a provider with no figure to give answers :none, and stores nothing" do
      uuid = connect("fixture_reading", %{"api_secret" => "s"})
      before = stored(uuid)

      assert Integrations.reading(uuid) == :none

      # Asking is a read: the connection's own record is untouched.
      after_ask = stored(uuid)
      assert after_ask["validation_status"] == before["validation_status"]
      assert after_ask["last_validated_at"] == before["last_validated_at"]
    end

    test "a connection with no credentials is not configured" do
      {:ok, %{uuid: uuid}} = Integrations.add_connection("dataforseo", "empty")

      assert {:error, message} = Integrations.reading(uuid)
      assert message =~ "Not configured"
    end

    test "an unknown connection is not configured either" do
      assert {:error, _} = Integrations.reading(UUIDv7.generate())
    end

    test "a string that is not a uuid is an error, not a raise" do
      assert {:error, _} = Integrations.reading("not-a-uuid")
    end
  end

  describe "validation_note_style/1 — how a stored note reads" do
    test "a fact on a connected connection is information, not a warning" do
      assert {"text-base-content/70", "hero-information-circle"} =
               validation_note_style("connected")
    end

    test "an error keeps the error styling" do
      assert {"text-error", "hero-exclamation-triangle"} = validation_note_style("error")
    end

    test "anything untested is a caution" do
      for status <- ["configured", "disconnected", nil] do
        assert {"text-warning", "hero-exclamation-triangle"} = validation_note_style(status)
      end
    end
  end
end
