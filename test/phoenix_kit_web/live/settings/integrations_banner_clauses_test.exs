# NOT `…IntegrationsEncryptionBannerTest` — that name is already taken by the
# integration test at test/integration/phoenix_kit_web/live/settings/, and a
# second module of the same name silently redefines the first. This one is the
# unit-level companion: it walks the page's clause heads over the whole signal
# space without a database.
defmodule PhoenixKitWeb.Live.Settings.IntegrationsBannerClausesTest do
  # The admin page is the fourth surface that describes the key state, and the
  # one that kept being left behind: the boot log, the mix task and
  # `Encryption.key_report/1` were each corrected in turn while this page went
  # on saying the old thing. Round 5 introduced `{:dedicated, :store_unreadable}`
  # and fixed three surfaces for it; here, a working dedicated key was still
  # labelled a FALLBACK, under a banner that did not render at all because the
  # guard was `status != :dedicated`.
  #
  # Its clause heads are public seams for the same reason
  # `Mix.Tasks.PhoenixKit.Doctor.integration_key_result/2` is one: the defect
  # lives in the rendering, and a test that cannot reach the rendering cannot
  # guard it.
  use ExUnit.Case, async: true

  alias PhoenixKit.Integrations.Encryption
  alias PhoenixKitWeb.Live.Settings.Integrations, as: Page

  @location "/srv/keys/app.key"

  # The page's clause heads are walked over the whole signal space by
  # `PhoenixKit.Test.KeyVerdictInvariants.assert_consistent/2`, which both the
  # synthetic and the real enumerations call — the page is a surface of the same
  # verdict, and checking it separately is how it fell a round behind twice.
  #
  # What stays here is the pair of states that reached three surfaces out of
  # four before anyone noticed, asserted directly rather than as one point in a
  # sweep.
  describe "the states the page kept being told about last" do
    # The banner is guarded on the report's severity. Guarded on the tier, the
    # one state where encryption works but its key store does not showed nothing
    # at all — and the fingerprint line beside it called that key a FALLBACK.
    test "a working key with a broken store is warned about, and not called a fallback" do
      signals = %{
        enabled?: true,
        tier: :dedicated,
        rejected_key: false,
        store: {:unreadable, @location},
        fingerprint: {:ok, "abc123def456"}
      }

      report = Encryption.key_report(signals)

      assert report.severity == :warn, "the banner is guarded on severity != :ok"
      assert Page.encryption_status_title(report) =~ "key store"
      refute Page.fingerprint_tier(report) =~ "FALLBACK"
      assert Page.fingerprint_tier(report) =~ "dedicated"
      refute Page.encryption_status_detail(report) =~ "weaker"
    end

    # P012's state, on the surface where `:ok` meant silence: a working key with
    # a key store that holds something else.
    test "a store holding a different secret is warned about, and not called a backup" do
      signals = %{
        enabled?: true,
        tier: :dedicated,
        rejected_key: false,
        store: {:shadowed, @location},
        fingerprint: {:ok, "abc123def456"}
      }

      report = Encryption.key_report(signals)

      assert report.severity == :warn, "at :ok the page renders no banner at all"
      assert Page.encryption_status_title(report) =~ "different secret"
      assert Page.encryption_status_detail(report) =~ "not a copy"
      assert Page.fingerprint_tier(report) =~ "dedicated"
      refute Page.fingerprint_tier(report) =~ "FALLBACK"
    end
  end
end
