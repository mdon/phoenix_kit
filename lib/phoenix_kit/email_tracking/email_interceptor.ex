defmodule PhoenixKit.EmailTracking.EmailInterceptor do
  @moduledoc """
  Email interceptor for logging outgoing emails in PhoenixKit.

  This module provides functionality to intercept outgoing emails and create
  comprehensive logs for tracking purposes. It integrates seamlessly with
  the existing mailer system without disrupting email delivery.

  ## Features

  - **Transparent Interception**: Logs emails without affecting delivery
  - **Selective Logging**: Respects sampling rate and system settings
  - **AWS SES Integration**: Automatically adds configuration sets
  - **Rich Metadata Extraction**: Captures headers, size, attachments
  - **User Context**: Links emails to users when possible
  - **Template Recognition**: Identifies email templates and campaigns

  ## Integration

  The interceptor is designed to be called by the mailer before sending:

      # In PhoenixKit.Mailer.deliver_email/1
      email = EmailInterceptor.intercept_before_send(email, opts)
      # ... then send email normally

  ## Configuration

  The interceptor respects all email tracking system settings:

  - Only logs if `email_tracking_enabled` is true
  - Saves body based on `email_tracking_save_body` setting
  - Applies sampling rate from `email_tracking_sampling_rate`
  - Adds AWS SES configuration set if configured

  ## Examples

      # Basic interception
      logged_email = PhoenixKit.EmailTracking.EmailInterceptor.intercept_before_send(email)

      # With additional context
      logged_email = PhoenixKit.EmailTracking.EmailInterceptor.intercept_before_send(email, 
        user_id: 123,
        template_name: "welcome_email",
        campaign_id: "welcome_series"
      )

      # Check if email should be logged
      if PhoenixKit.EmailTracking.EmailInterceptor.should_log_email?(email) do
        # Log the email
      end
  """

  require Logger
  
  alias PhoenixKit.EmailTracking
  alias PhoenixKit.EmailTracking.EmailLog
  alias Swoosh.Email

  @doc """
  Intercepts an email before sending and creates a tracking log.

  Returns the email (potentially modified with tracking headers) and
  creates a log entry if tracking is enabled.

  ## Options

  - `:user_id` - Associate with a specific user
  - `:template_name` - Name of the email template
  - `:campaign_id` - Campaign identifier for grouping
  - `:provider` - Override provider detection
  - `:configuration_set` - Override AWS SES configuration set
  - `:message_tags` - Additional tags for the email

  ## Examples

      iex> email = new() |> to("user@example.com") |> from("app@example.com")
      iex> PhoenixKit.EmailTracking.EmailInterceptor.intercept_before_send(email, user_id: 123)
      %Swoosh.Email{headers: %{"X-PhoenixKit-Log-Id" => "456"}}
  """
  def intercept_before_send(%Email{} = email, opts \\ []) do
    if EmailTracking.enabled?() and should_log_email?(email, opts) do
      case create_email_log(email, opts) do
        {:ok, log} ->
          Logger.debug("Email tracked with ID: #{log.id}, Message ID: #{log.message_id}")
          
          # Add tracking headers to email
          add_tracking_headers(email, log, opts)
          
        {:ok, :skipped} ->
          Logger.debug("Email logging skipped due to sampling")
          email
          
        {:error, reason} ->
          Logger.error("Failed to log email: #{inspect(reason)}")
          email
      end
    else
      email
    end
  end

  @doc """
  Determines if an email should be logged based on system settings.

  Considers sampling rate, system enablement, and email characteristics.

  ## Examples

      iex> PhoenixKit.EmailTracking.EmailInterceptor.should_log_email?(email)
      true
  """
  def should_log_email?(%Email{} = email, opts \\ []) do
    cond do
      not EmailTracking.enabled?() ->
        false
        
      is_system_email?(email) ->
        # Always log system emails (errors, bounces, etc.)
        true
        
      true ->
        # Apply sampling rate for regular emails
        sampling_rate = EmailTracking.get_sampling_rate()
        meets_sampling_threshold?(email, sampling_rate)
    end
  end

  @doc """
  Extracts provider information from email or mailer configuration.

  ## Examples

      iex> PhoenixKit.EmailTracking.EmailInterceptor.detect_provider(email, [])
      "aws_ses"
  """
  def detect_provider(%Email{} = email, opts \\ []) do
    cond do
      provider = Keyword.get(opts, :provider) ->
        provider
        
      has_ses_headers?(email) ->
        "aws_ses"
        
      has_smtp_headers?(email) ->
        "smtp"
        
      true ->
        detect_provider_from_config()
    end
  end

  @doc """
  Creates an email log entry from a Swoosh.Email struct.

  ## Examples

      iex> PhoenixKit.EmailTracking.EmailInterceptor.create_email_log(email, user_id: 123)
      {:ok, %EmailLog{}}
  """
  def create_email_log(%Email{} = email, opts \\ []) do
    log_attrs = extract_email_data(email, opts)
    
    EmailTracking.create_log(log_attrs)
  end

  @doc """
  Adds tracking headers to an email for identification.

  ## Examples

      iex> email_with_headers = PhoenixKit.EmailTracking.EmailInterceptor.add_tracking_headers(email, log, [])
      %Swoosh.Email{headers: %{"X-PhoenixKit-Log-Id" => "123"}}
  """
  def add_tracking_headers(%Email{} = email, %EmailLog{} = log, opts \\ []) do
    tracking_headers = %{
      "X-PhoenixKit-Log-Id" => to_string(log.id),
      "X-PhoenixKit-Message-Id" => log.message_id
    }
    
    # Add AWS SES specific headers
    ses_headers = build_ses_headers(log, opts)
    
    all_headers = Map.merge(tracking_headers, ses_headers)
    
    # Add headers to email
    Enum.reduce(all_headers, email, fn {key, value}, acc_email ->
      Email.header(acc_email, key, value)
    end)
  end

  @doc """
  Builds AWS SES specific tracking headers and configuration.

  ## Examples

      iex> PhoenixKit.EmailTracking.EmailInterceptor.build_ses_headers(log, [])
      %{"X-SES-CONFIGURATION-SET" => "my-tracking-set"}
  """
  def build_ses_headers(%EmailLog{} = log, opts \\ []) do
    headers = %{}
    
    # Add configuration set if available
    headers = 
      case get_configuration_set(opts) do
        nil -> headers
        config_set -> Map.put(headers, "X-SES-CONFIGURATION-SET", config_set)
      end
    
    # Add message tags for AWS SES
    headers = 
      case build_message_tags(log, opts) do
        tags when map_size(tags) > 0 ->
          # Convert tags to SES format
          tag_headers = Enum.with_index(tags, 1)
          |> Enum.reduce(headers, fn {{key, value}, index}, acc ->
            Map.put(acc, "X-SES-MESSAGE-TAG-#{index}", "#{key}=#{value}")
          end)
          tag_headers
          
        _ -> headers
      end
    
    headers
  end

  @doc """
  Updates an email log after successful sending.

  This is called after the email provider confirms the send.

  ## Examples

      iex> PhoenixKit.EmailTracking.EmailInterceptor.update_after_send(log, provider_response)
      {:ok, %EmailLog{}}
  """
  def update_after_send(%EmailLog{} = log, provider_response \\ %{}) do
    update_attrs = %{
      status: "sent",
      sent_at: DateTime.utc_now()
    }
    
    # Extract additional data from provider response
    update_attrs = 
      case extract_provider_data(provider_response) do
        %{} = provider_data when map_size(provider_data) > 0 ->
          Map.merge(update_attrs, provider_data)
        _ -> update_attrs
      end
    
    EmailLog.update_log(log, update_attrs)
  end

  @doc """
  Updates an email log after send failure.

  ## Examples

      iex> PhoenixKit.EmailTracking.EmailInterceptor.update_after_failure(log, error)
      {:ok, %EmailLog{}}
  """
  def update_after_failure(%EmailLog{} = log, error) do
    error_message = extract_error_message(error)
    
    update_attrs = %{
      status: "failed",
      error_message: error_message,
      retry_count: log.retry_count + 1
    }
    
    EmailLog.update_log(log, update_attrs)
  end

  ## --- Private Helper Functions ---

  # Extract comprehensive data from Swoosh.Email
  defp extract_email_data(%Email{} = email, opts) do
    %{
      message_id: generate_message_id(email, opts),
      to: extract_primary_recipient(email.to),
      from: extract_sender(email.from),
      subject: email.subject || "(no subject)",
      headers: extract_headers(email),
      body_preview: extract_body_preview(email),
      body_full: extract_body_full(email, opts),
      attachments_count: length(email.attachments || []),
      size_bytes: estimate_email_size(email),
      template_name: Keyword.get(opts, :template_name),
      campaign_id: Keyword.get(opts, :campaign_id),
      user_id: Keyword.get(opts, :user_id),
      provider: detect_provider(email, opts),
      configuration_set: get_configuration_set(opts),
      message_tags: build_message_tags(email, opts),
      sent_at: DateTime.utc_now()
    }
  end

  # Generate or extract message ID
  defp generate_message_id(%Email{} = email, opts) do
    # Try to extract from existing headers first
    existing_id = 
      get_in(email.headers, ["Message-ID"]) ||
      get_in(email.headers, ["message-id"]) ||
      Keyword.get(opts, :message_id)
    
    case existing_id do
      nil -> "pk_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
      id -> String.trim(id, "<>")
    end
  end

  # Extract primary recipient email
  defp extract_primary_recipient([{_name, email} | _]), do: email
  defp extract_primary_recipient([email | _]) when is_binary(email), do: email
  defp extract_primary_recipient({_name, email}), do: email
  defp extract_primary_recipient(email) when is_binary(email), do: email
  defp extract_primary_recipient(_), do: "unknown@example.com"

  # Extract sender email
  defp extract_sender({_name, email}), do: email
  defp extract_sender(email) when is_binary(email), do: email
  defp extract_sender(_), do: "unknown@example.com"

  # Extract and clean headers
  defp extract_headers(%Email{headers: headers}) when is_map(headers) do
    # Remove sensitive headers and normalize
    headers
    |> Enum.reject(fn {key, _} -> 
      key in ["Authorization", "Authentication-Results", "X-Password", "X-API-Key"]
    end)
    |> Enum.into(%{})
  end
  defp extract_headers(_), do: %{}

  # Extract body preview (first 500+ characters)
  defp extract_body_preview(%Email{} = email) do
    body = email.text_body || email.html_body || ""
    
    body
    |> strip_html_tags()
    |> String.slice(0, 1000)  # Increased from 500 to 1000 as per plan
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # Extract full body if enabled
  defp extract_body_full(%Email{} = email, opts) do
    if EmailTracking.save_body_enabled?() or Keyword.get(opts, :save_body, false) do
      text_body = email.text_body || ""
      html_body = email.html_body || ""
      
      if String.length(html_body) > String.length(text_body) do
        html_body
      else
        text_body
      end
    else
      nil
    end
  end

  # Estimate email size in bytes
  defp estimate_email_size(%Email{} = email) do
    size = 0
    
    # Headers
    size = size + (email.headers |> inspect() |> byte_size())
    
    # Subject
    size = size + byte_size(email.subject || "")
    
    # Body
    size = size + byte_size(email.text_body || "")
    size = size + byte_size(email.html_body || "")
    
    # Attachments (rough estimate)
    attachment_size = 
      (email.attachments || [])
      |> Enum.reduce(0, fn attachment, acc ->
        case attachment do
          %{data: data} when is_binary(data) -> acc + byte_size(data)
          %{path: path} when is_binary(path) -> 
            case File.stat(path) do
              {:ok, %File.Stat{size: file_size}} -> acc + file_size
              _ -> acc + 10000  # Default estimate
            end
          _ -> acc + 10000  # Default estimate
        end
      end)
    
    size + attachment_size
  end

  # Check if email should be sampled
  defp meets_sampling_threshold?(%Email{} = email, sampling_rate) do
    if sampling_rate >= 100 do
      true
    else
      # Use deterministic sampling based on recipient email
      recipient = extract_primary_recipient(email.to)
      hash = :erlang.phash2(recipient, 100)
      hash < sampling_rate
    end
  end

  # Check if this is a system/critical email
  defp is_system_email?(%Email{} = email) do
    subject = String.downcase(email.subject || "")
    sender = String.downcase(extract_sender(email.from))
    
    # System emails are always logged
    String.contains?(subject, ["error", "bounce", "failure", "alert", "warning", "critical"]) or
    String.contains?(sender, ["noreply", "no-reply", "system", "admin", "alert"])
  end

  # Get AWS SES configuration set
  defp get_configuration_set(opts) do
    Keyword.get(opts, :configuration_set) || EmailTracking.get_ses_configuration_set()
  end

  # Build message tags for categorization
  defp build_message_tags(%Email{} = email, opts) do
    base_tags = Keyword.get(opts, :message_tags, %{})
    
    auto_tags = %{}
    
    # Add template tag if available
    auto_tags = 
      case Keyword.get(opts, :template_name) do
        nil -> auto_tags
        template -> Map.put(auto_tags, "template", template)
      end
    
    # Add campaign tag if available
    auto_tags = 
      case Keyword.get(opts, :campaign_id) do
        nil -> auto_tags
        campaign -> Map.put(auto_tags, "campaign", campaign)
      end
    
    # Add user context if available
    auto_tags = 
      case Keyword.get(opts, :user_id) do
        nil -> auto_tags
        user_id -> Map.put(auto_tags, "user_id", to_string(user_id))
      end
    
    # Add email type detection
    auto_tags = Map.put(auto_tags, "email_type", detect_email_type(email))
    
    Map.merge(auto_tags, base_tags)
  end

  # Build message tags for log record
  defp build_message_tags(log_or_email, opts) do
    build_message_tags(%Email{}, opts)  # Simplified for now
  end

  # Detect email type from content
  defp detect_email_type(%Email{} = email) do
    subject = String.downcase(email.subject || "")
    
    cond do
      String.contains?(subject, ["welcome", "confirm", "verify", "activate"]) -> "authentication"
      String.contains?(subject, ["reset", "password", "forgot"]) -> "password_reset"
      String.contains?(subject, ["newsletter", "update", "news"]) -> "newsletter"
      String.contains?(subject, ["invoice", "receipt", "payment", "billing"]) -> "transactional"
      String.contains?(subject, ["invitation", "invite"]) -> "invitation"
      true -> "general"
    end
  end

  # Check for SES specific headers
  defp has_ses_headers?(%Email{headers: headers}) when is_map(headers) do
    Map.has_key?(headers, "X-SES-CONFIGURATION-SET") or
    Enum.any?(headers, fn {key, _} -> String.starts_with?(key, "X-SES-") end)
  end
  defp has_ses_headers?(_), do: false

  # Check for SMTP headers
  defp has_smtp_headers?(%Email{headers: headers}) when is_map(headers) do
    Map.has_key?(headers, "X-SMTP-Server") or
    Map.has_key?(headers, "Received")
  end
  defp has_smtp_headers?(_), do: false

  # Detect provider from configuration
  defp detect_provider_from_config do
    # Try to detect from application configuration
    case PhoenixKit.Config.get(:mailer) do
      {:ok, mailer} when not is_nil(mailer) ->
        # Try to determine provider from mailer configuration
        config = Application.get_env(:phoenix_kit, mailer, [])
        adapter = Keyword.get(config, :adapter)
        
        case adapter do
          Swoosh.Adapters.AmazonSES -> "aws_ses"
          Swoosh.Adapters.SMTP -> "smtp"
          Swoosh.Adapters.Sendgrid -> "sendgrid"
          Swoosh.Adapters.Mailgun -> "mailgun"
          Swoosh.Adapters.Local -> "local"
          _ -> "unknown"
        end
        
      _ -> "unknown"
    end
  end

  # Extract data from provider response
  defp extract_provider_data(%{} = response) do
    # Extract message ID from SES response
    case response do
      %{"MessageId" => message_id} -> %{message_id: message_id}
      %{message_id: message_id} -> %{message_id: message_id}
      _ -> %{}
    end
  end
  defp extract_provider_data(_), do: %{}

  # Extract error message from various error formats
  defp extract_error_message({:error, reason}) when is_binary(reason), do: reason
  defp extract_error_message({:error, reason}) when is_atom(reason), do: to_string(reason)
  defp extract_error_message({:error, %{message: message}}) when is_binary(message), do: message
  defp extract_error_message(%{message: message}) when is_binary(message), do: message
  defp extract_error_message(error) when is_binary(error), do: error
  defp extract_error_message(error) when is_atom(error), do: to_string(error)
  defp extract_error_message(error), do: inspect(error)

  # Strip HTML tags from text (basic)
  defp strip_html_tags(html) when is_binary(html) do
    html
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/&[a-zA-Z0-9#]+;/, " ")
  end
  defp strip_html_tags(_), do: ""
end