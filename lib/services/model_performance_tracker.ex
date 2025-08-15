defmodule Services.ModelPerformanceTracker do
  @moduledoc """
  A GenServer that tracks AI model performance metrics during sessions.

  This service tracks request-level timing and token usage to help evaluate
  different model configurations and their effectiveness.
  """

  use GenServer

  defstruct [
    :session_id,
    :active_requests,
    :completed_requests
  ]

  @type tracking_id :: String.t()
  @type model :: AI.Model.t()
  @type usage_data :: map()

  @type request_data :: %{
          id: tracking_id(),
          model: model(),
          start_time: integer(),
          end_time: integer() | nil,
          usage: usage_data() | nil
        }

  @type t :: %__MODULE__{
          session_id: String.t(),
          active_requests: %{tracking_id() => request_data()},
          completed_requests: [request_data()]
        }

  # Client API

  @spec start_link() :: {:ok, pid()}
  def start_link do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec start_session() :: String.t()
  def start_session do
    GenServer.call(__MODULE__, :start_session)
  end

  @spec begin_tracking(model()) :: tracking_id()
  def begin_tracking(model) do
    GenServer.call(__MODULE__, {:begin_tracking, model})
  end

  @spec end_tracking(tracking_id(), usage_data()) :: :ok
  def end_tracking(tracking_id, usage_data) do
    GenServer.call(__MODULE__, {:end_tracking, tracking_id, usage_data})
  end

  @spec generate_report() :: String.t()
  def generate_report do
    GenServer.call(__MODULE__, :generate_report)
  end

  @spec reset_session() :: :ok
  def reset_session do
    GenServer.call(__MODULE__, :reset_session)
  end

  # Server Callbacks

  @impl GenServer
  def init(_args) do
    {:ok,
     %__MODULE__{
       session_id: generate_session_id(),
       active_requests: %{},
       completed_requests: []
     }}
  end

  @impl GenServer
  def handle_call(:start_session, _from, state) do
    new_session_id = generate_session_id()

    new_state = %{state | session_id: new_session_id, completed_requests: []}

    {:reply, new_session_id, new_state}
  end

  @impl GenServer
  def handle_call({:begin_tracking, model}, _from, state) do
    tracking_id = generate_tracking_id()

    request_data = %{
      id: tracking_id,
      model: model,
      start_time: System.monotonic_time(:millisecond),
      end_time: nil,
      usage: nil
    }

    new_active_requests = Map.put(state.active_requests, tracking_id, request_data)
    new_state = %{state | active_requests: new_active_requests}

    {:reply, tracking_id, new_state}
  end

  @impl GenServer
  def handle_call({:end_tracking, tracking_id, usage_data}, _from, state) do
    case Map.get(state.active_requests, tracking_id) do
      nil ->
        {:reply, :ok, state}

      request_data ->
        completed_request = %{
          request_data
          | end_time: System.monotonic_time(:millisecond),
            usage: usage_data
        }

        new_active_requests = Map.delete(state.active_requests, tracking_id)
        new_completed_requests = [completed_request | state.completed_requests]

        new_state = %{
          state
          | active_requests: new_active_requests,
            completed_requests: new_completed_requests
        }

        {:reply, :ok, new_state}
    end
  end

  @impl GenServer
  def handle_call(:generate_report, _from, state) do
    report = build_performance_report(state.completed_requests)
    {:reply, report, state}
  end

  @impl GenServer
  def handle_call(:reset_session, _from, state) do
    new_state = %{
      state
      | session_id: generate_session_id(),
        active_requests: %{},
        completed_requests: []
    }

    {:reply, :ok, new_state}
  end

  # Private Functions

  defp generate_session_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp generate_tracking_id do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end

  defp build_performance_report([]), do: ""

  defp build_performance_report(requests) do
    total_requests = length(requests)

    if total_requests == 0 do
      ""
    else
      model_stats = calculate_model_statistics(requests)
      overall_stats = calculate_overall_statistics(requests)

      """

      ### Model Performance Report

      **Session Summary:**
      - Total API Requests: #{total_requests}
      - Total Time: #{overall_stats.total_time_ms}ms
      - Total Tokens: #{overall_stats.total_tokens}

      #{format_model_breakdown(model_stats)}

      #{format_detailed_metrics(model_stats)}
      """
    end
  end

  defp calculate_overall_statistics(requests) do
    total_time_ms =
      requests
      |> Enum.map(fn req -> req.end_time - req.start_time end)
      |> Enum.sum()

    total_tokens =
      requests
      |> Enum.map(fn req -> get_total_tokens(req.usage) end)
      |> Enum.sum()

    %{
      total_time_ms: total_time_ms,
      total_tokens: total_tokens
    }
  end

  defp calculate_model_statistics(requests) do
    requests
    |> Enum.group_by(fn req ->
      %{
        model: req.model.model,
        reasoning: req.model.reasoning
      }
    end)
    |> Enum.map(fn {model_config, model_requests} ->
      total_time_ms =
        model_requests
        |> Enum.map(fn req -> req.end_time - req.start_time end)
        |> Enum.sum()

      request_count = length(model_requests)
      avg_time_ms = if request_count > 0, do: total_time_ms / request_count, else: 0

      total_input_tokens =
        model_requests
        |> Enum.map(fn req -> get_input_tokens(req.usage) end)
        |> Enum.sum()

      total_output_tokens =
        model_requests
        |> Enum.map(fn req -> get_output_tokens(req.usage) end)
        |> Enum.sum()

      total_reasoning_tokens =
        model_requests
        |> Enum.map(fn req -> get_reasoning_tokens(req.usage) end)
        |> Enum.sum()

      total_tokens = total_input_tokens + total_output_tokens + total_reasoning_tokens

      # Calculate tokens per minute
      total_time_minutes = total_time_ms / 1000 / 60

      tokens_per_minute =
        if total_time_minutes > 0, do: total_tokens / total_time_minutes, else: 0

      output_tokens_per_minute =
        if total_time_minutes > 0, do: total_output_tokens / total_time_minutes, else: 0

      # Calculate input token analysis
      input_analysis = calculate_input_analysis(model_requests)

      %{
        model_config: model_config,
        request_count: request_count,
        total_time_ms: total_time_ms,
        avg_time_ms: avg_time_ms,
        total_input_tokens: total_input_tokens,
        total_output_tokens: total_output_tokens,
        total_reasoning_tokens: total_reasoning_tokens,
        total_tokens: total_tokens,
        tokens_per_minute: tokens_per_minute,
        output_tokens_per_minute: output_tokens_per_minute,
        input_analysis: input_analysis
      }
    end)
    |> Enum.sort_by(fn stat ->
      {stat.model_config.model, reasoning_level_to_int(stat.model_config.reasoning)}
    end)
  end

  defp calculate_input_analysis(requests) do
    if length(requests) == 0 do
      %{
        avg_input_size: 0,
        input_processing_speed_ms_per_token: 0.0,
        scaling_analysis: %{},
        input_correlation: 0.0
      }
    else
      # Basic input metrics
      input_sizes = Enum.map(requests, fn req -> get_input_tokens(req.usage) end)
      processing_times = Enum.map(requests, fn req -> req.end_time - req.start_time end)

      avg_input_size = Enum.sum(input_sizes) / length(input_sizes)

      # Calculate input processing speed (ms per input token)
      total_input_tokens = Enum.sum(input_sizes)
      total_processing_time = Enum.sum(processing_times)

      input_processing_speed =
        if total_input_tokens > 0 do
          total_processing_time / total_input_tokens
        else
          0.0
        end

      # Input size bucketing analysis
      scaling_analysis = calculate_scaling_analysis(requests)

      # Calculate correlation between input size and processing time
      input_correlation = calculate_correlation(input_sizes, processing_times)

      %{
        avg_input_size: avg_input_size,
        input_processing_speed_ms_per_token: input_processing_speed,
        scaling_analysis: scaling_analysis,
        input_correlation: input_correlation
      }
    end
  end

  defp calculate_scaling_analysis(requests) do
    # Group requests by input size buckets
    buckets = %{
      # < 2000 tokens
      small: [],
      # 2000-10000 tokens  
      medium: [],
      # > 10000 tokens
      large: []
    }

    bucketed_requests =
      Enum.reduce(requests, buckets, fn req, acc ->
        input_tokens = get_input_tokens(req.usage)
        processing_time = req.end_time - req.start_time

        request_data = %{input_tokens: input_tokens, processing_time: processing_time}

        cond do
          input_tokens < 2000 ->
            %{acc | small: [request_data | acc.small]}

          input_tokens <= 10000 ->
            %{acc | medium: [request_data | acc.medium]}

          true ->
            %{acc | large: [request_data | acc.large]}
        end
      end)

    # Calculate metrics for each bucket
    bucket_stats = %{
      small: calculate_bucket_stats(bucketed_requests.small),
      medium: calculate_bucket_stats(bucketed_requests.medium),
      large: calculate_bucket_stats(bucketed_requests.large)
    }

    # Calculate scaling factors
    small_speed = bucket_stats.small.avg_processing_speed_ms_per_token
    medium_speed = bucket_stats.medium.avg_processing_speed_ms_per_token
    large_speed = bucket_stats.large.avg_processing_speed_ms_per_token

    scaling_factors = %{
      medium_vs_small: if(small_speed > 0, do: medium_speed / small_speed, else: 0.0),
      large_vs_small: if(small_speed > 0, do: large_speed / small_speed, else: 0.0),
      large_vs_medium: if(medium_speed > 0, do: large_speed / medium_speed, else: 0.0)
    }

    %{
      buckets: bucket_stats,
      scaling_factors: scaling_factors
    }
  end

  defp calculate_bucket_stats([]),
    do: %{
      count: 0,
      avg_input_size: 0,
      avg_processing_time: 0,
      avg_processing_speed_ms_per_token: 0.0
    }

  defp calculate_bucket_stats(bucket_data) do
    count = length(bucket_data)
    total_input = Enum.sum(Enum.map(bucket_data, & &1.input_tokens))
    total_time = Enum.sum(Enum.map(bucket_data, & &1.processing_time))

    avg_input_size = if count > 0, do: total_input / count, else: 0
    avg_processing_time = if count > 0, do: total_time / count, else: 0
    avg_processing_speed = if total_input > 0, do: total_time / total_input, else: 0.0

    %{
      count: count,
      avg_input_size: avg_input_size,
      avg_processing_time: avg_processing_time,
      avg_processing_speed_ms_per_token: avg_processing_speed
    }
  end

  defp calculate_correlation([], []), do: 0.0
  # Need at least 2 points
  defp calculate_correlation([_], [_]), do: 0.0

  defp calculate_correlation(x_values, y_values) when length(x_values) != length(y_values),
    do: 0.0

  defp calculate_correlation(x_values, y_values) do
    n = length(x_values)

    if n < 2 do
      0.0
    else
      # Calculate means
      x_mean = Enum.sum(x_values) / n
      y_mean = Enum.sum(y_values) / n

      # Calculate correlation coefficient
      numerator =
        Enum.zip(x_values, y_values)
        |> Enum.map(fn {x, y} -> (x - x_mean) * (y - y_mean) end)
        |> Enum.sum()

      x_variance =
        x_values
        |> Enum.map(fn x -> (x - x_mean) * (x - x_mean) end)
        |> Enum.sum()

      y_variance =
        y_values
        |> Enum.map(fn y -> (y - y_mean) * (y - y_mean) end)
        |> Enum.sum()

      denominator = :math.sqrt(x_variance * y_variance)

      if denominator > 0 do
        numerator / denominator
      else
        0.0
      end
    end
  end

  defp format_model_breakdown(model_stats) do
    if length(model_stats) <= 1 do
      ""
    else
      breakdown =
        model_stats
        |> Enum.map(fn stat ->
          "- #{format_model_name(stat.model_config)}: #{stat.request_count} requests, #{stat.total_time_ms}ms"
        end)
        |> Enum.join("\n")

      """
      **By Model:**
      #{breakdown}
      """
    end
  end

  defp format_detailed_metrics(model_stats) do
    model_stats
    |> Enum.map(fn stat ->
      input_analysis_text = format_input_analysis(stat.input_analysis)

      """
      **#{format_model_name(stat.model_config)}:**
      - Requests: #{stat.request_count}, Avg Input: #{format_number(stat.input_analysis.avg_input_size)} tokens
      - Avg Response Time: #{Float.round(stat.avg_time_ms, 1)}ms (#{Float.round(stat.input_analysis.input_processing_speed_ms_per_token, 2)}ms/token input)
      - Total Tokens: #{stat.total_tokens} (Input: #{stat.total_input_tokens}, Output: #{stat.total_output_tokens}#{format_reasoning_tokens(stat.total_reasoning_tokens)})
      - Throughput: #{Float.round(stat.tokens_per_minute, 1)} tokens/min (#{Float.round(stat.output_tokens_per_minute, 1)} output/min)#{input_analysis_text}
      """
    end)
    |> Enum.join("\n")
  end

  defp format_model_name(%{model: model, reasoning: reasoning}) do
    case reasoning do
      :none -> model
      reasoning_level -> "#{model} (reasoning: #{reasoning_level})"
    end
  end

  defp format_reasoning_tokens(0), do: ""
  defp format_reasoning_tokens(count), do: ", Reasoning: #{count}"

  defp format_input_analysis(%{
         scaling_analysis: scaling_analysis,
         input_correlation: correlation
       }) do
    scaling_text = format_scaling_analysis(scaling_analysis)
    correlation_text = format_correlation(correlation)

    case {scaling_text, correlation_text} do
      {"", ""} -> ""
      {scaling, ""} -> "\n#{scaling}"
      {"", corr} -> "\n#{corr}"
      {scaling, corr} -> "\n#{scaling}\n#{corr}"
    end
  end

  defp format_scaling_analysis(%{buckets: buckets, scaling_factors: factors}) do
    # Only show scaling analysis if we have meaningful data in multiple buckets
    bucket_counts = [
      buckets.small.count,
      buckets.medium.count,
      buckets.large.count
    ]

    active_buckets = Enum.count(bucket_counts, fn count -> count > 0 end)

    if active_buckets < 2 do
      ""
    else
      parts = []

      # Show bucket breakdown
      bucket_info =
        [
          if buckets.small.count > 0 do
            "Small (<2K): #{buckets.small.count} requests, #{Float.round(buckets.small.avg_processing_time, 0)}ms avg"
          end,
          if buckets.medium.count > 0 do
            "Medium (2-10K): #{buckets.medium.count} requests, #{Float.round(buckets.medium.avg_processing_time, 0)}ms avg"
          end,
          if buckets.large.count > 0 do
            "Large (>10K): #{buckets.large.count} requests, #{Float.round(buckets.large.avg_processing_time, 0)}ms avg"
          end
        ]
        |> Enum.filter(& &1)
        |> Enum.join(", ")

      parts =
        if bucket_info != "", do: ["- Input Size Analysis: #{bucket_info}" | parts], else: parts

      # Show most significant scaling factor
      {significant_factor, factor_value} =
        [
          {"Large vs Small", factors.large_vs_small},
          {"Large vs Medium", factors.large_vs_medium},
          {"Medium vs Small", factors.medium_vs_small}
        ]
        # Only show significant differences
        |> Enum.filter(fn {_name, value} -> value > 1.2 end)
        |> Enum.max_by(fn {_name, value} -> value end, fn -> {nil, 0.0} end)

      scaling_info =
        if significant_factor do
          "- Scaling Impact: #{significant_factor} inputs are #{Float.round(factor_value, 1)}x slower"
        else
          nil
        end

      parts = if scaling_info, do: [scaling_info | parts], else: parts

      if length(parts) > 0 do
        Enum.reverse(parts) |> Enum.join("\n")
      else
        ""
      end
    end
  end

  defp format_correlation(correlation) when correlation > 0.7 do
    "- Input Size Impact: Strong correlation (#{Float.round(correlation, 2)}) - larger inputs significantly slower"
  end

  defp format_correlation(correlation) when correlation > 0.4 do
    "- Input Size Impact: Moderate correlation (#{Float.round(correlation, 2)}) - some scaling effect observed"
  end

  defp format_correlation(_), do: ""

  defp format_number(num) when is_float(num), do: format_number(round(num))

  defp format_number(num) when num >= 1_000_000 do
    "#{Float.round(num / 1_000_000, 1)}M"
  end

  defp format_number(num) when num >= 1_000 do
    # Format with commas for readability
    num
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
    |> Enum.join(",")
  end

  defp format_number(num), do: Integer.to_string(num)

  # Convert reasoning levels to integers for sorting (least to most effort)
  defp reasoning_level_to_int(:none), do: 0
  defp reasoning_level_to_int(:minimal), do: 1
  defp reasoning_level_to_int(:low), do: 2
  defp reasoning_level_to_int(:medium), do: 3
  defp reasoning_level_to_int(:high), do: 4

  defp get_total_tokens(%{"total_tokens" => total}), do: total
  defp get_total_tokens(%{total_tokens: total}), do: total
  defp get_total_tokens(_), do: 0

  defp get_input_tokens(%{"prompt_tokens" => prompt}), do: prompt
  defp get_input_tokens(%{prompt_tokens: prompt}), do: prompt
  defp get_input_tokens(_), do: 0

  defp get_output_tokens(%{"completion_tokens" => completion}), do: completion
  defp get_output_tokens(%{completion_tokens: completion}), do: completion
  defp get_output_tokens(_), do: 0

  defp get_reasoning_tokens(%{"reasoning_tokens" => reasoning}), do: reasoning
  defp get_reasoning_tokens(%{reasoning_tokens: reasoning}), do: reasoning
  defp get_reasoning_tokens(_), do: 0
end
