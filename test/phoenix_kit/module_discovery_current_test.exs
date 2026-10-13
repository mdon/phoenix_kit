defmodule PhoenixKit.ModuleDiscoveryCurrentTest do
  @moduledoc """
  `ModuleDiscovery.current_external_modules/0` — the list a boot asks for three
  times in a row (`ModuleRegistry.static_children/0`, the registry's `init/1`,
  `rescan/0` from `PhoenixKit.boot/1`). It must answer like
  `discover_external_modules/0`, read the beams only when the disk changed, and
  still see a dep that appears.

  DB-free. Sync: the remembered scan and the runtime cache are global
  `:persistent_term`s, the registry is one named process, the beam-read counter
  is a global trace and `:modules` config is global.

  Scan work is measured through `:beam_lib.chunks/2` calls, not mocked. Every
  test about a change first proves the scan was remembered (a second call reads
  no beam): otherwise a test run on an unsettled disk would pass without testing
  anything.
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.ModuleDiscovery
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.TestSupport.ModuleScanFixture, as: Fixture

  @moduletag :tmp_dir

  @old {{2020, 1, 1}, {0, 0, 0}}
  @memo_key {ModuleDiscovery, :module_hash_memo}

  setup_all do
    # A fingerprint holding an mtime newer than 2 s is never remembered, and the
    # suite has just compiled: let the environment settle once (see
    # module_hash_fast_test.exs).
    Process.sleep(3_200)
    :ok
  end

  setup do
    ModuleDiscovery.clear_hash_memo()
    ModuleDiscovery.clear_cache()

    on_exit(fn ->
      ModuleDiscovery.clear_hash_memo()
      ModuleDiscovery.clear_cache()
    end)

    :ok
  end

  test "answers like discover_external_modules/0, and the second call reads no beam", %{
    tmp_dir: tmp_dir
  } do
    mod = aged_dep(tmp_dir, :current_scan_fixture_same)

    Fixture.count_beam_reads(fn reads ->
      first = ModuleDiscovery.current_external_modules()
      assert reads.() > 0, "the first call has to scan"

      assert first == ModuleDiscovery.discover_external_modules()
      assert mod in first

      after_reference = reads.()
      for _ <- 1..10, do: assert(ModuleDiscovery.current_external_modules() == first)
      assert reads.() == after_reference, "an unchanged disk must not be read again"
    end)
  end

  test "same list and order as discover_external_modules/0", %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:phoenix_kit, :modules)
    on_exit(fn -> restore_modules_config(previous) end)

    # Put on the code path out of alphabetical order, one of them holding two more
    # marked beams whose order differs bytewise (`Z` < `a`) and case-insensitively.
    zeta = aged_dep(tmp_dir, :current_scan_fixture_zeta)
    alpha = aged_dep(tmp_dir, :current_scan_fixture_alpha)
    [upper] = add_marked_beam(tmp_dir, [:current_scan_fixture_alpha], "CurrentScanFixtureAlphaZ")
    [lower] = add_marked_beam(tmp_dir, [:current_scan_fixture_alpha], "CurrentScanFixtureAlphaa")

    # Configured: one module the scan also finds, one only configured.
    Application.put_env(:phoenix_kit, :modules, [zeta, __MODULE__])

    current = ModuleDiscovery.current_external_modules()
    assert current == ModuleDiscovery.discover_external_modules()
    assert Enum.count(current, &(&1 == zeta)) == 1
    assert List.last(current) == __MODULE__

    for mod <- [zeta, alpha, upper, lower], do: assert(mod in current)
  end

  test "leaves the runtime cache warm with the same answer", %{tmp_dir: tmp_dir} do
    aged_dep(tmp_dir, :current_scan_fixture_cache)
    modules = ModuleDiscovery.current_external_modules()

    Fixture.count_beam_reads(fn reads ->
      assert ModuleDiscovery.cached_external_modules() == modules
      assert reads.() == 0
    end)
  end

  test "refills a dropped runtime cache from the remembered scan", %{tmp_dir: tmp_dir} do
    # `register/1` drops the cache; the next rescan must put it back without a scan.
    aged_dep(tmp_dir, :current_scan_fixture_refill)
    modules = ModuleDiscovery.current_external_modules()
    ModuleDiscovery.clear_cache()

    Fixture.count_beam_reads(fn reads ->
      assert ModuleDiscovery.current_external_modules() == modules
      assert ModuleDiscovery.cached_external_modules() == modules
      assert reads.() == 0
    end)
  end

  test "a dep that appears on the code path is found", %{tmp_dir: tmp_dir} do
    aged_dep(tmp_dir, :current_scan_fixture_before)
    before = remembered!()

    mod = aged_dep(tmp_dir, :current_scan_fixture_new)
    refute mod in before

    assert mod in ModuleDiscovery.current_external_modules()
  end

  test "a change to the :modules config is noticed", %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:phoenix_kit, :modules)
    on_exit(fn -> restore_modules_config(previous) end)

    aged_dep(tmp_dir, :current_scan_fixture_config)
    refute __MODULE__ in remembered!()

    Application.put_env(:phoenix_kit, :modules, [__MODULE__ | List.wrap(previous)])
    assert __MODULE__ in ModuleDiscovery.current_external_modules()
  end

  test "refresh_cache/0 always reads the disk", %{tmp_dir: tmp_dir} do
    aged_dep(tmp_dir, :current_scan_fixture_refresh)
    remembered!()

    Fixture.count_beam_reads(fn reads ->
      ModuleDiscovery.refresh_cache()
      assert reads.() > 0
    end)
  end

  test "a reordered code path is not a change, and the answer follows the new order", %{
    tmp_dir: tmp_dir
  } do
    # A dev VM reorders the code path on every recompile (the `consolidated`
    # protocols dir moves); that must not cost a rescan of every beam.
    first = aged_dep(tmp_dir, :current_scan_fixture_order_a)
    second = aged_dep(tmp_dir, :current_scan_fixture_order_b)

    # The same module in both: it is listed once, where the first dir in the
    # current order holds it.
    [shared, shared] =
      add_marked_beam(
        tmp_dir,
        [:current_scan_fixture_order_a, :current_scan_fixture_order_b],
        "CurrentScanFixtureOrderShared"
      )

    before = remembered!()
    assert before == ModuleDiscovery.discover_external_modules()
    assert index(before, first) < index(before, second)
    assert index(before, shared) < index(before, second)
    assert Enum.count(before, &(&1 == shared)) == 1

    dir = Path.join(tmp_dir, "current_scan_fixture_order_a")
    Code.delete_path(dir)
    Code.append_path(dir)

    Fixture.count_beam_reads(fn reads ->
      after_reorder = ModuleDiscovery.current_external_modules()
      ModuleDiscovery.module_hash_fast()
      assert reads.() == 0, "a reordered code path must be answered from the remembered scan"

      assert index(after_reorder, second) < index(after_reorder, first)
      assert index(after_reorder, shared) < index(after_reorder, first)
      assert Enum.sort(after_reorder) == Enum.sort(before)
    end)

    assert ModuleDiscovery.current_external_modules() ==
             ModuleDiscovery.discover_external_modules()
  end

  test "a memo of another shape is rescanned and replaced, even under a matching fingerprint",
       %{tmp_dir: tmp_dir} do
    # A live VM that hot-reloads this module can still hold what an older version
    # remembered: `{fingerprint, hash, inventory}` (module_hash_fast/0 before this
    # change), or a module list in place of the per-dir map. The fingerprint is the
    # real, current one, so only the shape check stands between it and a hit.
    aged_dep(tmp_dir, :current_scan_fixture_old_memo)
    remembered!()
    {fingerprint, hash, inventory, _by_dir} = :persistent_term.get(@memo_key)
    modules = ModuleDiscovery.discover_external_modules()

    for old <- [{fingerprint, hash, inventory}, {fingerprint, hash, inventory, modules}] do
      :persistent_term.put(@memo_key, old)

      Fixture.count_beam_reads(fn reads ->
        assert ModuleDiscovery.current_external_modules() == modules
        assert reads.() > 0, "a memo of another shape must not be trusted"
      end)

      assert {^fingerprint, ^hash, ^inventory, by_dir} = :persistent_term.get(@memo_key)
      assert is_map(by_dir)
    end
  end

  # The registry's `init/1` loads its modules through the same `load_modules/0`
  # as `rescan/0`; it runs once per VM and is not restarted here.
  test "the boot sequence reads the beams once", %{tmp_dir: tmp_dir} do
    mod = aged_dep(tmp_dir, :current_scan_fixture_boot)
    on_exit(fn -> ModuleRegistry.unregister(mod) end)

    Fixture.count_beam_reads(fn reads ->
      # PhoenixKit.Supervisor building its children: the first, cold scan.
      ModuleRegistry.static_children()
      scan_cost = reads.()
      assert scan_cost > 0

      # PhoenixKit.boot/1 right after: picks the module up without a second scan.
      assert {:ok, new_modules} = ModuleRegistry.rescan()
      assert mod in new_modules
      assert reads.() == scan_cost
    end)
  end

  test "rescan/1 honours its timeout" do
    :ok = :sys.suspend(ModuleRegistry)
    on_exit(fn -> :sys.resume(ModuleRegistry) end)

    assert {:timeout, _} = catch_exit(ModuleRegistry.rescan(50))

    :ok = :sys.resume(ModuleRegistry)
    assert {:ok, _} = ModuleRegistry.rescan(:timer.seconds(30))
  end

  # The current list, after proving it came from a remembered scan: a second call
  # reads no beam.
  defp remembered! do
    modules = ModuleDiscovery.current_external_modules()

    Fixture.count_beam_reads(fn reads ->
      assert ModuleDiscovery.current_external_modules() == modules
      assert reads.() == 0, "the scan was not remembered (is the disk settled?)"
    end)

    modules
  end

  # A fixture dep whose files and directory carry an old mtime, so the scan of it
  # is remembered (nothing on the code path is newer than 2 s).
  defp aged_dep(tmp_dir, app) do
    mod = Fixture.write_dep(tmp_dir, app)
    age!(Path.join(tmp_dir, Atom.to_string(app)))
    mod
  end

  # One more module carrying `@phoenix_kit_module true`, its beam written into each
  # of the given fixture deps. One module per dep in the result.
  defp add_marked_beam(tmp_dir, apps, name) do
    module = Module.concat([name])

    [{^module, binary}] =
      Code.compile_string("""
      defmodule #{inspect(module)} do
        Module.register_attribute(__MODULE__, :phoenix_kit_module, persist: true)
        @phoenix_kit_module true
      end
      """)

    for app <- apps do
      dir = Path.join(tmp_dir, Atom.to_string(app))
      File.write!(Path.join(dir, "#{module}.beam"), binary)
      age!(dir)
      module
    end
  end

  defp age!(dir) do
    for file <- File.ls!(dir), do: File.touch!(Path.join(dir, file), @old)
    File.touch!(dir, @old)
  end

  defp index(list, item), do: Enum.find_index(list, &(&1 == item))

  defp restore_modules_config(nil), do: Application.delete_env(:phoenix_kit, :modules)
  defp restore_modules_config(value), do: Application.put_env(:phoenix_kit, :modules, value)
end
