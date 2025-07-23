defmodule AI.CompletionAPI do
  @endpoint "https://api.openai.com/v1/chat/completions"

  @type model :: AI.Model.t()
  @type msgs :: [map()]
  @type tools :: nil | [AI.Tools.tool_spec()]

  @type usage :: integer()
  @type msg_response :: {:ok, :msg, binary, usage}
  @type tool_response :: {:ok, :tool, list(map())}

  @type response ::
          msg_response
          | tool_response
          | {:error, map}
          | {:error, :context_length_exceeded}

  @spec get(model, msgs, tools) :: response
  def get(model, msgs, tools \\ nil) do
    api_key = get_api_key!()

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    payload =
      %{
        model: model.model,
        messages: msgs,
        response_format: %{type: "text"}
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
        get_response(response)
    end
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

  defp get_response(%{
         "choices" => [%{"message" => response}],
         "usage" => %{"total_tokens" => usage}
       }) do
    response
    |> Map.put("usage", usage)
    |> get_response()
  end

  defp get_response(%{"tool_calls" => tool_calls}) do
    {:ok, :tool, Enum.map(tool_calls, &get_tool_call/1)}
  end

  defp get_response(%{"content" => response, "usage" => usage}) do
    {:ok, :msg, response, usage}
  end

  defp get_tool_call(%{"id" => id, "function" => %{"name" => name, "arguments" => args}}) do
    %{id: id, function: %{name: name, arguments: args}}
  end

  defp get_error(:closed), do: {:error, "Connection closed"}
  defp get_error(:timeout), do: {:error, "Connection timed out"}

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
