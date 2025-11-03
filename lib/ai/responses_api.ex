defmodule AI.ResponsesAPI do
  @moduledoc """
  OpenAI Responses API client with tuple parity to `AI.CompletionAPI`.
  """

  @endpoint "https://api.openai.com/v1/responses"

  @type model :: AI.Model.t()
  @type msgs :: [map()]
  @type tools :: nil | [AI.Tools.tool_spec()]
  @type response_format :: nil | map
  @type web_search? :: boolean

  @type usage :: non_neg_integer
  @type msg_response :: {:ok, :msg, binary, usage}
  @type tool_response :: {:ok, :tool, list(map())}

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
          t -> %{tools: t}
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
      |> Map.merge(if web_search?, do: %{web_search_options: %{}}, else: %{})

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
              {:error, %{message: msg}} = err ->
                UI.error("HTTP error while calling OpenAI Responses API: #{msg}")
                IO.inspect(payload[:messages] |> Enum.slice(-1, 1), label: "Last message sent")
                err

              err ->
                err
            end

          {:ok, response} ->
            get_response(response, tracking_id)
        end
      rescue
        e in Jason.DecodeError ->
          {:error,
           %{
             http_status: 500,
             error:
               "JSON decode error: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
           }}

        e in RuntimeError ->
          {:error,
           %{
             http_status: 500,
             error:
               "Runtime error: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
           }}

        e ->
          {:error,
           %{
             http_status: 500,
             error:
               "Unexpected error: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
           }}
      end

    case result do
      {:error, _} -> Services.ModelPerformanceTracker.end_tracking(tracking_id, %{})
      _ -> :ok
    end

    result
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

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

  defp get_response(%{"output" => output, "usage" => usage}, tracking_id) when is_list(output) do
    tool_calls =
      output
      |> Enum.filter(&match?(%{"type" => "tool_call"}, &1))
      |> Enum.map(&to_tool_call/1)

    if tool_calls != [] do
      Services.ModelPerformanceTracker.end_tracking(tracking_id, %{})
      {:ok, :tool, tool_calls}
    else
      text = extract_output_text(output) || ""
      Services.ModelPerformanceTracker.end_tracking(tracking_id, usage)
      total_tokens = Map.get(usage, "total_tokens", 0)
      {:ok, :msg, text, total_tokens}
    end
  end

  defp get_response(%{"output_text" => text, "usage" => usage}, tracking_id)
       when is_binary(text) do
    Services.ModelPerformanceTracker.end_tracking(tracking_id, usage)
    total_tokens = Map.get(usage, "total_tokens", 0)
    {:ok, :msg, text, total_tokens}
  end

  # Compatibility fallback if proxied response looks like chat-completions
  defp get_response(%{"choices" => [%{"message" => response}], "usage" => usage}, tracking_id) do
    Services.ModelPerformanceTracker.end_tracking(tracking_id, usage)
    total_tokens = Map.get(usage, "total_tokens", 0)
    {:ok, :msg, Map.get(response, "content", ""), total_tokens}
  end

  defp get_response(other, _tracking_id) do
    {:error, %{http_status: 500, error: inspect(other, pretty: true)}}
  end

  defp to_tool_call(%{"type" => "tool_call", "id" => id, "name" => name, "arguments" => args}) do
    %{id: id, function: %{name: name, arguments: args}}
  end

  defp extract_output_text(output) do
    output
    |> Enum.find_value(fn
      %{"type" => "output_text", "text" => t} when is_binary(t) -> t
      %{"type" => "message", "content" => t} when is_binary(t) -> t
      %{"type" => "message", "content" => [%{"type" => "text", "text" => t} | _]} -> t
      _ -> nil
    end)
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
        case Regex.run(~r/Your messages resulted in (\d+) tokens/, msg) do
          nil -> {:error, :context_length_exceeded, -1}
          [_, used] -> {:error, :context_length_exceeded, String.to_integer(used)}
        end

      {:ok, %{"error" => %{"code" => code, "message" => msg}}} ->
        {:error, %{http_status: http_status, code: code, message: msg}}

      {:ok, error} ->
        {:error, %{http_status: http_status, error: inspect(error, pretty: true)}}

      {:error, _} ->
        {:error, %{http_status: http_status, error: json_error_string}}
    end
  end

  defp get_error(other), do: {:error, inspect(other, pretty: true)}
end
