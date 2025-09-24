defmodule PhoenixKit.EmailTracking do
  @moduledoc """
  Email tracking system for PhoenixKit - main API module.

  This module provides the primary interface for email tracking functionality,
  including system configuration, log management, event tracking, and analytics.

  ## Core Features

  - **Email Logging**: Comprehensive logging of all outgoing emails
  - **Event Tracking**: Track delivery, bounce, complaint, open, and click events
  - **AWS SES Integration**: Deep integration with AWS SES for event tracking
  - **Analytics**: Detailed metrics and engagement analysis
  - **System Settings**: Configurable options for tracking behavior
  - **Rate Limiting**: Protection against abuse and spam
  - **Archival**: Automatic cleanup and archival of old data

  ## System Settings

  All settings are stored in the PhoenixKit settings system with module "email_tracking":

  - `email_tracking_enabled` - Enable/disable the entire tracking system
  - `email_tracking_save_body` - Save full email body (vs preview only)
  - `email_tracking_ses_events` - Track AWS SES delivery events
  - `email_tracking_cloudwatch_metrics` - Enable CloudWatch metrics
  - `email_tracking_retention_days` - Days to keep email logs (default: 90)
  - `aws_ses_configuration_set` - AWS SES configuration set name
  - `email_tracking_compress_body` - Compress body after N days
  - `email_tracking_archive_to_s3` - Enable S3 archival
  - `email_tracking_sampling_rate` - Percentage of emails to fully log

  ## Core Functions

  ### System Management
  - `enabled?/0` - Check if email tracking is enabled
  - `enable_system/0` - Enable email tracking
  - `disable_system/0` - Disable email tracking
  - `get_config/0` - Get current system configuration

  ### Email Log Management
  - `list_logs/1` - Get email logs with filters
  - `get_log!/1` - Get email log by ID
  - `create_log/1` - Create new email log
  - `update_log_status/2` - Update log status

  ### Event Management
  - `create_event/1` - Create tracking event
  - `list_events_for_log/1` - Get events for specific log
  - `process_webhook_event/1` - Process incoming webhook

  ### Analytics & Metrics
  - `get_system_stats/1` - Overall system statistics
  - `get_engagement_metrics/1` - Open/click rate analysis
  - `get_campaign_stats/1` - Campaign-specific metrics
  - `get_provider_performance/1` - Provider comparison

  ### Maintenance
  - `cleanup_old_logs/1` - Remove old logs
  - `compress_old_bodies/1` - Compress storage
  - `archive_to_s3/1` - Archive to S3

  ## Usage Examples

      # Check if system is enabled
      if PhoenixKit.EmailTracking.enabled?() do
        # Tracking is active
      end

      # Get system statistics
      stats = PhoenixKit.EmailTracking.get_system_stats(:last_30_days)
      # => %{total_sent: 5000, delivered: 4850, bounce_rate: 2.5, open_rate: 23.4}

      # Get campaign performance
      campaign_stats = PhoenixKit.EmailTracking.get_campaign_stats("newsletter_2024")
      # => %{total_sent: 1000, delivery_rate: 98.5, open_rate: 25.2, click_rate: 4.8}

      # Process webhook from AWS SES
      {:ok, event} = PhoenixKit.EmailTracking.process_webhook_event(webhook_data)

      # Clean up old data
      {deleted_count, _} = PhoenixKit.EmailTracking.cleanup_old_logs(90)

  ## Configuration Example

      # In your application config
      config :phoenix_kit,
        email_tracking_enabled: true,
        email_tracking_save_body: false,
        email_tracking_retention_days: 90,
        aws_ses_configuration_set: "my-app-tracking"
  """

  alias PhoenixKit.EmailTracking.{EmailEvent, EmailLog, SQSProcessor}
  alias PhoenixKit.Settings

  ## --- Manual Synchronization Functions ---

  @doc """
  Manually sync email status by fetching events from SQS queues.

  This function searches for events in both the main SQS queue and DLQ
  that match the given message_id and processes them to update email status.

  ## Parameters

  - `message_id` - The AWS SES message ID to sync

  ## Returns

  - `{:ok, result}` - Successful sync with processing results
  - `{:error, reason}` - Error during sync process

  ## Examples

      iex> PhoenixKit.EmailTracking.sync_email_status("0110019971abc123-...")
      {:ok, %{events_processed: 3, log_updated: true}}
  """
  def sync_email_status(message_id) when is_binary(message_id) do
    if enabled?() do
      # Try to find existing log
      _existing_log =
        case get_log_by_message_id(message_id) do
          {:ok, log} -> log
          {:error, :not_found} -> nil
        end

      # Get events from SQS and DLQ
      sqs_events = fetch_sqs_events_for_message(message_id)
      dlq_events = fetch_dlq_events_for_message(message_id)

      all_events = sqs_events ++ dlq_events

      if Enum.empty?(all_events) do
        {:ok,
         %{
           events_processed: 0,
           total_events_found: 0,
           log_updated: false,
           message: "No events found"
         }}
      else
        # Process events through SQS processor
        results =
          Enum.map(all_events, fn event ->
            SQSProcessor.process_email_event(event)
          end)

        successful_results =
          Enum.filter(results, fn
            {:ok, _} -> true
            _ -> false
          end)

        {:ok,
         %{
           events_processed: length(successful_results),
           total_events_found: length(all_events),
           log_updated: length(successful_results) > 0,
           results: successful_results
         }}
      end
    else
      {:error, :tracking_disabled}
    end
  end

  @doc """
  Fetch SES events from main SQS queue for specific message ID.

  ## Parameters

  - `message_id` - The AWS SES message ID to search for

  ## Returns

  List of SES events matching the message ID.
  """
  def fetch_sqs_events_for_message(message_id) do
    queue_url = Settings.get_setting("aws_sqs_queue_url")

    if queue_url do
      try do
        messages =
          ExAws.SQS.receive_message(queue_url, max_number_of_messages: 10)
          |> ExAws.request()
          |> case do
            {:ok, %{body: %{messages: messages}}} -> messages
            _ -> []
          end

        # Filter messages by message_id
        messages
        |> Enum.filter(fn message ->
          case parse_and_check_message_id(message, message_id) do
            true -> true
            false -> false
          end
        end)
        |> Enum.map(fn message ->
          case SQSProcessor.parse_sns_message(message) do
            {:ok, event_data} -> event_data
            {:error, _} -> nil
          end
        end)
        |> Enum.filter(&(&1 != nil))
      rescue
        _ -> []
      end
    else
      []
    end
  end

  @doc """
  Fetch SES events from DLQ queue for specific message ID.

  ## Parameters

  - `message_id` - The AWS SES message ID to search for

  ## Returns

  List of SES events matching the message ID from DLQ.
  """
  def fetch_dlq_events_for_message(message_id) do
    dlq_url = Settings.get_setting("aws_sqs_dlq_url")

    if dlq_url do
      try do
        messages =
          ExAws.SQS.receive_message(dlq_url, max_number_of_messages: 10)
          |> ExAws.request()
          |> case do
            {:ok, %{body: %{messages: messages}}} -> messages
            _ -> []
          end

        # Filter messages by message_id
        messages
        |> Enum.filter(fn message ->
          case parse_and_check_message_id(message, message_id) do
            true -> true
            false -> false
          end
        end)
        |> Enum.map(fn message ->
          case SQSProcessor.parse_sns_message(message) do
            {:ok, event_data} -> event_data
            {:error, _} -> nil
          end
        end)
        |> Enum.filter(&(&1 != nil))
      rescue
        _ -> []
      end
    else
      []
    end
  end

  # Helper function to check message_id in message
  defp parse_and_check_message_id(sqs_message, target_message_id) do
    case SQSProcessor.parse_sns_message(sqs_message) do
      {:ok, event_data} ->
        message_id = get_in(event_data, ["mail", "messageId"])
        message_id == target_message_id

      {:error, _} ->
        false
    end
  rescue
    _ -> false
  end

  ## --- System Settings ---

  @doc """
  Checks if the email tracking system is enabled.

  Returns true if the "email_tracking_enabled" setting is true.

  ## Examples

      iex> PhoenixKit.EmailTracking.enabled?()
      true
  """
  def enabled? do
    Settings.get_boolean_setting("email_tracking_enabled", false)
  end

  @doc """
  Enables the email tracking system.

  Sets the "email_tracking_enabled" setting to true.

  ## Examples

      iex> PhoenixKit.EmailTracking.enable_system()
      {:ok, %Setting{}}
  """
  def enable_system do
    Settings.update_boolean_setting_with_module("email_tracking_enabled", true, "email_tracking")
  end

  @doc """
  Disables the email tracking system.

  Sets the "email_tracking_enabled" setting to false.

  ## Examples

      iex> PhoenixKit.EmailTracking.disable_system()
      {:ok, %Setting{}}
  """
  def disable_system do
    Settings.update_boolean_setting_with_module("email_tracking_enabled", false, "email_tracking")
  end

  @doc """
  Checks if full email body saving is enabled.

  Returns true if the "email_tracking_save_body" setting is true.

  ## Examples

      iex> PhoenixKit.EmailTracking.save_body_enabled?()
      false
  """
  def save_body_enabled? do
    Settings.get_boolean_setting("email_tracking_save_body", false)
  end

  @doc """
  Enables or disables full email body saving.

  ## Examples

      iex> PhoenixKit.EmailTracking.set_save_body(true)
      {:ok, %Setting{}}
  """
  def set_save_body(enabled) when is_boolean(enabled) do
    Settings.update_boolean_setting_with_module(
      "email_tracking_save_body",
      enabled,
      "email_tracking"
    )
  end

  @doc """
  Checks if AWS SES event tracking is enabled.

  ## Examples

      iex> PhoenixKit.EmailTracking.ses_events_enabled?()
      true
  """
  def ses_events_enabled? do
    Settings.get_boolean_setting("email_tracking_ses_events", true)
  end

  @doc """
  Enables or disables AWS SES event tracking.

  ## Examples

      iex> PhoenixKit.EmailTracking.set_ses_events(true)
      {:ok, %Setting{}}
  """
  def set_ses_events(enabled) when is_boolean(enabled) do
    Settings.update_boolean_setting_with_module(
      "email_tracking_ses_events",
      enabled,
      "email_tracking"
    )
  end

  @doc """
  Gets the configured retention period for email logs in days.

  ## Examples

      iex> PhoenixKit.EmailTracking.get_retention_days()
      90
  """
  def get_retention_days do
    Settings.get_integer_setting("email_tracking_retention_days", 90)
  end

  @doc """
  Sets the retention period for email logs.

  ## Examples

      iex> PhoenixKit.EmailTracking.set_retention_days(180)
      {:ok, %Setting{}}
  """
  def set_retention_days(days) when is_integer(days) and days > 0 do
    Settings.update_setting_with_module(
      "email_tracking_retention_days",
      to_string(days),
      "email_tracking"
    )
  end

  @doc """
  Gets the AWS SES configuration set name.

  ## Examples

      iex> PhoenixKit.EmailTracking.get_ses_configuration_set()
      "my-app-tracking"
  """
  def get_ses_configuration_set do
    Settings.get_setting("aws_ses_configuration_set", nil)
  end

  @doc """
  Sets the AWS SES configuration set name.

  ## Examples

      iex> PhoenixKit.EmailTracking.set_ses_configuration_set("my-tracking-set")
      {:ok, %Setting{}}
  """
  def set_ses_configuration_set(config_set_name) when is_binary(config_set_name) do
    Settings.update_setting_with_module(
      "aws_ses_configuration_set",
      config_set_name,
      "email_tracking"
    )
  end

  @doc """
  Gets the sampling rate for email logging (percentage).

  ## Examples

      iex> PhoenixKit.EmailTracking.get_sampling_rate()
      100  # Log 100% of emails
  """
  def get_sampling_rate do
    Settings.get_integer_setting("email_tracking_sampling_rate", 100)
  end

  @doc """
  Sets the sampling rate for email logging.

  ## Examples

      iex> PhoenixKit.EmailTracking.set_sampling_rate(80)  # Log 80% of emails
      {:ok, %Setting{}}
  """
  def set_sampling_rate(percentage)
      when is_integer(percentage) and percentage >= 0 and percentage <= 100 do
    Settings.update_setting_with_module(
      "email_tracking_sampling_rate",
      to_string(percentage),
      "email_tracking"
    )
  end

  ## --- AWS SQS Configuration ---

  @doc """
  Gets the AWS SNS Topic ARN for email events.

  ## Examples

      iex> PhoenixKit.EmailTracking.get_sns_topic_arn()
      "arn:aws:sns:eu-north-1:123456789012:phoenixkit-email-events"
  """
  def get_sns_topic_arn do
    Settings.get_setting("aws_sns_topic_arn", nil)
  end

  @doc """
  Sets the AWS SNS Topic ARN for email events.

  ## Examples

      iex> PhoenixKit.EmailTracking.set_sns_topic_arn("arn:aws:sns:eu-north-1:123456789012:phoenixkit-email-events")
      {:ok, %Setting{}}
  """
  def set_sns_topic_arn(topic_arn) when is_binary(topic_arn) do
    Settings.update_setting_with_module(
      "aws_sns_topic_arn",
      topic_arn,
      "email_tracking"
    )
  end

  @doc """
  Gets the AWS SQS Queue URL for email events.

  ## Examples

      iex> PhoenixKit.EmailTracking.get_sqs_queue_url()
      "https://sqs.eu-north-1.amazonaws.com/123456789012/phoenixkit-email-queue"
  """
  def get_sqs_queue_url do
    Settings.get_setting("aws_sqs_queue_url", nil)
  end

  @doc """
  Sets the AWS SQS Queue URL for email events.

  ## Examples

      iex> PhoenixKit.EmailTracking.set_sqs_queue_url("https://sqs.eu-north-1.amazonaws.com/123456789012/phoenixkit-email-queue")
      {:ok, %Setting{}}
  """
  def set_sqs_queue_url(queue_url) when is_binary(queue_url) do
    Settings.update_setting_with_module(
      "aws_sqs_queue_url",
      queue_url,
      "email_tracking"
    )
  end

  @doc """
  Gets the AWS SQS Queue ARN for email events.

  ## Examples

      iex> PhoenixKit.EmailTracking.get_sqs_queue_arn()
      "arn:aws:sqs:eu-north-1:123456789012:phoenixkit-email-queue"
  """
  def get_sqs_queue_arn do
    Settings.get_setting("aws_sqs_queue_arn", nil)
  end

  @doc """
  Sets the AWS SQS Queue ARN for email events.

  ## Examples

      iex> PhoenixKit.EmailTracking.set_sqs_queue_arn("arn:aws:sqs:eu-north-1:123456789012:phoenixkit-email-queue")
      {:ok, %Setting{}}
  """
  def set_sqs_queue_arn(queue_arn) when is_binary(queue_arn) do
    Settings.update_setting_with_module(
      "aws_sqs_queue_arn",
      queue_arn,
      "email_tracking"
    )
  end

  @doc """
  Gets the AWS SQS Dead Letter Queue URL.

  ## Examples

      iex> PhoenixKit.EmailTracking.get_sqs_dlq_url()
      "https://sqs.eu-north-1.amazonaws.com/123456789012/phoenixkit-email-dlq"
  """
  def get_sqs_dlq_url do
    Settings.get_setting("aws_sqs_dlq_url", nil)
  end

  @doc """
  Sets the AWS SQS Dead Letter Queue URL.

  ## Examples

      iex> PhoenixKit.EmailTracking.set_sqs_dlq_url("https://sqs.eu-north-1.amazonaws.com/123456789012/phoenixkit-email-dlq")
      {:ok, %Setting{}}
  """
  def set_sqs_dlq_url(dlq_url) when is_binary(dlq_url) do
    Settings.update_setting_with_module(
      "aws_sqs_dlq_url",
      dlq_url,
      "email_tracking"
    )
  end

  @doc """
  Gets the AWS region for SES and SQS services.

  ## Examples

      iex> PhoenixKit.EmailTracking.get_aws_region()
      "eu-north-1"
  """
  def get_aws_region do
    Settings.get_setting("aws_region", System.get_env("AWS_REGION", "eu-north-1"))
  end

  @doc """
  Sets the AWS region for SES and SQS services.

  ## Examples

      iex> PhoenixKit.EmailTracking.set_aws_region("eu-north-1")
      {:ok, %Setting{}}
  """
  def set_aws_region(region) when is_binary(region) do
    Settings.update_setting_with_module(
      "aws_region",
      region,
      "email_tracking"
    )
  end

  ## --- SQS Worker Configuration ---

  @doc """
  Checks if SQS polling is enabled.

  ## Examples

      iex> PhoenixKit.EmailTracking.sqs_polling_enabled?()
      true
  """
  def sqs_polling_enabled? do
    Settings.get_boolean_setting("sqs_polling_enabled", false)
  end

  @doc """
  Enables or disables SQS polling.

  ## Examples

      iex> PhoenixKit.EmailTracking.set_sqs_polling(true)
      {:ok, %Setting{}}
  """
  def set_sqs_polling(enabled) when is_boolean(enabled) do
    Settings.update_setting_with_module(
      "sqs_polling_enabled",
      to_string(enabled),
      "email_tracking"
    )
  end

  @doc """
  Gets the SQS polling interval in milliseconds.

  ## Examples

      iex> PhoenixKit.EmailTracking.get_sqs_polling_interval()
      5000  # 5 seconds
  """
  def get_sqs_polling_interval do
    Settings.get_integer_setting("sqs_polling_interval_ms", 5000)
  end

  @doc """
  Sets the SQS polling interval in milliseconds.

  ## Examples

      iex> PhoenixKit.EmailTracking.set_sqs_polling_interval(3000)  # 3 seconds
      {:ok, %Setting{}}
  """
  def set_sqs_polling_interval(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Settings.update_setting_with_module(
      "sqs_polling_interval_ms",
      to_string(interval_ms),
      "email_tracking"
    )
  end

  @doc """
  Gets the maximum number of SQS messages to receive per polling cycle.

  ## Examples

      iex> PhoenixKit.EmailTracking.get_sqs_max_messages()
      10
  """
  def get_sqs_max_messages do
    Settings.get_integer_setting("sqs_max_messages_per_poll", 10)
  end

  @doc """
  Sets the maximum number of SQS messages to receive per polling cycle.

  ## Examples

      iex> PhoenixKit.EmailTracking.set_sqs_max_messages(20)
      {:ok, %Setting{}}
  """
  def set_sqs_max_messages(max_messages)
      when is_integer(max_messages) and max_messages > 0 and max_messages <= 10 do
    Settings.update_setting_with_module(
      "sqs_max_messages_per_poll",
      to_string(max_messages),
      "email_tracking"
    )
  end

  @doc """
  Gets the SQS message visibility timeout in seconds.

  ## Examples

      iex> PhoenixKit.EmailTracking.get_sqs_visibility_timeout()
      300  # 5 minutes
  """
  def get_sqs_visibility_timeout do
    Settings.get_integer_setting("sqs_visibility_timeout", 300)
  end

  @doc """
  Sets the SQS message visibility timeout in seconds.

  ## Examples

      iex> PhoenixKit.EmailTracking.set_sqs_visibility_timeout(600)  # 10 minutes
      {:ok, %Setting{}}
  """
  def set_sqs_visibility_timeout(timeout_seconds)
      when is_integer(timeout_seconds) and timeout_seconds > 0 do
    Settings.update_setting_with_module(
      "sqs_visibility_timeout",
      to_string(timeout_seconds),
      "email_tracking"
    )
  end

  @doc """
  Gets comprehensive SQS configuration.

  ## Examples

      iex> PhoenixKit.EmailTracking.get_sqs_config()
      %{
        sns_topic_arn: "arn:aws:sns:...",
        queue_url: "https://sqs.eu-north-1.amazonaws.com/...",
        polling_enabled: true,
        polling_interval_ms: 5000,
        max_messages_per_poll: 10
      }
  """
  def get_sqs_config do
    %{
      sns_topic_arn: get_sns_topic_arn(),
      queue_url: get_sqs_queue_url(),
      queue_arn: get_sqs_queue_arn(),
      dlq_url: get_sqs_dlq_url(),
      aws_region: get_aws_region(),
      aws_access_key_id: System.get_env("AWS_ACCESS_KEY_ID"),
      aws_secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY"),
      polling_enabled: sqs_polling_enabled?(),
      polling_interval_ms: get_sqs_polling_interval(),
      max_messages_per_poll: get_sqs_max_messages(),
      visibility_timeout: get_sqs_visibility_timeout()
    }
  end

  @doc """
  Gets the current email tracking system configuration.

  Returns a map with all current settings.

  ## Examples

      iex> PhoenixKit.EmailTracking.get_config()
      %{
        enabled: true,
        save_body: false,
        ses_events: true,
        retention_days: 90,
        sampling_rate: 100,
        ses_configuration_set: "my-tracking",
        sns_topic_arn: "arn:aws:sns:eu-north-1:123456789012:phoenixkit-email-events",
        sqs_queue_url: "https://sqs.eu-north-1.amazonaws.com/123456789012/phoenixkit-email-queue",
        sqs_polling_enabled: false,
        aws_region: "eu-north-1"
      }
  """
  def get_config do
    %{
      enabled: enabled?(),
      save_body: save_body_enabled?(),
      ses_events: ses_events_enabled?(),
      retention_days: get_retention_days(),
      sampling_rate: get_sampling_rate(),
      ses_configuration_set: get_ses_configuration_set(),
      compress_after_days: get_compress_after_days(),
      archive_to_s3: s3_archival_enabled?(),
      cloudwatch_metrics: cloudwatch_metrics_enabled?(),
      # AWS SQS Configuration
      sns_topic_arn: get_sns_topic_arn(),
      sqs_queue_url: get_sqs_queue_url(),
      sqs_queue_arn: get_sqs_queue_arn(),
      sqs_dlq_url: get_sqs_dlq_url(),
      aws_region: get_aws_region(),
      # SQS Worker Configuration
      sqs_polling_enabled: sqs_polling_enabled?(),
      sqs_polling_interval_ms: get_sqs_polling_interval(),
      sqs_max_messages_per_poll: get_sqs_max_messages(),
      sqs_visibility_timeout: get_sqs_visibility_timeout()
    }
  end

  ## --- Email Log Management ---

  @doc """
  Lists email logs with optional filters.

  ## Options

  - `:status` - Filter by status (sent, delivered, bounced, etc.)
  - `:campaign_id` - Filter by campaign
  - `:template_name` - Filter by template
  - `:provider` - Filter by email provider
  - `:from_date` - Emails sent after this date
  - `:to_date` - Emails sent before this date
  - `:recipient` - Filter by recipient email
  - `:limit` - Limit results (default: 50)
  - `:offset` - Offset for pagination

  ## Examples

      iex> PhoenixKit.EmailTracking.list_logs(%{status: "bounced", limit: 10})
      [%EmailLog{}, ...]
  """
  def list_logs(filters \\ %{}) do
    if enabled?() do
      EmailLog.list_logs(filters)
    else
      []
    end
  end

  @doc """
  Counts email logs with optional filtering (without loading all records).

  ## Parameters

  - `filters` - Map of filters to apply (optional)

  ## Examples

      iex> PhoenixKit.EmailTracking.count_logs(%{status: "bounced"})
      42
  """
  def count_logs(filters \\ %{}) do
    if enabled?() do
      EmailLog.count_logs(filters)
    else
      0
    end
  end

  @doc """
  Gets a single email log by ID.

  Raises `Ecto.NoResultsError` if the log does not exist or system is disabled.

  ## Examples

      iex> PhoenixKit.EmailTracking.get_log!(123)
      %EmailLog{}
  """
  def get_log!(id) do
    ensure_enabled!()
    EmailLog.get_log!(id)
  end

  @doc """
  Gets an email log by message ID.

  ## Examples

      iex> PhoenixKit.EmailTracking.get_log_by_message_id("msg-abc123")
      %EmailLog{}
  """
  def get_log_by_message_id(message_id) when is_binary(message_id) do
    if enabled?() do
      case EmailLog.get_log_by_message_id(message_id) do
        nil -> {:error, :not_found}
        log -> {:ok, log}
      end
    else
      {:error, :tracking_disabled}
    end
  end

  @doc """
  Creates an email log if tracking is enabled.

  ## Examples

      iex> PhoenixKit.EmailTracking.create_log(%{
        message_id: "abc123",
        to: "user@example.com",
        from: "app@example.com"
      })
      {:ok, %EmailLog{}}
  """
  def create_log(attrs \\ %{}) do
    if enabled?() and should_log_email?(attrs) do
      # Add system-level defaults
      attrs =
        Map.merge(attrs, %{
          configuration_set: get_ses_configuration_set(),
          body_full:
            if(save_body_enabled?() and attrs[:body_full], do: attrs[:body_full], else: nil)
        })

      EmailLog.create_log(attrs)
    else
      {:ok, :skipped}
    end
  end

  @doc """
  Updates the status of an email log.

  ## Examples

      iex> PhoenixKit.EmailTracking.update_log_status(log, "delivered")
      {:ok, %EmailLog{}}
  """
  def update_log_status(log, status) when is_binary(status) do
    if enabled?() do
      EmailLog.update_status(log, status)
    else
      {:ok, log}
    end
  end

  ## --- Event Management ---

  @doc """
  Creates an email tracking event.

  ## Examples

      iex> PhoenixKit.EmailTracking.create_event(%{
        email_log_id: 1,
        event_type: "open"
      })
      {:ok, %EmailEvent{}}
  """
  def create_event(attrs \\ %{}) do
    if enabled?() and ses_events_enabled?() do
      EmailEvent.create_event(attrs)
    else
      {:ok, :skipped}
    end
  end

  @doc """
  Lists events for a specific email log.

  ## Examples

      iex> PhoenixKit.EmailTracking.list_events_for_log(123)
      [%EmailEvent{}, ...]
  """
  def list_events_for_log(email_log_id) when is_integer(email_log_id) do
    if enabled?() do
      EmailEvent.for_email_log(email_log_id)
    else
      []
    end
  end

  @doc """
  Processes an incoming webhook event (typically from AWS SES).

  ## Examples

      iex> webhook_data = %{
        "eventType" => "bounce",
        "mail" => %{"messageId" => "abc123"}
      }
      iex> PhoenixKit.EmailTracking.process_webhook_event(webhook_data)
      {:ok, %EmailEvent{}}
  """
  def process_webhook_event(webhook_data) when is_map(webhook_data) do
    if enabled?() and ses_events_enabled?() do
      case extract_message_id(webhook_data) do
        nil ->
          {:error, :message_id_not_found}

        message_id ->
          case get_log_by_message_id(message_id) do
            {:error, :not_found} ->
              {:error, :email_log_not_found}

            {:ok, email_log} ->
              process_event_for_log(email_log, webhook_data)

            {:error, reason} ->
              {:error, reason}
          end
      end
    else
      {:ok, :skipped}
    end
  end

  ## --- Analytics & Metrics ---

  @doc """
  Gets overall system statistics for a time period.

  ## Examples

      iex> PhoenixKit.EmailTracking.get_system_stats(:last_30_days)
      %{
        total_sent: 5000,
        delivered: 4850,
        bounced: 150,
        opened: 1200,
        clicked: 240,
        delivery_rate: 97.0,
        bounce_rate: 3.0,
        open_rate: 24.7,
        click_rate: 20.0
      }
  """
  def get_system_stats(period \\ :last_30_days) do
    if enabled?() do
      {start_date, end_date} = get_period_dates(period)

      basic_stats = EmailLog.get_stats_for_period(start_date, end_date)

      Map.merge(basic_stats, %{
        # Add aliases for email_stats.ex compatibility
        complaints: basic_stats.complained,
        total_opened: basic_stats.opened,
        total_clicked: basic_stats.clicked,
        # Calculate percentages
        delivery_rate: safe_percentage(basic_stats.delivered, basic_stats.total_sent),
        bounce_rate: safe_percentage(basic_stats.bounced, basic_stats.total_sent),
        complaint_rate: safe_percentage(basic_stats.complained, basic_stats.total_sent),
        open_rate: safe_percentage(basic_stats.opened, basic_stats.delivered),
        click_rate: safe_percentage(basic_stats.clicked, basic_stats.opened),
        failure_rate: safe_percentage(basic_stats.failed, basic_stats.total_sent)
      })
    else
      %{}
    end
  end

  @doc """
  Gets engagement metrics with trend analysis.

  ## Examples

      iex> PhoenixKit.EmailTracking.get_engagement_metrics(:last_7_days)
      %{
        avg_open_rate: 24.5,
        avg_click_rate: 4.2,
        bounce_rate: 2.8,
        engagement_trend: :increasing
      }
  """
  def get_engagement_metrics(period \\ :last_30_days) do
    if enabled?() do
      EmailLog.get_engagement_metrics(period)
    else
      %{}
    end
  end

  @doc """
  Gets statistics for a specific campaign.

  ## Examples

      iex> PhoenixKit.EmailTracking.get_campaign_stats("newsletter_2024")
      %{
        total_sent: 1000,
        delivery_rate: 98.5,
        open_rate: 25.2,
        click_rate: 4.8
      }
  """
  def get_campaign_stats(campaign_id) when is_binary(campaign_id) do
    if enabled?() do
      EmailLog.get_campaign_stats(campaign_id)
    else
      %{}
    end
  end

  @doc """
  Gets provider-specific performance metrics.

  ## Examples

      iex> PhoenixKit.EmailTracking.get_provider_performance(:last_7_days)
      %{
        "aws_ses" => %{delivery_rate: 98.5, bounce_rate: 1.5},
        "smtp" => %{delivery_rate: 95.0, bounce_rate: 5.0}
      }
  """
  def get_provider_performance(period \\ :last_7_days) do
    if enabled?() do
      EmailLog.get_provider_performance(period)
    else
      %{}
    end
  end

  @doc """
  Gets geographic distribution of engagement events.

  ## Examples

      iex> PhoenixKit.EmailTracking.get_geo_stats("open", :last_30_days)
      %{"US" => 500, "CA" => 200, "UK" => 150}
  """
  def get_geo_stats(event_type, period \\ :last_30_days) do
    if enabled?() do
      {start_date, end_date} = get_period_dates(period)
      EmailEvent.get_geo_distribution(event_type, start_date, end_date)
    else
      %{}
    end
  end

  @doc """
  Gets the most clicked links for a time period.

  ## Examples

      iex> PhoenixKit.EmailTracking.get_top_links(:last_30_days, 10)
      [%{url: "https://example.com/product", clicks: 150}, ...]
  """
  def get_top_links(period \\ :last_30_days, limit \\ 10) do
    if enabled?() do
      {start_date, end_date} = get_period_dates(period)
      EmailEvent.get_top_clicked_links(start_date, end_date, limit)
    else
      []
    end
  end

  ## --- Maintenance Functions ---

  @doc """
  Removes email logs older than the specified number of days.

  Uses the system retention setting if no days specified.

  ## Examples

      iex> PhoenixKit.EmailTracking.cleanup_old_logs()
      {150, nil}  # Deleted 150 records

      iex> PhoenixKit.EmailTracking.cleanup_old_logs(180)
      {75, nil}   # Deleted 75 records older than 180 days
  """
  def cleanup_old_logs(days_old \\ nil) do
    if enabled?() do
      days = days_old || get_retention_days()
      EmailLog.cleanup_old_logs(days)
    else
      {0, nil}
    end
  end

  @doc """
  Compresses body_full field for old email logs to save storage.

  ## Examples

      iex> PhoenixKit.EmailTracking.compress_old_bodies()
      {25, nil}  # Compressed 25 records

      iex> PhoenixKit.EmailTracking.compress_old_bodies(60)
      {40, nil}  # Compressed 40 records older than 60 days
  """
  def compress_old_bodies(days_old \\ nil) do
    if enabled?() do
      days = days_old || get_compress_after_days()
      EmailLog.compress_old_bodies(days)
    else
      {0, nil}
    end
  end

  @doc """
  Archives old email logs to S3 if archival is enabled.

  ## Examples

      iex> PhoenixKit.EmailTracking.archive_to_s3()
      {:ok, archived_count: 100, s3_key: "archives/2024/01/emails.json"}
  """
  def archive_to_s3(days_old \\ nil) do
    if enabled?() and s3_archival_enabled?() do
      days = days_old || get_retention_days()
      logs_to_archive = EmailLog.get_logs_for_archival(days)

      if length(logs_to_archive) > 0 do
        # This would be implemented in a separate Archiver module
        # For now, return a placeholder
        {:ok, archived_count: length(logs_to_archive), logs: logs_to_archive}
      else
        {:ok, archived_count: 0, logs: []}
      end
    else
      {:ok, :skipped}
    end
  end

  ## --- Private Helper Functions ---

  # Ensure the system is enabled, raise if not
  defp ensure_enabled! do
    unless enabled?() do
      raise "Email tracking system is not enabled"
    end
  end

  # Determine if an email should be logged based on sampling rate
  defp should_log_email?(_attrs) do
    sampling_rate = get_sampling_rate()

    if sampling_rate >= 100 do
      true
    else
      # Use deterministic sampling based on message_id or random
      :rand.uniform(100) <= sampling_rate
    end
  end

  # Extract message ID from webhook data
  defp extract_message_id(webhook_data) do
    webhook_data["mail"]["messageId"] ||
      webhook_data["messageId"] ||
      get_in(webhook_data, ["mail", "commonHeaders", "messageId"])
  end

  # Process a specific event for an email log
  defp process_event_for_log(email_log, webhook_data) do
    case EmailEvent.create_from_ses_webhook(email_log, webhook_data) do
      {:ok, event} ->
        # Update email log status based on event
        update_log_status_from_event(email_log, event)
        {:ok, event}

      error ->
        error
    end
  end

  # Update email log status based on event type
  defp update_log_status_from_event(email_log, %EmailEvent{event_type: "delivery"}) do
    EmailLog.mark_as_delivered(email_log)
  end

  defp update_log_status_from_event(email_log, %EmailEvent{
         event_type: "bounce",
         bounce_type: bounce_type
       }) do
    EmailLog.mark_as_bounced(email_log, bounce_type)
  end

  defp update_log_status_from_event(email_log, %EmailEvent{event_type: "open"}) do
    EmailLog.mark_as_opened(email_log)
  end

  defp update_log_status_from_event(email_log, %EmailEvent{event_type: "click", link_url: url}) do
    EmailLog.mark_as_clicked(email_log, url)
  end

  defp update_log_status_from_event(_email_log, _event) do
    # No status update needed for other event types
    :ok
  end

  # Get compression setting
  defp get_compress_after_days do
    Settings.get_integer_setting("email_tracking_compress_body", 30)
  end

  # Check if S3 archival is enabled
  defp s3_archival_enabled? do
    Settings.get_boolean_setting("email_tracking_archive_to_s3", false)
  end

  # Check if CloudWatch metrics are enabled
  defp cloudwatch_metrics_enabled? do
    Settings.get_boolean_setting("email_tracking_cloudwatch_metrics", false)
  end

  # Get period start/end dates
  defp get_period_dates(:last_7_days) do
    end_date = DateTime.utc_now()
    start_date = DateTime.add(end_date, -7, :day)
    {start_date, end_date}
  end

  defp get_period_dates(:last_30_days) do
    end_date = DateTime.utc_now()
    start_date = DateTime.add(end_date, -30, :day)
    {start_date, end_date}
  end

  defp get_period_dates(:last_90_days) do
    end_date = DateTime.utc_now()
    start_date = DateTime.add(end_date, -90, :day)
    {start_date, end_date}
  end

  defp get_period_dates(:last_24_hours) do
    end_date = DateTime.utc_now()
    start_date = DateTime.add(end_date, -1, :day)
    {start_date, end_date}
  end

  defp get_period_dates({:date_range, start_date, end_date})
       when is_struct(start_date, Date) and is_struct(end_date, Date) do
    start_datetime = DateTime.new!(start_date, ~T[00:00:00])
    end_datetime = DateTime.new!(end_date, ~T[23:59:59])
    {start_datetime, end_datetime}
  end

  # Calculate safe percentage
  defp safe_percentage(numerator, denominator) when denominator > 0 do
    (numerator / denominator * 100) |> Float.round(1)
  end

  defp safe_percentage(_, _), do: 0.0
end
