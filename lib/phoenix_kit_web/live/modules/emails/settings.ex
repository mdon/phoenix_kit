defmodule PhoenixKitWeb.Live.Modules.Emails.Settings do
  @moduledoc """
  LiveView for email system configuration and settings management.

  This module provides a comprehensive interface for managing all aspects
  of the PhoenixKit email system, including:

  - **System Control**: Enable/disable the entire email system
  - **Storage Settings**: Configure email body and header storage
  - **AWS SES Integration**: Manage SES event tracking and configuration
  - **Data Management**: Set retention periods and sampling rates
  - **Advanced Features**: Configure compression and S3 archival
  - **SQS Configuration**: Control SQS polling and message processing

  ## Route

  This LiveView is mounted at `{prefix}/admin/settings/emails` and requires
  appropriate admin permissions.

  Note: `{prefix}` is your configured PhoenixKit URL prefix (default: `/phoenix_kit`).

  ## Features

  - Real-time settings updates with immediate effect
  - AWS infrastructure configuration (SES, SNS, SQS)
  - Data lifecycle management (retention, compression, archival)
  - Performance tuning (sampling rate, polling intervals)
  - Validation with user-friendly error messages

  ## Permissions

  Access is restricted to users with admin or owner roles in PhoenixKit.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.AWS.InfrastructureSetup
  alias PhoenixKit.Emails
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @dialyzer {:nowarn_function, handle_event: 3}

  def mount(_params, session, socket) do
    # Get current path for navigation
    current_path = get_current_path(socket, session)

    # Get project title from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    # Load email configuration
    email_config = Emails.get_config()

    # Load AWS settings
    aws_settings = %{
      access_key_id: Settings.get_setting("aws_access_key_id", ""),
      secret_access_key: Settings.get_setting("aws_secret_access_key", ""),
      region: Settings.get_setting("aws_region", "eu-north-1"),
      sqs_queue_url: Settings.get_setting("aws_sqs_queue_url", ""),
      sqs_dlq_url: Settings.get_setting("aws_sqs_dlq_url", ""),
      sqs_queue_arn: Settings.get_setting("aws_sqs_queue_arn", ""),
      sns_topic_arn: Settings.get_setting("aws_sns_topic_arn", ""),
      ses_configuration_set:
        Settings.get_setting("aws_ses_configuration_set", "phoenixkit-tracking"),
      sqs_polling_interval_ms: Settings.get_setting("sqs_polling_interval_ms", "5000")
    }

    socket =
      socket
      |> assign(:current_path, current_path)
      |> assign(:page_title, "Emails")
      |> assign(:project_title, project_title)
      |> assign(:email_enabled, email_config.enabled)
      |> assign(:email_save_body, email_config.save_body)
      |> assign(:email_save_headers, Emails.save_headers_enabled?())
      |> assign(:email_ses_events, email_config.ses_events)
      |> assign(:email_retention_days, email_config.retention_days)
      |> assign(:email_sampling_rate, email_config.sampling_rate)
      |> assign(:email_compress_body, email_config.compress_after_days)
      |> assign(:email_archive_to_s3, email_config.archive_to_s3)
      |> assign(:sqs_polling_enabled, email_config.sqs_polling_enabled)
      |> assign(:sqs_polling_interval_ms, email_config.sqs_polling_interval_ms)
      |> assign(:sqs_max_messages_per_poll, email_config.sqs_max_messages_per_poll)
      |> assign(:sqs_visibility_timeout, email_config.sqs_visibility_timeout)
      |> assign(:aws_settings, aws_settings)
      |> assign(:saving, false)
      |> assign(:setting_up_aws, false)

    {:ok, socket}
  end

  def handle_event("toggle_emails", _params, socket) do
    # Toggle email system
    new_enabled = !socket.assigns.email_enabled

    result =
      if new_enabled do
        Emails.enable_system()
      else
        Emails.disable_system()
      end

    case result do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:email_enabled, new_enabled)
          |> put_flash(
            :info,
            if(new_enabled,
              do: "Email system enabled",
              else: "Email system disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update email system")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_email_save_body", _params, socket) do
    # Toggle email body saving
    new_save_body = !socket.assigns.email_save_body

    result = Emails.set_save_body(new_save_body)

    case result do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:email_save_body, new_save_body)
          |> put_flash(
            :info,
            if(new_save_body,
              do: "Email body saving enabled",
              else: "Email body saving disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update email body saving setting")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_email_save_headers", _params, socket) do
    # Toggle email headers saving
    new_save_headers = !socket.assigns.email_save_headers

    result = Emails.set_save_headers(new_save_headers)

    case result do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:email_save_headers, new_save_headers)
          |> put_flash(
            :info,
            if(new_save_headers,
              do: "Email headers saving enabled",
              else: "Email headers saving disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update email headers saving setting")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_email_ses_events", _params, socket) do
    # Toggle AWS SES events tracking
    new_ses_events = !socket.assigns.email_ses_events

    result = Emails.set_ses_events(new_ses_events)

    case result do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:email_ses_events, new_ses_events)
          |> put_flash(
            :info,
            if(new_ses_events,
              do: "AWS SES events tracking enabled",
              else: "AWS SES events tracking disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update AWS SES events tracking")
        {:noreply, socket}
    end
  end

  def handle_event("update_email_sampling_rate", %{"sampling_rate" => value}, socket) do
    case Integer.parse(value) do
      {sampling_rate, _} when sampling_rate >= 0 and sampling_rate <= 100 ->
        case Emails.set_sampling_rate(sampling_rate) do
          {:ok, _setting} ->
            socket =
              socket
              |> assign(:email_sampling_rate, sampling_rate)
              |> put_flash(:info, "Email sampling rate updated to #{sampling_rate}%")

            {:noreply, socket}

          {:error, _changeset} ->
            socket = put_flash(socket, :error, "Failed to update email sampling rate")
            {:noreply, socket}
        end

      _ ->
        socket = put_flash(socket, :error, "Please enter a valid number between 0 and 100")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_sqs_polling", _params, socket) do
    # Toggle SQS polling
    new_sqs_polling = !socket.assigns.sqs_polling_enabled

    result = Emails.set_sqs_polling(new_sqs_polling)

    case result do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:sqs_polling_enabled, new_sqs_polling)
          |> put_flash(
            :info,
            if(new_sqs_polling,
              do: "SQS polling enabled",
              else: "SQS polling disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update SQS polling setting")
        {:noreply, socket}
    end
  end

  def handle_event("update_email_retention", %{"retention_days" => value}, socket) do
    case Integer.parse(value) do
      {retention_days, _} when retention_days > 0 and retention_days <= 365 ->
        case Emails.set_retention_days(retention_days) do
          {:ok, _setting} ->
            socket =
              socket
              |> assign(:email_retention_days, retention_days)
              |> put_flash(:info, "Email retention period updated to #{retention_days} days")

            {:noreply, socket}

          {:error, _changeset} ->
            socket = put_flash(socket, :error, "Failed to update email retention period")
            {:noreply, socket}
        end

      _ ->
        socket = put_flash(socket, :error, "Please enter a valid number between 1 and 365")
        {:noreply, socket}
    end
  end

  def handle_event("update_compress_days", %{"compress_days" => value}, socket) do
    case Integer.parse(value) do
      {compress_days, _} when compress_days >= 7 and compress_days <= 365 ->
        case Emails.set_compress_after_days(compress_days) do
          {:ok, _setting} ->
            socket =
              socket
              |> assign(:email_compress_body, compress_days)
              |> put_flash(:info, "Email body compression updated to #{compress_days} days")

            {:noreply, socket}

          {:error, _changeset} ->
            socket = put_flash(socket, :error, "Failed to update compression days")
            {:noreply, socket}
        end

      _ ->
        socket = put_flash(socket, :error, "Please enter a valid number between 7 and 365")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_s3_archival", _params, socket) do
    new_s3_archival = !socket.assigns.email_archive_to_s3

    result = Emails.set_s3_archival(new_s3_archival)

    case result do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:email_archive_to_s3, new_s3_archival)
          |> put_flash(
            :info,
            if(new_s3_archival,
              do: "S3 archival enabled",
              else: "S3 archival disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update S3 archival setting")
        {:noreply, socket}
    end
  end

  def handle_event("update_max_messages", %{"max_messages" => value}, socket) do
    case Integer.parse(value) do
      {max_messages, _} when max_messages >= 1 and max_messages <= 10 ->
        case Emails.set_sqs_max_messages(max_messages) do
          {:ok, _setting} ->
            socket =
              socket
              |> assign(:sqs_max_messages_per_poll, max_messages)
              |> put_flash(:info, "SQS max messages updated to #{max_messages}")

            {:noreply, socket}

          {:error, _changeset} ->
            socket = put_flash(socket, :error, "Failed to update SQS max messages")
            {:noreply, socket}
        end

      _ ->
        socket = put_flash(socket, :error, "Please enter a valid number between 1 and 10")
        {:noreply, socket}
    end
  end

  def handle_event("update_visibility_timeout", %{"timeout" => value}, socket) do
    case Integer.parse(value) do
      {timeout, _} when timeout >= 30 and timeout <= 43_200 ->
        case Emails.set_sqs_visibility_timeout(timeout) do
          {:ok, _setting} ->
            socket =
              socket
              |> assign(:sqs_visibility_timeout, timeout)
              |> put_flash(:info, "SQS visibility timeout updated to #{timeout} seconds")

            {:noreply, socket}

          {:error, _changeset} ->
            socket = put_flash(socket, :error, "Failed to update SQS visibility timeout")
            {:noreply, socket}
        end

      _ ->
        socket =
          put_flash(socket, :error, "Please enter a valid number between 30 and 43200 seconds")

        {:noreply, socket}
    end
  end

  def handle_event("setup_aws_infrastructure", _params, socket) do
    # Start AWS infrastructure setup process
    socket = assign(socket, :setting_up_aws, true)

    # Get project name from settings
    project_name =
      Settings.get_setting("project_title", "myapp")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9-]/, "-")
      |> String.trim("-")

    # Get AWS credentials from current settings
    aws_config = socket.assigns.aws_settings
    region = aws_config.region || "eu-north-1"

    # Check if credentials are configured
    access_key_id =
      if aws_config.access_key_id != "", do: aws_config.access_key_id, else: nil

    secret_access_key =
      if aws_config.secret_access_key != "", do: aws_config.secret_access_key, else: nil

    if access_key_id && secret_access_key do
      # Run AWS infrastructure setup
      case InfrastructureSetup.run(
             project_name: project_name,
             region: region,
             access_key_id: access_key_id,
             secret_access_key: secret_access_key
           ) do
        {:ok, config} ->
          # Update settings with created infrastructure details
          case Settings.update_settings_batch(config) do
            {:ok, _results} ->
              # Reload AWS settings
              new_aws_settings = %{
                access_key_id: access_key_id,
                secret_access_key: secret_access_key,
                region: config["aws_region"],
                sqs_queue_url: config["aws_sqs_queue_url"],
                sqs_dlq_url: config["aws_sqs_dlq_url"],
                sqs_queue_arn: config["aws_sqs_queue_arn"],
                sns_topic_arn: config["aws_sns_topic_arn"],
                ses_configuration_set: config["aws_ses_configuration_set"],
                sqs_polling_interval_ms: config["sqs_polling_interval_ms"]
              }

              socket =
                socket
                |> assign(:aws_settings, new_aws_settings)
                |> assign(:setting_up_aws, false)
                |> put_flash(:info, """
                ✅ AWS Email Infrastructure Created Successfully!

                📦 Created Resources:
                • Project: #{project_name}
                • Region: #{config["aws_region"]}
                • SNS Topic: #{config["aws_sns_topic_arn"]}
                • SQS Queue: #{config["aws_sqs_queue_url"]}
                • Dead Letter Queue: #{config["aws_sqs_dlq_url"]}
                • SES Configuration Set: #{config["aws_ses_configuration_set"]}

                🎉 All settings have been automatically filled below.
                Click "Save AWS Settings" to persist the configuration.

                ⚡ Next steps:
                1. Verify your email/domain in AWS SES Console
                2. Enable SQS Polling below
                3. Start sending emails!
                """)

              {:noreply, socket}

            {:error, _failed_operation, _failed_value, _changes} ->
              socket =
                socket
                |> assign(:setting_up_aws, false)
                |> put_flash(:error, """
                ⚠️ Infrastructure created but failed to save settings.

                AWS resources were created successfully, but there was an error saving configuration to database.
                Please save AWS settings manually.
                """)

              {:noreply, socket}
          end

        {:error, step, reason} ->
          socket =
            socket
            |> assign(:setting_up_aws, false)
            |> put_flash(:error, """
            ❌ AWS Setup Failed

            Failed at step: #{step}
            Reason: #{reason}

            Please check:
            • AWS credentials are valid
            • IAM permissions (SQS, SNS, SES, STS)
            • AWS region is correct
            • No resource limits exceeded

            You can also use the manual bash script:
            ./scripts/setup_aws_email_infrastructure.sh
            """)

          {:noreply, socket}
      end
    else
      socket =
        socket
        |> assign(:setting_up_aws, false)
        |> put_flash(:error, """
        ❌ AWS Credentials Required

        Please configure AWS Access Key ID and Secret Access Key before running setup.

        You can get these credentials from AWS IAM Console:
        https://console.aws.amazon.com/iam/home#/users
        """)

      {:noreply, socket}
    end
  end

  def handle_event("save_aws_settings", %{"aws_settings" => aws_params}, socket) do
    socket = assign(socket, :saving, true)

    # Prepare all settings for batch update
    settings_to_update = %{
      "aws_access_key_id" => aws_params["access_key_id"] || "",
      "aws_secret_access_key" => aws_params["secret_access_key"] || "",
      "aws_region" => aws_params["region"] || "eu-north-1",
      "aws_sqs_queue_url" => aws_params["sqs_queue_url"] || "",
      "aws_sqs_dlq_url" => aws_params["sqs_dlq_url"] || "",
      "aws_sqs_queue_arn" => aws_params["sqs_queue_arn"] || "",
      "aws_sns_topic_arn" => aws_params["sns_topic_arn"] || "",
      "aws_ses_configuration_set" => aws_params["ses_configuration_set"] || "phoenixkit-tracking",
      "sqs_polling_interval_ms" => aws_params["sqs_polling_interval_ms"] || "5000"
    }

    # Update all settings in a single transaction
    case Settings.update_settings_batch(settings_to_update) do
      {:ok, _results} ->
        new_aws_settings = build_aws_settings_map(aws_params)

        socket =
          socket
          |> assign(:aws_settings, new_aws_settings)
          |> assign(:saving, false)
          |> put_flash(:info, "AWS settings saved successfully")

        {:noreply, socket}

      {:error, _failed_operation, _failed_value, _changes} ->
        socket =
          socket
          |> assign(:saving, false)
          |> put_flash(:error, "Failed to save AWS settings")

        {:noreply, socket}
    end
  end

  defp get_current_path(_socket, _session) do
    # For Email settings page
    Routes.path("/admin/settings/emails")
  end

  # Build AWS settings map from params
  defp build_aws_settings_map(aws_params) do
    %{
      access_key_id: aws_params["access_key_id"] || "",
      secret_access_key: aws_params["secret_access_key"] || "",
      region: aws_params["region"] || "eu-north-1",
      sqs_queue_url: aws_params["sqs_queue_url"] || "",
      sqs_dlq_url: aws_params["sqs_dlq_url"] || "",
      sqs_queue_arn: aws_params["sqs_queue_arn"] || "",
      sns_topic_arn: aws_params["sns_topic_arn"] || "",
      ses_configuration_set: aws_params["ses_configuration_set"] || "phoenixkit-tracking",
      sqs_polling_interval_ms: aws_params["sqs_polling_interval_ms"] || "5000"
    }
  end
end
