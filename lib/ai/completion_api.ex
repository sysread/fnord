defmodule AI.CompletionAPI do
  @endpoint "https://api.openai.com/v1/chat/completions"

  @type model :: AI.Model.t()
  @type msgs :: [map()]
  @type tools :: nil | [AI.Tools.tool_spec()]
  @type response_format :: nil | map

  @type usage :: non_neg_integer
  @type msg_response :: {:ok, :msg, binary, usage}
  @type tool_response :: {:ok, :tool, list(map)}

  @type response ::
          msg_response
          | tool_response
          | {:error, map}
          | {:error, :api_unavailable}
          | {:error, :context_length_exceeded}

  @spec get(model, msgs, tools, response_format) :: response
  def get(model, msgs, tools \\ nil, response_format \\ nil) do
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
              {:error, %{message: msg}} = error ->
                UI.error("HTTP error while calling OpenAI API: #{msg}")
                IO.inspect(payload.messages |> Enum.slice(-1, 1), label: "Last message sent")
                error

              error ->
                error
            end

          {:ok, response} ->
            get_response(response, tracking_id)
        end
      rescue
        e in Jason.DecodeError ->
          {:error, %{http_status: 500, error: "JSON decode error: #{Exception.message(e)}"}}

        e in RuntimeError ->
          {:error, %{http_status: 500, error: "Runtime error: #{Exception.message(e)}"}}

        e ->
          {:error, %{http_status: 500, error: "Unexpected error: #{Exception.message(e)}"}}
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

  defp get_error({502, _}), do: {:error, :api_unavailable}
  defp get_error({503, _}), do: {:error, :api_unavailable}
  defp get_error({504, _}), do: {:error, :api_unavailable}

  defp get_error({http_status, json_error_string}) do
    json_error_string
    |> Jason.decode()
    |> case do
      {:ok, %{"error" => %{"code" => "context_length_exceeded"}}} ->
        {:error, :context_length_exceeded}

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
end
