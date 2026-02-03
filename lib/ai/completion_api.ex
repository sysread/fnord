defmodule AI.CompletionAPI do
  @behaviour AI.Endpoint
  @base_url "https://api.openai.com"

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
          | {:error, binary}
          | {:error, :api_unavailable, any}
          | {:error, :context_length_exceeded, non_neg_integer}

  @impl AI.Endpoint
  def endpoint_path, do: "#{@base_url}/v1/chat/completions"

  @spec get(model, msgs, tools, response_format, web_search?) :: response
  def get(model, msgs, tools \\ nil, response_format \\ nil, web_search? \\ false) do
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
        case model.verbosity do
          :low -> %{verbosity: "low"}
          :medium -> %{verbosity: "medium"}
          :high -> %{verbosity: "high"}
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
        AI.Endpoint.post_json(__MODULE__, headers, payload)
        |> case do
          {:transport_error, error} ->
            get_error(error)

          {:http_error, error} ->
            case get_error(error) do
              {:error, :context_length_exceeded, _usage} = err ->
                err

              {:error, %{message: msg}} ->
                UI.error("HTTP error while calling OpenAI API: #{msg}")
                {:error, %{message: msg}}

              other ->
                other
            end

          {:ok, %{body: response} = _payload} ->
            get_response(response)
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

  defp get_response(%{"choices" => [%{"message" => response}], "usage" => usage}) do
    response
    |> Map.put("usage", usage)
    |> get_response()
  end

  defp get_response(%{"tool_calls" => tool_calls}) do
    {:ok, :tool, Enum.map(tool_calls, &get_tool_call/1)}
  end

  defp get_response(%{"content" => response, "usage" => usage}) do
    # Return total_tokens for backward compatibility
    total_tokens = Map.get(usage, "total_tokens", 0)
    {:ok, :msg, response, total_tokens}
  end

  # Fallback clause for unexpected response shapes
  defp get_response(unexpected) do
    {:error,
     %{
       http_status: 500,
       error: "Unexpected response #{inspect(unexpected)}"
     }}
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

  # Catch-all for non-tuple errors: convert to binary
  defp get_error(other) when not is_tuple(other), do: {:error, to_string(other)}

  # Catch-all for other error tuples: inspect for debugging
  defp get_error(other), do: {:error, inspect(other, pretty: true)}
end
