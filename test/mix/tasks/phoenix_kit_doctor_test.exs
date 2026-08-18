defmodule Mix.Tasks.PhoenixKit.DoctorTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.PhoenixKit.Doctor, as: DoctorTask

  # `run/1` isn't a unit-test seam (starts the app, needs a real DB) — same
  # reasoning as `Mix.Tasks.PhoenixKit.StatusTest` and
  # `Mix.Tasks.PhoenixKit.RepairTest`: exercise the pure decision the task
  # makes. Here that decision is what `--exit-code` reports to a deploy script.

  describe "exit_code/1 — only a FAIL gates the run" do
    test "all passing → 0" do
      assert DoctorTask.exit_code([
               {"Repo Detection", {:pass, "PhoenixKit.Repo"}},
               {"DB Connectivity", {:pass, "PostgreSQL 16.2"}}
             ]) == 0
    end

    test "no checks at all → 0" do
      assert DoctorTask.exit_code([]) == 0
    end

    test "any failure → 1" do
      assert DoctorTask.exit_code([
               {"Repo Detection", {:pass, "PhoenixKit.Repo"}},
               {"Module Schema Versions", {:fail, "Behind: Boards V01 (code expects V02)"}},
               {"Update Mode", {:pass, "update_mode=false"}}
             ]) == 1
    end

    test "warnings alone never fail the run" do
      # Deliberate, and the reason the flag is usable at all: several warnings
      # fire on healthy installs — a pool capped by update_mode, an
      # application.ex the child-order check could not locate. Gating on them
      # would make --exit-code permanently red, which is how a task ends up
      # back at "reports a problem and exits 0".
      assert DoctorTask.exit_code([
               {"Pool Configuration", {:warn, "pool_size=2 is very low."}},
               {"Child Start Order", {:warn, "Couldn't locate your application.ex"}},
               {"Update Mode", {:warn, "update_mode=true"}}
             ]) == 0
    end

    test "a failure mixed among warnings still fails" do
      assert DoctorTask.exit_code([
               {"Pool Configuration", {:warn, "pool_size=2 is very low."}},
               {"Schema Drift", {:fail, "3 columns missing"}},
               {"Update Mode", {:warn, "update_mode=true"}}
             ]) == 1
    end

    test "an exception inside a check is a FAIL and gates too" do
      # `run_check/2` rescues into {:fail, "Exception: ..."}, so a crashed check
      # must not be able to pass a deploy.
      assert DoctorTask.exit_code([
               {"Orphaned FK References", {:fail, "Exception: connection not available"}}
             ]) == 1
    end
  end

  defmodule ScheduledWorker do
    use Oban.Worker, queue: :scheduled_jobs

    @impl Oban.Worker
    def perform(_job), do: :ok
  end

  defmodule DefaultQueueWorker do
    # No `queue:` — Oban.Job's own "default" applies.
    use Oban.Worker

    @impl Oban.Worker
    def perform(_job), do: :ok
  end

  describe "check_cron_queues/1 — a crontab entry with no queue to run it" do
    test "warns when a crontab worker's queue is not configured" do
      # PhoenixKit's own 2025-12-28 → 1.7.63 bug, reproduced: the entry fires
      # every minute, the queue it declares is absent, so each tick inserts a
      # job that stays :available forever.
      config = [
        queues: [default: 10],
        plugins: [{Oban.Plugins.Cron, crontab: [{"* * * * *", ScheduledWorker}]}]
      ]

      assert {:warn, message} = DoctorTask.check_cron_queues(config)
      assert message =~ "ScheduledWorker"
      assert message =~ "scheduled_jobs"
    end

    test "passes once the queue is configured" do
      config = [
        queues: [default: 10, scheduled_jobs: 1],
        plugins: [{Oban.Plugins.Cron, crontab: [{"* * * * *", ScheduledWorker}]}]
      ]

      assert {:pass, _} = DoctorTask.check_cron_queues(config)
    end

    test "a worker declaring no queue is checked against 'default', not skipped" do
      assert {:warn, message} =
               DoctorTask.check_cron_queues(
                 queues: [emails: 10],
                 plugins: [{Oban.Plugins.Cron, crontab: [{"0 3 * * *", DefaultQueueWorker}]}]
               )

      assert message =~ "default"

      assert {:pass, _} =
               DoctorTask.check_cron_queues(
                 queues: [default: 10],
                 plugins: [{Oban.Plugins.Cron, crontab: [{"0 3 * * *", DefaultQueueWorker}]}]
               )
    end

    test "an entry's own queue opt overrides the worker's, as Oban resolves it" do
      # Cron merges the entry's opts over `worker.__opts__()`, so a worker
      # declaring an unconfigured queue is fine when the entry redirects it —
      # and reporting it would be a false positive.
      assert {:pass, _} =
               DoctorTask.check_cron_queues(
                 queues: [default: 10],
                 plugins: [
                   {Oban.Plugins.Cron, crontab: [{"* * * * *", ScheduledWorker, queue: :default}]}
                 ]
               )
    end

    test "queues: false is a node that runs no jobs, not a misconfiguration" do
      # Web-only and test nodes turn queues off wholesale; every entry would
      # look orphaned. Warning there is a false positive by construction.
      assert {:pass, message} =
               DoctorTask.check_cron_queues(
                 queues: false,
                 plugins: [{Oban.Plugins.Cron, crontab: [{"* * * * *", ScheduledWorker}]}]
               )

      assert message =~ "runs no queues"
    end

    test "plugins: false means there is no cron to check" do
      assert {:pass, message} =
               DoctorTask.check_cron_queues(queues: [default: 10], plugins: false)

      assert message =~ "plugins: false"
    end

    test "a module that is not an Oban worker is skipped rather than reported" do
      # A crontab can name something doctor's VM cannot load. Guessing would
      # report a healthy host as broken over a module we merely failed to
      # resolve.
      assert {:pass, _} =
               DoctorTask.check_cron_queues(
                 queues: [default: 10],
                 plugins: [{Oban.Plugins.Cron, crontab: [{"* * * * *", NoSuchWorker.Nowhere}]}]
               )
    end

    test "no Cron plugin, no crontab, and no Oban config at all are all clean" do
      assert {:pass, _} = DoctorTask.check_cron_queues(queues: [default: 10], plugins: [])
      assert {:pass, _} = DoctorTask.check_cron_queues(nil)

      assert {:pass, _} =
               DoctorTask.check_cron_queues(
                 queues: [default: 10],
                 plugins: [{Oban.Plugins.Cron, crontab: []}]
               )
    end

    test "a top-level crontab: key is checked, not just the Cron plugin" do
      # Oban still accepts `crontab:` directly on the Oban config and promotes
      # it into a Cron plugin itself (Oban.Config.crontab_to_plugin/1). Reading
      # only `plugins:` reported a clean bill of health on exactly the config
      # this check exists to catch.
      assert {:warn, message} =
               DoctorTask.check_cron_queues(
                 queues: [default: 10],
                 crontab: [{"* * * * *", ScheduledWorker}]
               )

      assert message =~ "ScheduledWorker"
    end

    test "entries from a second Cron plugin are not lost" do
      assert {:warn, message} =
               DoctorTask.check_cron_queues(
                 queues: [default: 10],
                 plugins: [
                   {Oban.Plugins.Cron, crontab: []},
                   {Oban.Plugins.Cron, crontab: [{"* * * * *", ScheduledWorker}]}
                 ]
               )

      assert message =~ "ScheduledWorker"
    end

    test "an empty queues list reads the same as queues: false" do
      # Oban's own docs: "Using an empty list or `false` prevents any queues
      # from starting on init." Treating them differently warned on one
      # spelling of a deliberate web-only node and passed the other.
      assert {:pass, message} =
               DoctorTask.check_cron_queues(
                 queues: [],
                 plugins: [{Oban.Plugins.Cron, crontab: [{"* * * * *", ScheduledWorker}]}]
               )

      assert message =~ "runs no queues"
    end

    test "testing mode is not a misconfiguration" do
      # `testing: :inline | :manual` makes Oban overwrite queues and plugins
      # with [] itself, so no cron fires and nothing can accumulate.
      for mode <- [:inline, :manual] do
        assert {:pass, message} =
                 DoctorTask.check_cron_queues(
                   testing: mode,
                   queues: [default: 10],
                   plugins: [{Oban.Plugins.Cron, crontab: [{"* * * * *", ScheduledWorker}]}]
                 )

        assert message =~ "testing mode"
      end

      # :disabled is the real default and must still be checked.
      assert {:warn, _} =
               DoctorTask.check_cron_queues(
                 testing: :disabled,
                 queues: [default: 10],
                 plugins: [{Oban.Plugins.Cron, crontab: [{"* * * * *", ScheduledWorker}]}]
               )
    end

    test "the warning says what configuring the queue will release" do
      # Draining is not free: the first sweep publishes every overdue
      # scheduled post and sends every overdue broadcast. A host that reads
      # only "add the queue" gets that as a surprise.
      assert {:warn, message} =
               DoctorTask.check_cron_queues(
                 queues: [default: 10],
                 plugins: [{Oban.Plugins.Cron, crontab: [{"* * * * *", ScheduledWorker}]}]
               )

      assert message =~ "backlog"
      assert message =~ "cancel_all_jobs"
    end

    test "every offending worker is named, not just the first" do
      assert {:warn, message} =
               DoctorTask.check_cron_queues(
                 queues: [emails: 10],
                 plugins: [
                   {Oban.Plugins.Cron,
                    crontab: [
                      {"* * * * *", ScheduledWorker},
                      {"0 3 * * *", DefaultQueueWorker}
                    ]}
                 ]
               )

      assert message =~ "ScheduledWorker"
      assert message =~ "DefaultQueueWorker"
    end
  end

  describe "integration_key_result/2 — the whole reachable signal space" do
    alias PhoenixKit.Integrations.Encryption

    @location "/srv/keys/app.key"

    # The full cross product, with NO reachability filter at all.
    #
    # Twice now a hand-written reachability rule excluded a state the code could
    # actually reach, and both times the enumeration that existed to catch such
    # a miss was the thing that hid it: the rules were reasoned out by whoever
    # reasoned out the code, so they carried the same blind spot. The second
    # time, the rule was even correct as stated ("an unreadable store cannot
    # have supplied the key in use") and still wrong to apply, because the key
    # came from config.
    #
    # There is nothing left to reason about. `Encryption.key_report/1` is total
    # over this space, and every point in it must render without contradicting
    # itself. Checking a combination that cannot occur costs one rendering and
    # removes an argument that has been wrong twice.
    defp signal_space do
      stores = [
        :absent,
        {:no_secret_yet, @location},
        {:unreadable, @location},
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

    # Every invariant below is keyed on the SIGNALS, never on the report.
    # Asserting against the report only checks that a rendering agrees with
    # itself, and a report that invents a fact agrees with itself perfectly —
    # a mutation that fabricated a fingerprint passed such a check unnoticed.
    test "no rendering contradicts the signals it was built from, anywhere in the space" do
      space = signal_space()

      # If this number moves, a signal gained a value and every assertion below
      # silently covers less than it claims.
      assert length(space) == 48

      for signals <- space, show? <- [false, true] do
        report = Encryption.key_report(signals)
        {status, detail} = DoctorTask.integration_key_result(report, show?)
        where = "#{inspect(signals)} show_fingerprint?=#{show?}"

        # A key that does not exist has no fingerprint, in EITHER flag position.
        if signals.fingerprint == :none do
          assert report.fingerprint == :none, "#{where}: report invented a fingerprint"
          refute detail =~ "Fingerprint", "#{where}: fingerprint mentioned with no key"
        else
          assert detail =~ "Fingerprint", "#{where}: key exists but no fingerprint line"
        end

        # Plaintext is claimed exactly where nothing is encrypting.
        plaintext_expected? = not signals.enabled? or signals.tier == :none

        assert String.contains?(detail, "PLAINTEXT") == plaintext_expected?,
               "#{where}: the PLAINTEXT claim does not match the signals"

        # A fallback is claimed only where the signals say one is in use. This
        # is the sentence that reappeared on five surfaces in five rounds.
        if detail =~ "fell back" or detail =~ "FALLBACK" do
          assert signals.tier == :legacy, "#{where}: claims a fallback the signals deny"
        end

        # The label on the fingerprint is the tier that produced it.
        case report.fingerprint do
          {:ok, _value, label} ->
            assert label =~ "dedicated" == (signals.tier == :dedicated),
                   "#{where}: fingerprint labelled #{inspect(label)}"

          :none ->
            :ok
        end

        # No storage line for a key stored nowhere, and no bare location that
        # reads as "saved here" when it is not.
        case signals.store do
          :absent ->
            refute detail =~ "Key store:", "#{where}: storage line with no store configured"

          {:no_secret_yet, _loc} ->
            assert detail =~ "holds no secret yet",
                   "#{where}: an empty store printed as if it held the key"

          {:unreadable, _loc} ->
            assert detail =~ "could not be read",
                   "#{where}: an unreadable store printed as if it held the key"

          {:holding, _loc} ->
            assert detail =~ "Key store:", "#{where}: store configured but not mentioned"
        end

        # Where rotation is unsafe it appears only as a prohibition.
        unless report.rotation_safe? do
          if String.contains?(detail, "phoenix_kit.integrations.rotate_key") do
            assert detail =~ "Do NOT run", "#{where}: suggests a rotation the report calls unsafe"
          end
        end

        # And `rotation_safe?` itself is checked against the signals, not
        # trusted. Keyed on the report alone, the assertion above is disabled by
        # exactly the mutation it exists to catch: flip the flag to true and the
        # bad advice sails through. `KeyRotation.rotate/2` refuses for any status
        # but :dedicated / :legacy_secret_key_base — verified by running, it
        # returns {:error, {:encryption_disabled, :disabled_no_key}} — so where
        # the signals say no key is active, no rendering may call rotation safe
        # or recommend it.
        if not signals.enabled? or signals.tier == :none do
          refute report.rotation_safe?,
                 "#{where}: rotation marked safe where the command refuses to run"

          if String.contains?(detail, "phoenix_kit.integrations.rotate_key") do
            assert detail =~ "Do NOT run",
                   "#{where}: sends an operator to a rotation that refuses while no key is active"
          end
        end

        # Severity, restated from the signals rather than read back from the
        # report — the previous version compared `status` with itself for every
        # tier but one, and asserted nothing at all for the rest.
        expected =
          cond do
            not signals.enabled? -> :warn
            signals.tier == :none -> :fail
            signals.tier == :dedicated and match?({:unreadable, _}, signals.store) -> :warn
            signals.tier == :dedicated -> :pass
            true -> :warn
          end

        assert status == expected, "#{where}: wrong severity"
      end
    end

    test "a fingerprint never appears without the tier that produced it" do
      for signals <- signal_space(), signals.fingerprint != :none do
        report = Encryption.key_report(signals)
        {_status, detail} = DoctorTask.integration_key_result(report, true)

        case report.fingerprint do
          {:ok, value, _tier} -> assert detail =~ ~r/Fingerprint #{value} \(.+\)/
          :none -> refute detail =~ "Fingerprint"
        end
      end
    end

    # The two absences the design keeps apart, because the advice is opposite.
    test "an empty store is told to fill it; an absent one is told to set one up" do
      empty =
        %{
          enabled?: true,
          tier: :none,
          too_short?: false,
          store: {:no_secret_yet, @location},
          fingerprint: :none
        }

      absent = %{empty | store: :absent}

      {_s1, filled} = DoctorTask.integration_key_result(Encryption.key_report(empty), false)
      {_s2, missing} = DoctorTask.integration_key_result(Encryption.key_report(absent), false)

      assert filled =~ "holds no secret yet"
      assert filled =~ "rotation cannot help"
      assert filled =~ @location
      assert missing =~ "Configure integrations_encryption_key"
      refute missing =~ @location
    end

    # The state the clause ORDER got wrong: a valid key in config while the
    # store is broken. Encryption is working; only the spare copy is not.
    # Reproduced against the real resolution before it was fixed, where it
    # reported the legacy tier.
    test "a configured key with a broken store is not reported as a fallback" do
      signals = %{
        enabled?: true,
        tier: :dedicated,
        too_short?: false,
        store: {:unreadable, @location},
        fingerprint: {:ok, "abc123def456"}
      }

      report = Encryption.key_report(signals)
      {status, detail} = DoctorTask.integration_key_result(report, true)

      assert report.diagnosis == {:dedicated, :store_unreadable}
      assert status == :warn
      refute detail =~ "fell back"
      refute detail =~ "FALLBACK"
      assert detail =~ "dedicated encryption key is in use"
      assert detail =~ "(dedicated key)"
      assert detail =~ @location
    end
  end
end
