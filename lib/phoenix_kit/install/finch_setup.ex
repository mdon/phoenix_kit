defmodule PhoenixKit.Install.FinchSetup do
  @moduledoc """
  Handles automatic Finch and HTTP client setup for PhoenixKit installation.

  This module provides functionality to:
  - Detect if HTTP client adapters (like AmazonSES, SendGrid, etc.) are being used
  - Automatically add Finch to the application supervisor when needed
  - Add required dependencies like gen_smtp for AWS SES
  - Configure Swoosh API client appropriately
  """

  alias Igniter.Project.{Application, Config, Deps}

  @doc """
  Automatically configures Finch and dependencies based on mailer adapter configuration.

  This function checks if any HTTP-based email adapters are configured and:
  - Adds Finch to the application supervisor
  - Adds gen_smtp dependency for AWS SES
  - Configures Swoosh API client

  ## Parameters
  - `igniter` - The igniter context

  ## Returns
  Updated igniter with Finch configuration if needed.
  """
  def add_finch_configuration(igniter) do
    igniter
    |> maybe_add_finch_supervisor()
    |> maybe_add_gen_smtp_dependency()
    |> add_swoosh_api_client_config()
  end

  # Check if HTTP-based email adapters are being used and add Finch to supervisor
  defp maybe_add_finch_supervisor(igniter) do
    if needs_finch?(igniter) do
      Application.add_new_child(
        igniter,
        {Finch, name: Swoosh.Finch},
        opts: [after: [:telemetry_supervisor, :pubsub]]
      )
    else
      igniter
    end
  end

  # Check if AWS SES is being used and add gen_smtp dependency
  defp maybe_add_gen_smtp_dependency(igniter) do
    if needs_gen_smtp?(igniter) do
      Deps.add_dep(igniter, {:gen_smtp, "~> 1.2"})
    else
      igniter
    end
  end

  # Configure Swoosh API client to use Finch
  defp add_swoosh_api_client_config(igniter) do
    if needs_finch?(igniter) do
      Config.configure_new(
        igniter,
        "config.exs",
        :swoosh,
        [:api_client],
        Swoosh.ApiClient.Finch
      )
    else
      # Disable API client for local adapters
      Config.configure_new(
        igniter,
        "dev.exs",
        :swoosh,
        [:api_client],
        false
      )
    end
  end

  # Check if any HTTP-based email adapters are configured
  defp needs_finch?(igniter) do
    http_adapters = [
      "Swoosh.Adapters.AmazonSES",
      "Swoosh.Adapters.Sendgrid",
      "Swoosh.Adapters.Mailgun",
      "Swoosh.Adapters.Postmark",
      "Swoosh.Adapters.Mandrill"
    ]

    check_config_for_adapters(igniter, http_adapters)
  end

  # Check if AWS SES is being used (needs gen_smtp)
  defp needs_gen_smtp?(igniter) do
    check_config_for_adapters(igniter, ["Swoosh.Adapters.AmazonSES"])
  end

  # Helper to check if any of the specified adapters are configured
  defp check_config_for_adapters(igniter, adapters) do
    config_files = ["config.exs", "dev.exs", "prod.exs"]

    Enum.any?(config_files, fn file ->
      case igniter.rewrite.sources[file] do
        nil ->
          false

        source ->
          content = Rewrite.Source.get(source, :content)
          Enum.any?(adapters, &String.contains?(content, &1))
      end
    end)
  end
end
