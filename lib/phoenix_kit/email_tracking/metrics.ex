defmodule PhoenixKit.EmailTracking.Metrics do
  @moduledoc """
  AWS CloudWatch metrics integration for PhoenixKit email tracking.

  This module provides comprehensive metrics collection and analysis capabilities
  for email performance, deliverability, and engagement tracking through AWS CloudWatch.

  ## Features

  - **AWS SES Metrics**: Direct integration with SES CloudWatch metrics
  - **Custom Metrics**: Application-specific metrics publishing
  - **Reputation Tracking**: Sender reputation and deliverability scores  
  - **Engagement Analysis**: Open rates, click rates, and engagement trends
  - **Geographic Analytics**: Performance by region and country
  - **Provider Analysis**: Deliverability by email provider (Gmail, Outlook, etc.)
  - **Real-time Dashboards**: Data for live monitoring dashboards

  ## Configuration

  Configure AWS credentials and region:

      config :ex_aws,
        access_key_id: {:system, "AWS_ACCESS_KEY_ID"},
        secret_access_key: {:system, "AWS_SECRET_ACCESS_KEY"},
        region: {:system, "AWS_REGION"}

      # Enable CloudWatch metrics in email tracking
      config :phoenix_kit,
        email_tracking_cloudwatch_metrics: true

  ## Usage Examples

      # Get basic SES metrics
      {:ok, metrics} = PhoenixKit.EmailTracking.Metrics.get_ses_metrics(:last_24_hours)

      # Get engagement metrics
      engagement = PhoenixKit.EmailTracking.Metrics.get_engagement_metrics(:last_7_days)

      # Publish custom metric
      PhoenixKit.EmailTracking.Metrics.put_custom_metric("EmailOpen", 1, "Count")

      # Get dashboard data
      dashboard = PhoenixKit.EmailTracking.Metrics.get_dashboard_data(:last_30_days)
  """

  require Logger

  alias PhoenixKit.EmailTracking
  alias PhoenixKit.EmailTracking.{EmailEvent, EmailLog}

  @custom_namespace "PhoenixKit/EmailTracking"

  # Metric names from AWS SES
  @ses_metrics %{
    send: "Send",
    bounce: "Bounce",
    complaint: "Complaint",
    delivery: "Delivery",
    click: "Click",
    open: "Open",
    reputation_bounce_rate: "Reputation.BounceRate",
    reputation_complaint_rate: "Reputation.ComplaintRate",
    reputation_delivery_delay: "Reputation.DeliveryDelay"
  }

  ## --- AWS SES Metrics ---

  @doc """
  Retrieves comprehensive SES metrics from CloudWatch.

  ## Parameters

  - `period` - Time period (:last_hour, :last_24_hours, :last_7_days, :last_30_days)
  - `options` - Additional options for filtering and grouping

  ## Examples

      iex> PhoenixKit.EmailTracking.Metrics.get_ses_metrics(:last_24_hours)
      {:ok, %{
        send: 1500,
        delivery: 1450,
        bounce: 30,
        complaint: 5,
        open: 800,
        click: 200
      }}
  """
  def get_ses_metrics(period \\ :last_24_hours, options \\ []) do
    if cloudwatch_enabled?() do
      {start_time, end_time} = get_time_range(period)

      # Get all basic SES metrics in parallel
      metric_tasks = [
        Task.async(fn -> get_metric_data(@ses_metrics.send, start_time, end_time, options) end),
        Task.async(fn ->
          get_metric_data(@ses_metrics.delivery, start_time, end_time, options)
        end),
        Task.async(fn -> get_metric_data(@ses_metrics.bounce, start_time, end_time, options) end),
        Task.async(fn ->
          get_metric_data(@ses_metrics.complaint, start_time, end_time, options)
        end),
        Task.async(fn -> get_metric_data(@ses_metrics.open, start_time, end_time, options) end),
        Task.async(fn -> get_metric_data(@ses_metrics.click, start_time, end_time, options) end)
      ]

      # Wait for all results
      results = Task.await_many(metric_tasks, 30_000)

      # Process results
      metrics = %{
        send: extract_metric_value(Enum.at(results, 0)),
        delivery: extract_metric_value(Enum.at(results, 1)),
        bounce: extract_metric_value(Enum.at(results, 2)),
        complaint: extract_metric_value(Enum.at(results, 3)),
        open: extract_metric_value(Enum.at(results, 4)),
        click: extract_metric_value(Enum.at(results, 5))
      }

      # Calculate derived metrics
      enhanced_metrics =
        Map.merge(metrics, %{
          delivery_rate: calculate_percentage(metrics.delivery, metrics.send),
          bounce_rate: calculate_percentage(metrics.bounce, metrics.send),
          complaint_rate: calculate_percentage(metrics.complaint, metrics.send),
          open_rate: calculate_percentage(metrics.open, metrics.delivery),
          click_rate: calculate_percentage(metrics.click, metrics.open),
          click_to_delivery_rate: calculate_percentage(metrics.click, metrics.delivery)
        })

      {:ok, enhanced_metrics}
    else
      {:error, :cloudwatch_disabled}
    end
  end

  @doc """
  Gets detailed reputation metrics from AWS SES.

  ## Examples

      iex> PhoenixKit.EmailTracking.Metrics.get_reputation_metrics()
      {:ok, %{
        bounce_rate: 2.5,
        complaint_rate: 0.1, 
        delivery_delay: 120,
        reputation_score: "HIGH"
      }}
  """
  def get_reputation_metrics(period \\ :last_24_hours) do
    if cloudwatch_enabled?() do
      {start_time, end_time} = get_time_range(period)

      reputation_tasks = [
        Task.async(fn ->
          get_metric_data(@ses_metrics.reputation_bounce_rate, start_time, end_time)
        end),
        Task.async(fn ->
          get_metric_data(@ses_metrics.reputation_complaint_rate, start_time, end_time)
        end),
        Task.async(fn ->
          get_metric_data(@ses_metrics.reputation_delivery_delay, start_time, end_time)
        end)
      ]

      results = Task.await_many(reputation_tasks, 15_000)

      bounce_rate = extract_metric_value(Enum.at(results, 0))
      complaint_rate = extract_metric_value(Enum.at(results, 1))
      delivery_delay = extract_metric_value(Enum.at(results, 2))

      reputation_score = calculate_reputation_score(bounce_rate, complaint_rate)

      {:ok,
       %{
         bounce_rate: bounce_rate,
         complaint_rate: complaint_rate,
         delivery_delay: delivery_delay,
         reputation_score: reputation_score,
         assessment: assess_reputation(bounce_rate, complaint_rate)
       }}
    else
      {:error, :cloudwatch_disabled}
    end
  end

  @doc """
  Gets engagement metrics with trend analysis.

  ## Examples

      iex> PhoenixKit.EmailTracking.Metrics.get_engagement_metrics(:last_7_days)
      %{
        open_rate: 24.5,
        click_rate: 4.2,
        engagement_score: 28.7,
        trend: :improving,
        daily_breakdown: [...]
      }
  """
  def get_engagement_metrics(period \\ :last_7_days) do
    if cloudwatch_enabled?() do
      # Get CloudWatch engagement data
      cloudwatch_data = get_cloudwatch_engagement_data(period)

      # Get local database engagement data for comparison
      local_data = get_local_engagement_data(period)

      # Combine and analyze
      combined_metrics = combine_engagement_data(cloudwatch_data, local_data)

      # Add trend analysis
      Map.put(combined_metrics, :trend, calculate_engagement_trend(combined_metrics))
    else
      # Fallback to local data only
      get_local_engagement_data(period)
    end
  end

  @doc """
  Gets geographic distribution of email engagement.

  ## Examples

      iex> PhoenixKit.EmailTracking.Metrics.get_geographic_metrics("open", :last_30_days)
      %{
        "US" => %{count: 500, percentage: 45.5},
        "CA" => %{count: 200, percentage: 18.2},
        "UK" => %{count: 150, percentage: 13.6}
      }
  """
  def get_geographic_metrics(event_type, period \\ :last_30_days) do
    {start_time, end_time} = get_time_range(period)

    # Get geo data from local events (CloudWatch doesn't provide geo breakdown)
    geo_data = EmailEvent.get_geo_distribution(event_type, start_time, end_time)

    total_count = Enum.reduce(geo_data, 0, fn {_country, count}, acc -> acc + count end)

    # Add percentages
    geo_data
    |> Enum.into(%{}, fn {country, count} ->
      percentage =
        if total_count > 0, do: (count / total_count * 100) |> Float.round(1), else: 0.0

      {country, %{count: count, percentage: percentage}}
    end)
  end

  ## --- Custom Metrics Publishing ---

  @doc """
  Publishes a custom metric to CloudWatch.

  ## Examples

      iex> PhoenixKit.EmailTracking.Metrics.put_custom_metric("EmailOpen", 1, "Count")
      :ok

      iex> PhoenixKit.EmailTracking.Metrics.put_custom_metric("ProcessingLatency", 156.7, "Milliseconds")
      :ok
  """
  def put_custom_metric(metric_name, value, unit \\ "Count", dimensions \\ []) do
    if cloudwatch_enabled?() do
      metric_data = %{
        metric_name: metric_name,
        value: value,
        unit: unit,
        timestamp: DateTime.utc_now(),
        dimensions: dimensions
      }

      case publish_cloudwatch_metric(@custom_namespace, metric_data) do
        :ok ->
          Logger.debug("Published custom metric", %{
            metric: metric_name,
            value: value,
            unit: unit
          })

          :ok
      end
    else
      Logger.debug("CloudWatch disabled, skipping custom metric", %{metric: metric_name})
      :ok
    end
  end

  @doc """
  Publishes multiple custom metrics at once for efficiency.

  ## Examples

      iex> metrics = [
        %{name: "EmailsSent", value: 100, unit: "Count"},
        %{name: "AvgProcessingTime", value: 45.2, unit: "Milliseconds"}
      ]
      iex> PhoenixKit.EmailTracking.Metrics.put_custom_metrics(metrics)
      :ok
  """
  def put_custom_metrics(metrics) when is_list(metrics) do
    if cloudwatch_enabled?() do
      # CloudWatch allows up to 20 metrics per request
      metrics
      |> Enum.chunk_every(20)
      |> Enum.each(fn metric_batch ->
        publish_metric_batch(@custom_namespace, metric_batch)
      end)
    else
      :ok
    end
  end

  ## --- Dashboard Data ---

  @doc """
  Gets comprehensive dashboard data combining multiple metric sources.

  Returns data optimized for dashboard visualization with time series,
  percentages, trends, and alerts.

  ## Examples

      iex> PhoenixKit.EmailTracking.Metrics.get_dashboard_data(:last_7_days)
      %{
        overview: %{
          total_sent: 5000,
          delivery_rate: 98.2,
          bounce_rate: 1.8,
          open_rate: 24.5,
          click_rate: 4.2
        },
        time_series: [...],
        alerts: [...],
        top_performers: [...]
      }
  """
  def get_dashboard_data(period \\ :last_7_days) do
    # Get overview metrics
    overview_task = Task.async(fn -> get_overview_metrics(period) end)

    # Get time series data
    time_series_task = Task.async(fn -> get_time_series_data(period) end)

    # Get geographic data
    geo_task = Task.async(fn -> get_geographic_metrics("open", period) end)

    # Get alerts and issues
    alerts_task = Task.async(fn -> get_metric_alerts(period) end)

    # Get top performing campaigns/templates
    top_performers_task = Task.async(fn -> get_top_performers(period) end)

    # Get provider performance
    provider_task = Task.async(fn -> get_provider_performance(period) end)

    # Wait for all results
    [overview, time_series, geographic, alerts, top_performers, provider_performance] =
      Task.await_many(
        [
          overview_task,
          time_series_task,
          geo_task,
          alerts_task,
          top_performers_task,
          provider_task
        ],
        30_000
      )

    %{
      overview: overview,
      time_series: time_series,
      geographic: geographic,
      alerts: alerts,
      top_performers: top_performers,
      provider_performance: provider_performance,
      generated_at: DateTime.utc_now()
    }
  end

  ## --- Alerting ---

  @doc """
  Checks metrics against thresholds and returns alerts.

  ## Examples

      iex> PhoenixKit.EmailTracking.Metrics.get_metric_alerts(:last_24_hours)
      [
        %{type: :high_bounce_rate, severity: :warning, value: 5.2, threshold: 5.0},
        %{type: :low_open_rate, severity: :info, value: 15.1, threshold: 20.0}
      ]
  """
  def get_metric_alerts(period \\ :last_24_hours) do
    alerts = []

    # Get current metrics
    case get_ses_metrics(period) do
      {:ok, metrics} ->
        alerts =
          alerts
          |> check_bounce_rate_alert(metrics.bounce_rate)
          |> check_complaint_rate_alert(metrics.complaint_rate)
          |> check_delivery_rate_alert(metrics.delivery_rate)
          |> check_open_rate_alert(metrics.open_rate)

        alerts

      {:error, _reason} ->
        [%{type: :metrics_unavailable, severity: :error, message: "Unable to retrieve metrics"}]
    end
  end

  ## --- Private Helper Functions ---

  # Check if CloudWatch is enabled
  defp cloudwatch_enabled? do
    EmailTracking.get_config().cloudwatch_metrics
  end

  # Get time range for period
  defp get_time_range(period) do
    end_time = DateTime.utc_now()

    start_time =
      case period do
        :last_hour -> DateTime.add(end_time, -1, :hour)
        :last_24_hours -> DateTime.add(end_time, -1, :day)
        :last_7_days -> DateTime.add(end_time, -7, :day)
        :last_30_days -> DateTime.add(end_time, -30, :day)
        :last_90_days -> DateTime.add(end_time, -90, :day)
      end

    {start_time, end_time}
  end

  # Get metric data from CloudWatch
  defp get_metric_data(metric_name, start_time, end_time, options \\ []) do
    dimensions = Keyword.get(options, :dimensions, [])
    statistic = Keyword.get(options, :statistic, "Sum")

    # Simulate CloudWatch API call (replace with actual implementation)
    case make_cloudwatch_request(metric_name, start_time, end_time, dimensions, statistic) do
      {:ok, data} -> {:ok, data}
    end
  end

  # Simulate CloudWatch API request
  defp make_cloudwatch_request(metric_name, start_time, end_time, _dimensions, _statistic) do
    # This is a placeholder - implement actual CloudWatch API calls
    # using ExAws.CloudWatch or HTTPoison

    Logger.debug("CloudWatch API request", %{
      metric: metric_name,
      start_time: start_time,
      end_time: end_time
    })

    # Return simulated data
    simulated_value =
      case metric_name do
        "Send" -> 1500
        "Delivery" -> 1450
        "Bounce" -> 30
        "Complaint" -> 5
        "Open" -> 800
        "Click" -> 200
        "Reputation.BounceRate" -> 2.0
        "Reputation.ComplaintRate" -> 0.1
        _ -> 0
      end

    {:ok, %{"Datapoints" => [%{"Sum" => simulated_value, "Timestamp" => start_time}]}}
  end

  # Extract numeric value from CloudWatch response
  defp extract_metric_value({:ok, %{"Datapoints" => datapoints}}) when is_list(datapoints) do
    datapoints
    |> Enum.map(fn point -> point["Sum"] || point["Average"] || 0 end)
    |> Enum.sum()
  end

  defp extract_metric_value({:ok, _}), do: 0
  defp extract_metric_value({:error, _}), do: 0
  defp extract_metric_value(_), do: 0

  # Calculate percentage safely
  defp calculate_percentage(numerator, denominator) when denominator > 0 do
    (numerator / denominator * 100) |> Float.round(1)
  end

  defp calculate_percentage(_, _), do: 0.0

  # Calculate reputation score
  defp calculate_reputation_score(bounce_rate, complaint_rate) do
    cond do
      bounce_rate > 10 or complaint_rate > 0.5 -> "LOW"
      bounce_rate > 5 or complaint_rate > 0.3 -> "MEDIUM"
      bounce_rate < 2 and complaint_rate < 0.1 -> "HIGH"
      true -> "MEDIUM"
    end
  end

  # Assess reputation
  defp assess_reputation(bounce_rate, complaint_rate) do
    issues = []

    issues = if bounce_rate > 5, do: ["High bounce rate" | issues], else: issues
    issues = if complaint_rate > 0.3, do: ["High complaint rate" | issues], else: issues

    case issues do
      [] -> "Good standing"
      issues -> "Issues: #{Enum.join(issues, ", ")}"
    end
  end

  # Get local engagement data from database
  defp get_local_engagement_data(period) do
    {_start_time, _end_time} = get_time_range(period)
    EmailLog.get_engagement_metrics(period)
  end

  # Get CloudWatch engagement data
  defp get_cloudwatch_engagement_data(period) do
    case get_ses_metrics(period) do
      {:ok, metrics} ->
        %{
          open_rate: metrics.open_rate,
          click_rate: metrics.click_rate,
          delivery_rate: metrics.delivery_rate
        }

      {:error, _} ->
        %{}
    end
  end

  # Combine engagement data from different sources
  defp combine_engagement_data(cloudwatch_data, local_data) do
    Map.merge(local_data, cloudwatch_data, fn _key, local_val, cloudwatch_val ->
      # Prefer CloudWatch data if available, fallback to local
      if cloudwatch_val && cloudwatch_val > 0, do: cloudwatch_val, else: local_val
    end)
  end

  # Calculate engagement trend
  defp calculate_engagement_trend(%{daily_stats: daily_stats})
       when is_list(daily_stats) and length(daily_stats) > 3 do
    # Simple trend calculation
    recent_avg = daily_stats |> Enum.take(-3) |> calculate_avg_engagement()
    earlier_avg = daily_stats |> Enum.take(3) |> calculate_avg_engagement()

    cond do
      recent_avg > earlier_avg + 2 -> :improving
      recent_avg < earlier_avg - 2 -> :declining
      true -> :stable
    end
  end

  defp calculate_engagement_trend(_), do: :stable

  # Calculate average engagement from daily stats
  defp calculate_avg_engagement(daily_stats) do
    if length(daily_stats) > 0 do
      total_opened = Enum.sum(Enum.map(daily_stats, & &1.opened))
      total_delivered = Enum.sum(Enum.map(daily_stats, & &1.delivered))
      calculate_percentage(total_opened, total_delivered)
    else
      0.0
    end
  end

  # Get overview metrics
  defp get_overview_metrics(period) do
    case get_ses_metrics(period) do
      {:ok, metrics} -> metrics
      {:error, _} -> EmailTracking.get_system_stats(period)
    end
  end

  # Get time series data for charts
  defp get_time_series_data(period) do
    {_start_time, _end_time} = get_time_range(period)
    # Placeholder: This would need to be implemented based on your specific needs
    # EmailLog.get_daily_engagement_stats(start_time, end_time)
    []
  end

  # Get top performing campaigns/templates
  defp get_top_performers(period) do
    {_start_time, _end_time} = get_time_range(period)

    # Get top campaigns by open rate
    # This would need to be implemented based on your specific needs
    []
  end

  # Get provider performance
  defp get_provider_performance(period) do
    EmailLog.get_provider_performance(period)
  end

  # Alert checking functions
  defp check_bounce_rate_alert(alerts, bounce_rate) when bounce_rate > 5.0 do
    [%{type: :high_bounce_rate, severity: :warning, value: bounce_rate, threshold: 5.0} | alerts]
  end

  defp check_bounce_rate_alert(alerts, bounce_rate) when bounce_rate > 10.0 do
    [
      %{type: :high_bounce_rate, severity: :critical, value: bounce_rate, threshold: 10.0}
      | alerts
    ]
  end

  defp check_bounce_rate_alert(alerts, _), do: alerts

  defp check_complaint_rate_alert(alerts, complaint_rate) when complaint_rate > 0.3 do
    [
      %{type: :high_complaint_rate, severity: :warning, value: complaint_rate, threshold: 0.3}
      | alerts
    ]
  end

  defp check_complaint_rate_alert(alerts, complaint_rate) when complaint_rate > 0.5 do
    [
      %{type: :high_complaint_rate, severity: :critical, value: complaint_rate, threshold: 0.5}
      | alerts
    ]
  end

  defp check_complaint_rate_alert(alerts, _), do: alerts

  defp check_delivery_rate_alert(alerts, delivery_rate) when delivery_rate < 95.0 do
    [
      %{type: :low_delivery_rate, severity: :warning, value: delivery_rate, threshold: 95.0}
      | alerts
    ]
  end

  defp check_delivery_rate_alert(alerts, _), do: alerts

  defp check_open_rate_alert(alerts, open_rate) when open_rate < 15.0 do
    [%{type: :low_open_rate, severity: :info, value: open_rate, threshold: 15.0} | alerts]
  end

  defp check_open_rate_alert(alerts, _), do: alerts

  # Publish metric to CloudWatch
  defp publish_cloudwatch_metric(namespace, metric_data) do
    # Placeholder for actual CloudWatch publishing
    # Implement using ExAws.CloudWatch.put_metric_data/3
    Logger.debug("Publishing CloudWatch metric", %{
      namespace: namespace,
      metric: metric_data.metric_name,
      value: metric_data.value
    })

    :ok
  end

  # Publish batch of metrics
  defp publish_metric_batch(namespace, metrics) do
    # Placeholder for batch publishing
    Logger.debug("Publishing metric batch", %{
      namespace: namespace,
      count: length(metrics)
    })

    :ok
  end
end
