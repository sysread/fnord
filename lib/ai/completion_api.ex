defmodule AI.CompletionAPI do
  @endpoint "https://api.openai.com/v1/chat/completions"

  @type model :: AI.Model.t()
  @type msgs :: [map()]
  @type tools :: nil | [AI.Tools.tool_spec()]
  @type response_format :: nil | map
  @type web_search? :: boolean

  @type usage :: non_neg_integer
  @type msg_response :: {:ok, :msg, binary, usage}
  @type tool_response :: {:ok, :tool, list(map)}

  @type response ::
          msg_response
          | tool_response
          | {:error, map}
          | {:error, :api_unavailable, any}
          | {:error, :context_length_exceeded, non_neg_integer}

  @spec get(model, msgs, tools, response_format, web_search?) :: response
  def get(model, msgs, tools \\ nil, response_format \\ nil, web_search? \\ false) do
    tracking_id = Services.ModelPerformanceTracker.begin_tracking(model)

    api_key = get_api_key!()

    response_format =
      if is_nil(response_format) do
        %{type: "text"}
      else
        response_format
      end

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    payload =
      %{
        model: model.model,
        messages: msgs,
        response_format: response_format
      }
      |> Map.merge(
        case tools do
          nil -> %{}
          tools -> %{tools: tools}
        end
      )
      |> Map.merge(
        case model.reasoning do
          :low -> %{reasoning_effort: "low"}
          :medium -> %{reasoning_effort: "medium"}
          :high -> %{reasoning_effort: "high"}
          _ -> %{}
        end
      )
      |> Map.merge(
        if web_search? do
          %{web_search_options: %{}}
        else
          %{}
        end
      )

    result =
      try do
        Http.post_json(@endpoint, headers, payload)
        |> case do
          {:transport_error, error} ->
            get_error(error)

          {:http_error, error} ->
            error
            |> get_error()
            |> case do
              {:error, %{message: msg}} ->
                UI.error("HTTP error while calling OpenAI API: #{msg}")
                {:error, %{message: msg}}

              error ->
                error
            end

          {:ok, response} ->
            get_response(response, tracking_id)
        end
      rescue
        e in Jason.DecodeError ->
          {:error,
           %{
             http_status: 500,
             error: """
             JSON decode error: #{Exception.message(e)}
             #{Exception.format_stacktrace(__STACKTRACE__)}
             """
           }}

        e in RuntimeError ->
          {:error,
           %{
             http_status: 500,
             error: """
             Runtime error: #{Exception.message(e)}
             #{Exception.format_stacktrace(__STACKTRACE__)}
             """
           }}

        e ->
          {:error,
           %{
             http_status: 500,
             error: """
             Unexpected error: #{Exception.message(e)}
             #{Exception.format_stacktrace(__STACKTRACE__)}
             """
           }}
      end

    # Handle error cases for tracking
    case result do
      {:error, _} ->
        Services.ModelPerformanceTracker.end_tracking(tracking_id, %{})

      _ ->
        # Success cases are already handled in get_response functions
        :ok
    end

    result
  end

  # -----------------------------------------------------------------------------
  # Private functions
  # -----------------------------------------------------------------------------
  @spec get_api_key!() :: binary
  defp get_api_key!() do
    ["FNORD_OPENAI_API_KEY", "OPENAI_API_KEY"]
    |> Enum.find_value(&System.get_env(&1, nil))
    |> case do
      nil ->
        raise "Either FNORD_OPENAI_API_KEY or OPENAI_API_KEY environment variable must be set"

      api_key ->
        api_key
    end
  end

  defp get_response(
         %{
           "choices" => [%{"message" => response}],
           "usage" => usage
         },
         tracking_id
       ) do
    response
    |> Map.put("usage", usage)
    |> get_response(tracking_id)
  end

  defp get_response(%{"tool_calls" => tool_calls}, tracking_id) do
    # Track tool calls with empty usage data
    Services.ModelPerformanceTracker.end_tracking(tracking_id, %{})
    {:ok, :tool, Enum.map(tool_calls, &get_tool_call/1)}
  end

  defp get_response(%{"content" => response, "usage" => usage}, tracking_id) do
    # Track the full usage data for performance metrics
    Services.ModelPerformanceTracker.end_tracking(tracking_id, usage)
    # Return total_tokens for backward compatibility
    total_tokens = Map.get(usage, "total_tokens", 0)
    {:ok, :msg, response, total_tokens}
  end

  defp get_tool_call(%{"id" => id, "function" => %{"name" => name, "arguments" => args}}) do
    %{id: id, function: %{name: name, arguments: args}}
  end

  defp get_error(:closed), do: {:error, "Connection closed"}
  defp get_error(:timeout), do: {:error, "Connection timed out"}
  defp get_error(:invalid_json_response), do: {:error, "Invalid JSON response"}

  defp get_error({502, reason}), do: {:error, :api_unavailable, reason}
  defp get_error({503, reason}), do: {:error, :api_unavailable, reason}
  defp get_error({504, reason}), do: {:error, :api_unavailable, reason}

  defp get_error({http_status, json_error_string}) do
    json_error_string
    |> Jason.decode()
    |> case do
      {:ok, %{"error" => %{"message" => msg, "code" => "context_length_exceeded"}}} ->
        ~r/Your messages resulted in (\d+) tokens/
        |> Regex.run(msg)
        |> case do
          nil -> {:error, :context_length_exceeded, -1}
          [_, used] -> {:error, :context_length_exceeded, String.to_integer(used)}
        end

      {:ok, %{"error" => %{"code" => code, "message" => msg}}} ->
        {:error,
         %{
           http_status: http_status,
           code: code,
           message: msg
         }}

      {:ok, error} ->
        {:error,
         %{
           http_status: http_status,
           error: inspect(error, pretty: true)
         }}

      {:error, _} ->
        {:error,
         %{
           http_status: http_status,
           error: json_error_string
         }}
    end
  end

  defp get_error(other), do: {:error, inspect(other, pretty: true)}
end
