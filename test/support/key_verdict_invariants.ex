defmodule PhoenixKit.Test.KeyVerdictInvariants do
  @moduledoc """
  What every key verdict must satisfy, and the real configurations that produce
  the states to check it on.

  Lives outside any one test file because the same invariants have to hold over
  two different spaces, and keeping two copies is how they drift:

    * the **synthetic** cross product — every combination of signal values,
      reachable or not. It proves the verdict is total: nothing crashes, nothing
      contradicts itself, whatever it is handed.
    * the **real** space — signal maps produced by `Encryption.key_signals/0`
      from actual `Application.put_env` configurations and actual key files.

  The second exists because the first is not evidence about the system. A
  synthetic space enumerates our idea of the states; a defect in the idea is
  invisible to it. That is not hypothetical here: the whole cross product was
  green at 60 combinations while a real configuration — a short secret in the
  key store with no `integrations_encryption_key` set — rendered advice naming a
  variable the operator does not have. The hand-built space contained a
  `{:holding, _}` store because someone wrote one down; it contained no short
  stored secret because nobody thought to.

  So the real space is the primary check, and `real ⊆ synthetic` is asserted so
  the two cannot drift apart.

  Every assertion is keyed on the SIGNALS, never on the report. Asserting a
  rendering against itself only proves it is self-consistent, and a report that
  invents a fact is perfectly self-consistent.
  """

  import ExUnit.Assertions

  alias Mix.Tasks.PhoenixKit.Doctor, as: DoctorTask
  alias PhoenixKit.Integrations.Encryption
  alias PhoenixKit.Integrations.KeyStore
  alias PhoenixKitWeb.Live.Settings.Integrations, as: Page

  @location "/srv/keys/app.key"

  @doc "Every combination of signal values, reachable or not."
  def synthetic_space do
    stores = [
      :absent,
      {:no_secret_yet, @location},
      {:unreadable, @location},
      {:shadowed, @location},
      {:holding, @location}
    ]

    for store <- stores,
        tier <- [:dedicated, :legacy, :none],
        rejected <- [false, :config, :store],
        enabled? <- [true, false] do
      %{
        enabled?: enabled?,
        tier: tier,
        rejected_key: rejected,
        store: store,
        fingerprint: if(enabled? and tier != :none, do: {:ok, "abc123def456"}, else: :none)
      }
    end
  end

  @doc """
  Drives real configurations through the real resolution and returns what it
  produced, as `{label, signals}`.

  Mutates `:phoenix_kit` application env and the key files under `dir`; the
  caller restores. Deliberately a cross product of what the resolution READS —
  the config key, the store's contents, `secret_key_base`, the enabled flag — so
  that adding a case means adding an input, not adding a state we imagined.
  """
  def real_space(dir) do
    config_keys = [
      {"no config key", nil},
      {"short config key", "short"},
      {"valid config key", valid_config()}
    ]

    stores = [
      {"no store", :none},
      {"store, file not created", :missing},
      {"store, file empty", :empty},
      {"store holding a SHORT secret", "shortsecret"},
      {"store holding another valid secret", valid_store()},
      {"store holding the config key itself", valid_config()}
    ]

    bases = [{"secret_key_base set", String.duplicate("s", 64)}, {"no secret_key_base", nil}]
    flags = [{"encryption on", true}, {"encryption off", false}]

    for {kn, key} <- config_keys,
        {sn, store} <- stores,
        {bn, base} <- bases,
        {fn_, enabled?} <- flags do
      apply_config(dir, key, store, base, enabled?)
      {"#{kn}, #{sn}, #{bn}, #{fn_}", Encryption.key_signals()}
    end
  end

  def valid_config, do: String.duplicate("k", 40)
  def valid_store, do: String.duplicate("v", 40)

  defp apply_config(dir, key, store, base, enabled?) do
    put(:integrations_encryption_key, key)
    put(:secret_key_base, base)
    put(:integration_encryption_enabled, enabled?)
    put(:parent_module, PhoenixKit.NoSuchApp)
    put(:integrations_key_store, store_config(dir, store))
    KeyStore.invalidate_cache()
    :persistent_term.erase({Encryption, :store_failure_logged})
  end

  defp store_config(_dir, :none), do: nil

  defp store_config(dir, :missing) do
    {KeyStore.File,
     path: Path.join(dir, "never-written-#{System.unique_integer([:positive])}.key")}
  end

  defp store_config(dir, :empty), do: write_store(dir, "")
  defp store_config(dir, secret), do: write_store(dir, secret)

  defp write_store(dir, contents) do
    path = Path.join(dir, "store-#{System.unique_integer([:positive])}.key")
    File.write!(path, contents)
    File.chmod!(path, 0o600)
    {KeyStore.File, path: path}
  end

  defp put(key, nil), do: Application.delete_env(:phoenix_kit, key)
  defp put(key, value), do: Application.put_env(:phoenix_kit, key, value)

  @doc "The shape of a signal map, for asserting `real ⊆ synthetic`."
  def shape(signals) do
    {signals.enabled?, signals.tier, signals.rejected_key, store_tag(signals.store),
     signals.fingerprint == :none}
  end

  def store_tag(:absent), do: :absent
  def store_tag({tag, _location}), do: tag

  @doc """
  Every invariant, against one signal map, in both fingerprint flag positions.
  """
  def assert_consistent(signals, where) do
    for show? <- [false, true], do: assert_doctor_consistent(signals, show?, where)
    assert_page_consistent(signals, where)
  end

  defp assert_doctor_consistent(signals, show?, where) do
    report = Encryption.key_report(signals)
    {status, detail} = DoctorTask.integration_key_result(report, show?)
    where = "#{where} show_fingerprint?=#{show?}"

    assert_fingerprint(signals, report, detail, where)
    assert_plaintext(signals, detail, where)
    assert_no_invented_fallback(signals, detail, where)
    assert_storage_line(signals, detail, where)
    assert_rejected_key(signals, report, detail, where)
    assert_rotation(signals, report, detail, where)
    assert_severity(signals, status, where)
  end

  # A key that does not exist has no fingerprint, in EITHER flag position.
  defp assert_fingerprint(signals, report, detail, where) do
    if signals.fingerprint == :none do
      assert report.fingerprint == :none, "#{where}: report invented a fingerprint"
      refute detail =~ "Fingerprint", "#{where}: fingerprint mentioned with no key"
    else
      assert detail =~ "Fingerprint", "#{where}: key exists but no fingerprint line"
    end

    case report.fingerprint do
      {:ok, _value, label} ->
        assert label =~ "dedicated" == (signals.tier == :dedicated),
               "#{where}: fingerprint labelled #{inspect(label)}"

      :none ->
        :ok
    end
  end

  # Plaintext is claimed exactly where nothing is encrypting.
  defp assert_plaintext(signals, detail, where) do
    expected? = not signals.enabled? or signals.tier == :none

    assert String.contains?(detail, "PLAINTEXT") == expected?,
           "#{where}: the PLAINTEXT claim does not match the signals"
  end

  # The sentence that reappeared on five surfaces in five rounds.
  defp assert_no_invented_fallback(signals, detail, where) do
    if detail =~ "fell back" or detail =~ "FALLBACK" do
      assert signals.tier == :legacy, "#{where}: claims a fallback the signals deny"
    end
  end

  # No storage line for a key stored nowhere, and no bare location that reads as
  # "saved here" when it is not.
  defp assert_storage_line(signals, detail, where) do
    case signals.store do
      :absent ->
        refute detail =~ "Key store:", "#{where}: storage line with no store configured"

      {:no_secret_yet, _loc} ->
        assert detail =~ "holds no secret yet", "#{where}: an empty store printed as holding"

      {:unreadable, _loc} ->
        assert detail =~ "could not be read", "#{where}: an unreadable store printed as holding"

      {:shadowed, _loc} ->
        assert detail =~ "DIFFERENT secret", "#{where}: another secret printed as the key"

      {:holding, _loc} ->
        assert detail =~ "Key store:", "#{where}: store configured but not mentioned"
    end
  end

  # A rejected key outranks every other fault in its tier — while it is set,
  # `dedicated_candidate/2` resolves nothing else — and the advice names WHERE it
  # is, which is a property of the resolution, not of the store's state.
  defp assert_rejected_key(signals, report, detail, where) do
    if signals.enabled? and signals.rejected_key != false and signals.tier != :dedicated do
      assert elem(report.diagnosis, 1) == :key_too_short,
             "#{where}: a rejected key outranked by #{inspect(elem(report.diagnosis, 1))}"

      assert detail =~ "rejected as shorter than", "#{where}: the rejected key is not reported"

      # Keyed on the ACTION, not on the whole rendered detail. Keyed on the
      # detail, this passed a mutation that dropped the store branch entirely:
      # the storage line prints the same path a few lines further down, so
      # "the advice names the location" was satisfied by a sentence that is not
      # the advice. An assertion resting on a coincidence elsewhere in the same
      # string is the defect this whole contract is about, in the checker.
      # Keyed on the FIELDS, one claim at a time. `detail` is every line joined,
      # and the storage line already contains the words "Key store" and the
      # path — asserting on the joined string lets a sentence that is not the
      # one under test satisfy the check, which is how an earlier version of
      # this invariant passed its own mutation.
      if signals.rejected_key == :store do
        refute report.summary =~ "IS configured",
               "#{where}: describes a store-held secret as configured in config"

        assert report.summary =~ "key store",
               "#{where}: the summary does not say where the rejected secret is"

        case report.fingerprint do
          {:ok, _value, label} ->
            assert label =~ "key store",
                   "#{where}: fingerprint labelled #{inspect(label)} for a store-held secret"

          :none ->
            :ok
        end
      end

      case {signals.rejected_key, signals.store} do
        {:store, {_state, location}} ->
          assert report.action =~ location,
                 "#{where}: the rejected secret is in the store, and the advice does not say so"

        {:config, {_state, location}} ->
          refute report.action =~ location,
                 "#{where}: the rejected key is in config, but the advice points at the store"

        {:config, :absent} ->
          assert report.action =~ "integrations_encryption_key",
                 "#{where}: the rejected key is in config, which the advice does not name"

        _degenerate ->
          :ok
      end
    end
  end

  defp assert_rotation(signals, report, detail, where) do
    unless report.rotation_safe? do
      if String.contains?(detail, "phoenix_kit.integrations.rotate_key") do
        assert detail =~ "Do NOT run", "#{where}: suggests a rotation the report calls unsafe"
      end
    end

    # `rotation_safe?` is a claim by the code under test, so it is checked
    # against the signals rather than trusted: keyed on the flag alone, the
    # assertion above is disabled by exactly the mutation it exists to catch.
    # `KeyRotation.rotate/2` refuses for any status but :dedicated /
    # :legacy_secret_key_base — verified by running.
    if not signals.enabled? or signals.tier == :none do
      refute report.rotation_safe?, "#{where}: rotation marked safe where the command refuses"

      if String.contains?(detail, "phoenix_kit.integrations.rotate_key") do
        assert detail =~ "Do NOT run", "#{where}: sends an operator to a rotation that refuses"
      end
    end
  end

  defp assert_severity(signals, status, where) do
    expected =
      cond do
        not signals.enabled? -> :warn
        signals.tier == :none -> :fail
        signals.tier == :dedicated and match?({:unreadable, _}, signals.store) -> :warn
        signals.tier == :dedicated and match?({:shadowed, _}, signals.store) -> :warn
        signals.tier == :dedicated -> :pass
        true -> :warn
      end

    assert status == expected, "#{where}: wrong severity"
  end

  # The admin page renders the same report in its own translated voice, and is
  # the surface where a wrong severity means silence rather than a wrong word:
  # its banner is guarded on `severity != :ok`.
  defp catch_all_title, do: Page.encryption_status_title({:no_such_status, :no_such_reason})
  defp catch_all_detail, do: Page.encryption_status_detail({:no_such_status, :no_such_reason})

  defp assert_page_consistent(signals, where) do
    report = Encryption.key_report(signals)
    title = Page.encryption_status_title(report)
    detail = Page.encryption_status_detail(report)
    label = Page.fingerprint_tier(report)

    assert is_binary(title) and title != "", "#{where}: page has no title"
    assert is_binary(detail) and detail != "", "#{where}: page has no detail"

    assert_page_has_a_clause(report, title, detail, where)
    assert_page_claims(signals, detail, label, where)
    assert_page_names_the_source(signals, detail, where)
  end

  # The page must have a clause for this diagnosis, not fall through to the
  # catch-all it keeps for a status it has not been taught about.
  #
  # Checking "non-empty, and free of forbidden phrases" does not hold a clause at
  # all: deleting one leaves the catch-all, which is non-empty and says nothing
  # forbidden, and every assertion still passes. Verified by destruction — both
  # new clauses removed, the page tests stayed green.
  #
  # The catch-all's own words are not written down here; they are obtained by
  # asking the page about a diagnosis that cannot exist, so this cannot drift
  # when they are reworded. Only where the banner actually renders: it is guarded
  # on `severity != :ok`, so the healthy verdict deliberately has no clause and
  # must not grow one.
  defp assert_page_has_a_clause(%{severity: :ok}, _title, _detail, _where), do: :ok

  defp assert_page_has_a_clause(report, title, detail, where) do
    assert title != catch_all_title(),
           "#{where}: no page title clause for #{inspect(report.diagnosis)} — catch-all answered"

    assert detail != catch_all_detail(),
           "#{where}: no page detail clause for #{inspect(report.diagnosis)} — catch-all answered"
  end

  defp assert_page_claims(signals, detail, label, where) do
    if detail =~ "fell back" or detail =~ "weaker key" do
      assert signals.tier == :legacy, "#{where}: page claims a fallback the signals deny"
    end

    if detail =~ "plain text" do
      assert not signals.enabled? or signals.tier == :none,
             "#{where}: page claims plain text while a key is in use"
    end

    if signals.fingerprint != :none do
      assert label =~ "dedicated" == (signals.tier == :dedicated),
             "#{where}: page labelled the fingerprint #{inspect(label)}"
    end
  end

  # Where the rejected secret lives, on the page as on every other surface. The
  # page was given only the diagnosis and still described the source, so a clause
  # written when a rejected key could only come from config went on claiming that
  # after the store could supply one — telling an operator whose short secret is
  # in the key store that repairing the store "changes nothing", which argues
  # against the only repair that works.
  defp assert_page_names_the_source(
         %{enabled?: true, rejected_key: :store, tier: tier, store: store} = signals,
         detail,
         where
       )
       when tier != :dedicated do
    report = Encryption.key_report(signals)

    refute detail =~ "changes nothing",
           "#{where}: page argues against repairing the store that holds the rejected secret"

    refute detail =~ "not consulted at all",
           "#{where}: page says the store was not consulted, and it is the source"

    # The detail clause was held; the title and the fingerprint label were not,
    # so deleting either of those was caught by nothing. Each is a single string
    # from a single call, so there is no neighbouring sentence to satisfy the
    # assertion by accident.
    assert Page.encryption_status_title(report) =~ "key store",
           "#{where}: page title does not say the rejected secret is in the store"

    assert Page.fingerprint_tier(report) =~ "key store",
           "#{where}: page labelled the fingerprint #{inspect(Page.fingerprint_tier(report))}"

    case store do
      {_state, location} ->
        assert detail =~ location,
               "#{where}: the rejected secret is in the store, which the page does not name"

      :absent ->
        :ok
    end
  end

  defp assert_page_names_the_source(_signals, _detail, _where), do: :ok
end
