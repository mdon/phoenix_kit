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

  # Same space the doctor's enumeration walks, and for the same reason: no
  # reachability filter, because a reachability rule was the defect twice.
  defp signal_space do
    stores = [
      :absent,
      {:no_secret_yet, @location},
      {:unreadable, @location},
      {:shadowed, @location},
      {:holding, @location}
    ]

    for store <- stores,
        tier <- [:dedicated, :legacy, :none],
        short? <- [false, true],
        enabled? <- [true, false] do
      %{
        enabled?: enabled?,
        tier: tier,
        too_short?: short?,
        store: store,
        fingerprint: if(enabled? and tier != :none, do: {:ok, "abc123def456"}, else: :none)
      }
    end
  end

  describe "the page's own words never contradict the signals" do
    test "no diagnosis renders a banner that disagrees with the key in use" do
      for signals <- signal_space() do
        report = Encryption.key_report(signals)
        title = Page.encryption_status_title(report.diagnosis)
        detail = Page.encryption_status_detail(report.diagnosis)
        where = inspect(signals)

        assert is_binary(title) and title != "", "#{where}: no title"
        assert is_binary(detail) and detail != "", "#{where}: no detail"

        # The sentence that has now been wrong on five surfaces.
        if detail =~ "fell back" or detail =~ "weaker key" do
          assert signals.tier == :legacy, "#{where}: claims a fallback the signals deny"
        end

        # Plain text is claimed exactly where nothing is encrypting.
        if detail =~ "plain text" do
          assert not signals.enabled? or signals.tier == :none,
                 "#{where}: claims plain text while a key is in use"
        end

        # Rotation refuses while no key is active — verified against
        # `KeyRotation.rotate/2` by running it in that state.
        if (not signals.enabled? or signals.tier == :none) and detail =~ "rotate_key" do
          assert detail =~ "Do not run" or detail =~ "Do NOT run" or
                   detail =~ "cannot help",
                 "#{where}: sends an operator to a rotation that refuses"
        end
      end
    end

    test "the fingerprint label is the tier that produced the key" do
      for signals <- signal_space(), signals.fingerprint != :none do
        report = Encryption.key_report(signals)
        label = Page.fingerprint_tier(report.diagnosis)
        where = inspect(signals)

        if label =~ "FALLBACK" do
          refute signals.tier == :dedicated,
                 "#{where}: a dedicated key labelled #{inspect(label)}"
        end

        assert label =~ "dedicated" == (signals.tier == :dedicated),
               "#{where}: labelled #{inspect(label)}"
      end
    end

    # The banner is guarded on the report's severity. Guarded on the tier, the
    # one state where encryption works but its key store does not showed nothing
    # at all — and the fingerprint line beside it called that key a FALLBACK.
    test "a working key with a broken store is warned about, and not called a fallback" do
      signals = %{
        enabled?: true,
        tier: :dedicated,
        too_short?: false,
        store: {:unreadable, @location},
        fingerprint: {:ok, "abc123def456"}
      }

      report = Encryption.key_report(signals)

      assert report.severity == :warn, "the banner is guarded on severity != :ok"
      assert Page.encryption_status_title(report.diagnosis) =~ "key store"
      refute Page.fingerprint_tier(report.diagnosis) =~ "FALLBACK"
      assert Page.fingerprint_tier(report.diagnosis) =~ "dedicated"
      refute Page.encryption_status_detail(report.diagnosis) =~ "weaker"
    end
  end
end
