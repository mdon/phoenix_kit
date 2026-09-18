defmodule PhoenixKit.Application do
  @moduledoc """
  OTP Application module for PhoenixKit.

  `PhoenixKit.Supervisor` is started by the parent application, not here.
  This callback still runs on boot: it warms the Gettext catalogue into
  `:persistent_term` so the first translation does not pay the decode.
  """
  use Application

  require Logger

  alias PhoenixKit.Modules.Storage.ApplyImageEditJob
  alias PhoenixKit.Modules.Storage.Providers.Local

  @impl true
  def start(_type, _args) do
    check_installation()
    Local.remember_start_dir()
    ApplyImageEditJob.attach_telemetry()
    PhoenixKitWeb.Gettext.warm_catalog()

    # PhoenixKit.Supervisor is started by the parent app in its tree.
    Supervisor.start_link([], strategy: :one_for_one, name: PhoenixKit.AppSupervisor)
  end

  defp check_installation do
    unless PhoenixKit.configured?() do
      Logger.warning("""
      PhoenixKit is added as a dependency but not installed.
      Run: mix phoenix_kit.install
      See: https://phoenix-kit.hexdocs.pm
      """)
    end
  end
end
