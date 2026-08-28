defmodule PhoenixKit.Install.ConfigVerifyTest do
  @moduledoc """
  I103: `ConfigVerify` is the shared parse-then-verify-then-rollback
  primitive behind every regex-based config splice fixed this round. These
  tests exercise it directly, against plain strings and quoted ASTs, with
  no Igniter/Mix context needed.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Install.ConfigVerify, as: CV

  describe "verify/2" do
    test "accepts a candidate that parses and satisfies the semantic check" do
      assert {:ok, _} =
               CV.verify("[crontab: [{\"* * * * *\", MyApp.Worker}]]", fn ast ->
                 CV.keyword_list_satisfies?(ast, :crontab, fn list ->
                   Enum.any?(list, &CV.tuple_names_module?(&1, MyApp.Worker))
                 end)
               end)
    end

    test "rejects a candidate that does not parse — :syntax" do
      assert {:error, :syntax} = CV.verify("crontab: [", fn _ -> true end)
    end

    test "rejects a candidate that parses but fails the semantic check — :semantic" do
      assert {:error, :semantic} =
               CV.verify("[crontab: [{\"0 3 * * *\", Other.Worker}]]", fn ast ->
                 CV.keyword_list_satisfies?(ast, :crontab, fn list ->
                   Enum.any?(list, &CV.tuple_names_module?(&1, MyApp.Worker))
                 end)
               end)
    end
  end

  describe "verify_or_rollback/3" do
    test "returns {:ok, candidate} on success" do
      assert {:ok, "[a: 1]"} = CV.verify_or_rollback("[]", "[a: 1]", fn _ -> true end)
    end

    test "returns {:rolled_back, original, :syntax} on a syntax failure" do
      assert {:rolled_back, "[]", :syntax} =
               CV.verify_or_rollback("[]", "[a: 1", fn _ -> true end)
    end

    test "returns {:rolled_back, original, :semantic} on a semantic failure" do
      assert {:rolled_back, "[]", :semantic} =
               CV.verify_or_rollback("[]", "[a: 1]", fn _ -> false end)
    end
  end

  describe "ast_contains?/2" do
    test "finds a matching node anywhere in the tree" do
      ast = quote do: [a: [b: [c: 1]]]
      assert CV.ast_contains?(ast, &match?({:c, 1}, &1))
    end

    test "false when nothing matches" do
      ast = quote do: [a: 1]
      refute CV.ast_contains?(ast, &match?({:z, _}, &1))
    end
  end

  describe "tuple_elements/1" do
    test "a literal 2-tuple returns its two elements" do
      assert CV.tuple_elements({:a, :b}) == [:a, :b]
    end

    test "a 3+ tuple (quoted as {:{}, meta, elements}) returns its elements" do
      assert CV.tuple_elements({:{}, [], [:a, :b, :c]}) == [:a, :b, :c]
    end

    test "not a tuple at all returns nil" do
      assert CV.tuple_elements([:a, :b]) == nil
      assert CV.tuple_elements(:atom) == nil
    end
  end

  describe "alias_matches?/2" do
    test "a quoted __aliases__ node matching the module" do
      {:ok, ast} = Code.string_to_quoted("Oban.Plugins.Cron")
      assert CV.alias_matches?(ast, Oban.Plugins.Cron)
    end

    test "a quoted __aliases__ node NOT matching the module" do
      {:ok, ast} = Code.string_to_quoted("Oban.Plugins.Cron")
      refute CV.alias_matches?(ast, Oban.Plugins.Pruner)
    end

    test "anything that isn't an alias node" do
      refute CV.alias_matches?("Oban.Plugins.Cron", Oban.Plugins.Cron)
      refute CV.alias_matches?(42, Oban.Plugins.Cron)
    end
  end

  describe "tuple_names_module?/2" do
    test "true when the module appears anywhere among the tuple's elements" do
      {:ok, ast} = Code.string_to_quoted(~s({"* * * * *", MyApp.Workers.Nightly}))
      assert CV.tuple_names_module?(ast, MyApp.Workers.Nightly)
    end

    test "false when a different module is named" do
      {:ok, ast} = Code.string_to_quoted(~s({"* * * * *", MyApp.Workers.Nightly}))
      refute CV.tuple_names_module?(ast, MyApp.Workers.Other)
    end

    test "false when the module is nested inside a value, not a direct element" do
      # The exact shape I103's mutation B reproduced: the target module
      # buried inside an existing entry's own nested list value.
      {:ok, ast} =
        Code.string_to_quoted(
          ~s({"*/5 * * * *", MyApp.Workers.TagSweeper, args: %{tags: ["a", MyApp.Workers.Nightly]}})
        )

      refute CV.tuple_names_module?(ast, MyApp.Workers.Nightly)
    end
  end

  describe "keyword_get/2" do
    test "finds the value for an existing key" do
      assert CV.keyword_get([a: 1, b: 2], :b) == {:ok, 2}
    end

    test "nil when the key is absent" do
      assert CV.keyword_get([a: 1], :z) == nil
    end

    test "nil when not even a keyword list" do
      assert CV.keyword_get(:not_a_list, :a) == nil
    end
  end

  describe "keyword_list_satisfies?/3" do
    test "true when a matching root_key list exists anywhere and satisfies the check" do
      ast = quote do: [plugins: [{Oban.Plugins.Cron, crontab: [{"* * * * *", MyApp.Worker}]}]]

      assert CV.keyword_list_satisfies?(ast, :crontab, fn list ->
               Enum.any?(list, &CV.tuple_names_module?(&1, MyApp.Worker))
             end)
    end

    test "false when the root_key list exists but the check fails" do
      ast = quote do: [plugins: [{Oban.Plugins.Cron, crontab: [{"* * * * *", MyApp.Worker}]}]]

      refute CV.keyword_list_satisfies?(ast, :crontab, fn list ->
               Enum.any?(list, &CV.tuple_names_module?(&1, MyApp.Other))
             end)
    end

    test "false when there is no root_key list at all" do
      ast = quote do: [plugins: [Oban.Plugins.Pruner]]
      refute CV.keyword_list_satisfies?(ast, :crontab, fn _ -> true end)
    end
  end

  describe "app_config_satisfies?/5" do
    @content """
    config :some_lib, plugins: [SomeLib.Plugin]

    config :my_app, Oban,
      repo: MyApp.Repo,
      plugins: [
        {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(60)}
      ]
    """

    test "true when the target app's own block has the matching list" do
      ast = Code.string_to_quoted!(@content)

      assert CV.app_config_satisfies?(ast, "my_app", Oban, :plugins, fn list ->
               Enum.any?(list, &CV.tuple_names_module?(&1, Oban.Plugins.Lifeline))
             end)
    end

    # I103, finding 3: this is the exact defect an unscoped
    # `keyword_list_satisfies?/3` had — it is satisfied by ANY `plugins:`
    # list in the file, including a DIFFERENT application's, so a check
    # built on it would report success even though `:my_app`'s own config
    # was never touched.
    test "false when only a DIFFERENT application's config satisfies the check" do
      content = """
      config :other_app, Oban,
        plugins: [
          {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(60)}
        ]

      config :my_app, Oban,
        repo: MyApp.Repo,
        plugins: [
          {Oban.Plugins.Pruner, max_age: 60}
        ]
      """

      ast = Code.string_to_quoted!(content)

      refute CV.app_config_satisfies?(ast, "my_app", Oban, :plugins, fn list ->
               Enum.any?(list, &CV.tuple_names_module?(&1, Oban.Plugins.Lifeline))
             end)
    end

    test "false when the app matches but the configured module doesn't" do
      content = """
      config :my_app, SomeOtherLib,
        plugins: [
          {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(60)}
        ]
      """

      ast = Code.string_to_quoted!(content)

      refute CV.app_config_satisfies?(ast, "my_app", Oban, :plugins, fn list ->
               Enum.any?(list, &CV.tuple_names_module?(&1, Oban.Plugins.Lifeline))
             end)
    end

    test "accepts app_name as either an atom or a string" do
      ast = Code.string_to_quoted!(@content)

      for app_name <- [:my_app, "my_app"] do
        assert CV.app_config_satisfies?(ast, app_name, Oban, :plugins, fn list ->
                 Enum.any?(list, &CV.tuple_names_module?(&1, Oban.Plugins.Lifeline))
               end)
      end
    end

    test "does not crash on a dynamically-computed (non-atom) app argument" do
      content = """
      config Application.get_env(:parent, :app), Oban,
        plugins: [Oban.Plugins.Lifeline]
      """

      ast = Code.string_to_quoted!(content)

      refute CV.app_config_satisfies?(ast, "my_app", Oban, :plugins, fn _ -> true end)
    end
  end
end
