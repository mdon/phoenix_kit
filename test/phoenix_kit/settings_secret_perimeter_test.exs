defmodule PhoenixKit.SettingsSecretPerimeterTest do
  @moduledoc """
  Exercises `PhoenixKit.Test.SecretKeyPerimeter`: a static scan of core's own
  `lib/` tree and migration seeds for secret-shaped key literals, asserted
  against `restricted_setting_keys/0`. This is the guard that would have
  caught the billing-secrets gap, had the offending code lived inside core
  rather than in a separate hex package (see the scanner's own moduledoc for
  that boundary).

  No database: the scan reads files and `restricted_setting_keys/0` is a
  compile-time list, so this runs (and guards) even where Postgres is
  unreachable — `DataCase` would tag it `:integration` and skip it there.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Settings
  alias PhoenixKit.Test.SecretKeyPerimeter

  describe "core-owned secret-key perimeter guard" do
    # The real scan, against this checkout's actual lib/ tree and migrations —
    # the surface a FUTURE core-introduced secret (a new migration seed, a new
    # single-key Settings call with a literal or module-attribute
    # secret-shaped name) would have to cross. Whatever this finds today is
    # expected to already be on restricted_setting_keys/0.
    test "every secret-shaped key literal core's own source references or seeds is restricted" do
      root = File.cwd!()

      found =
        (SecretKeyPerimeter.scan_settings_literals(Path.join(root, "lib")) ++
           SecretKeyPerimeter.scan_migration_seed_literals(Path.join(root, "lib")))
        |> Enum.uniq()

      secret_shaped = Enum.filter(found, &SecretKeyPerimeter.secret_shaped?/1)

      # Sanity floor: if either of these drops out, the scan itself broke
      # (wrong root, regex stopped matching after an unrelated refactor)
      # rather than core having gotten cleaner — a scan that finds nothing
      # and a scan that works are indistinguishable without this.
      assert "aws_secret_access_key" in secret_shaped,
             "the scan should at least find aws_secret_access_key (lib/modules/storage " <>
               "reads it via a literal Settings.get_setting call) — if it did not, the " <>
               "scan itself is broken, not the classification"

      assert "website_access_password" in secret_shaped,
             "website_access_password is referenced only via the module attribute " <>
               "@password_key (PhoenixKit.WebsiteAccess.Gate) — if this is missing, " <>
               "attribute resolution in the scan broke"

      for key <- secret_shaped do
        assert key in Settings.restricted_setting_keys(),
               "#{key} looks like it carries live credential material (core's own source " <>
                 "references or seeds it) but is not on @restricted_setting_keys"
      end
    end

    # Mutation, safely: a fixture file the scanner has never seen before,
    # containing exactly the shape of gap this guard exists for (a literal,
    # single-key Settings call naming a secret-shaped key that is nowhere
    # classified) — proving the SCAN MECHANISM finds it, without touching a
    # real production file to do it.
    test "the scan is not vacuous: it finds a secret-shaped key in a planted fixture" do
      tmp_root =
        Path.join(
          System.tmp_dir!(),
          "perimeter_fixture_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_root)
      on_exit(fn -> File.rm_rf!(tmp_root) end)

      File.write!(Path.join(tmp_root, "planted_module.ex"), """
      defmodule PlantedProbe do
        def read do
          Settings.get_setting("planted_fixture_totally_secret_key", "")
        end
      end
      """)

      found = SecretKeyPerimeter.scan_settings_literals(tmp_root)

      assert "planted_fixture_totally_secret_key" in found
      assert SecretKeyPerimeter.secret_shaped?("planted_fixture_totally_secret_key")

      # And the migration-seed scanner separately, same fixture directory,
      # different shape of gap (seeded, not called).
      File.write!(Path.join(tmp_root, "fake_migration.ex"), """
      defmodule FakeMigration do
        def up do
          execute(\"\"\"
          INSERT INTO phoenix_kit_settings ("key", "module", "value", "value_json")
          VALUES ('planted_seed_secret_key', 'fixture', 'x', NULL)
          ON CONFLICT ("key") DO NOTHING
          \"\"\")
        end
      end
      """)

      seeded = SecretKeyPerimeter.scan_migration_seed_literals(tmp_root)
      assert "planted_seed_secret_key" in seeded
      assert SecretKeyPerimeter.secret_shaped?("planted_seed_secret_key")
    end

    test "resolves a setting key referenced only through a module attribute" do
      tmp_root =
        Path.join(
          System.tmp_dir!(),
          "perimeter_attr_fixture_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_root)
      on_exit(fn -> File.rm_rf!(tmp_root) end)

      File.write!(Path.join(tmp_root, "planted_attr_module.ex"), """
      defmodule PlantedAttrProbe do
        @secret_key "planted_attr_totally_secret_key"

        def read, do: Settings.get_setting(@secret_key)
      end
      """)

      found = SecretKeyPerimeter.scan_settings_literals(tmp_root)

      assert "planted_attr_totally_secret_key" in found
      assert SecretKeyPerimeter.secret_shaped?("planted_attr_totally_secret_key")
    end
  end
end
