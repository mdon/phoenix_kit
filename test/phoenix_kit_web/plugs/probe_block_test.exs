defmodule PhoenixKitWeb.Plugs.ProbeBlockTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias PhoenixKitWeb.Plugs.ProbeBlock

  defp run(path, opts \\ []) do
    conn(:get, path) |> ProbeBlock.call(ProbeBlock.init(opts))
  end

  test "scanner probes get an empty 404 and halt" do
    for path <-
          ~w(/.env /.env.production /.git/config /config/.git/HEAD /wp-login.php
             /wp-admin/setup.php /blog/wp-content/x /xmlrpc.php /index.php
             /phpmyadmin/ /cgi-bin/luci /vendor/phpunit/src/Util/PHP/eval-stdin.php
             /actuator/health /server-status /.DS_Store) do
      conn = run(path)
      assert conn.halted, path
      assert conn.status == 404, path
      assert conn.resp_body == ""
    end
  end

  test "real pages and /.well-known pass through" do
    for path <-
          ~w(/ /admin /en/blog/my-post /users/log-in /assets/app.js /phoenix_kit/admin/settings
             /.well-known/acme-challenge/abc /.well-known/security.txt /wordpress-migration-guide
             /docs/wp-administer /blog/wp-contentious-topics) do
      conn = run(path)
      refute conn.halted, path
      assert conn.status == nil
    end
  end

  test "extra adds patterns and except lets a default through" do
    assert run("/old-admin/login", extra: ["/old-admin"]).halted
    assert run("/secret", extra: [~r{^/secret}]).halted
    refute run("/legacy/report.php", except: [~r{^/legacy/}]).halted
  end

  test "status can be changed" do
    assert run("/.env", status: 410).status == 410
  end

  test "init/1's result can be embedded in compiled code (endpoint plugs are initialised at compile time)" do
    opts = ProbeBlock.init(extra: [~r{^/secret}i, "/old-admin"], except: [~r{\.php$}])
    assert Macro.escape(opts)
  end
end
