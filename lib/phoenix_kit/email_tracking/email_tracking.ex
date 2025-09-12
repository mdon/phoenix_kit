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

  alias PhoenixKit.Settings
  alias PhoenixKit.EmailTracking.{EmailLog, EmailEvent}

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
    Settings.update_boolean_setting_with_module("email_tracking_save_body", enabled, "email_tracking")
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
    Settings.update_boolean_setting_with_module("email_tracking_ses_events", enabled, "email_tracking")
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
  def set_sampling_rate(percentage) when is_integer(percentage) and percentage >= 0 and percentage <= 100 do
    Settings.update_setting_with_module(
      "email_tracking_sampling_rate",
      to_string(percentage),
      "email_tracking"
    )
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
        ses_configuration_set: "my-tracking"
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
      cloudwatch_metrics: cloudwatch_metrics_enabled?()
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
      EmailLog.get_log_by_message_id(message_id)
    else
      nil
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
      attrs = Map.merge(attrs, %{
        configuration_set: get_ses_configuration_set(),
        body_full: if(save_body_enabled?() and attrs[:body_full], do: attrs[:body_full], else: nil)
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
            nil ->
              {:error, :email_log_not_found}
              
            email_log ->
              process_event_for_log(email_log, webhook_data)
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
        delivery_rate: safe_percentage(basic_stats.delivered, basic_stats.total_sent),
        bounce_rate: safe_percentage(basic_stats.bounced, basic_stats.total_sent),
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
  
  defp update_log_status_from_event(email_log, %EmailEvent{event_type: "bounce", bounce_type: bounce_type}) do
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

  # Calculate safe percentage
  defp safe_percentage(numerator, denominator) when denominator > 0 do
    (numerator / denominator * 100) |> Float.round(1)
  end
  defp safe_percentage(_, _), do: 0.0
end