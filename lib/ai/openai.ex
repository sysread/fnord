defmodule AI.OpenAI do
  @moduledoc """
  This module provides functions to interact with the OpenAI API, including
  getting embeddings and completions.
  """

  defstruct [
    :api_key,
    :http_options
  ]

  @api_key_error "Missing OpenAI API key. Please set the OPENAI_API_KEY environment variable."
  @embedding_endpoint "https://api.openai.com/v1/embeddings"
  @completion_endpoint "https://api.openai.com/v1/chat/completions"

  def new(http_options) do
    %__MODULE__{
      api_key: get_api_key(),
      http_options: http_options
    }
  end

  def get_embedding(openai, model, input) do
    headers = [get_auth_header(openai)]
    payload = %{model: model, encoding_format: "float", input: input}

    Http.post_json(@embedding_endpoint, headers, payload, openai.http_options)
    |> case do
      {:ok, %{"data" => [%{"embedding" => embedding}]}} -> {:ok, embedding}
      {:error, error} -> {:error, error}
    end
  end

  def get_completion(openai, model, msgs, tools \\ nil) do
    headers = [get_auth_header(openai)]

    payload =
      case tools do
        nil -> %{model: model, messages: msgs}
        tools -> %{model: model, messages: msgs, tools: tools}
      end

    Http.post_json(@completion_endpoint, headers, payload, openai.http_options)
    |> case do
      {:ok, response} -> get_completion_response(response)
      {:error, error} -> get_error_response(error)
    end
  end

  # -----------------------------------------------------------------------------
  # Private functions
  # -----------------------------------------------------------------------------
  defp get_api_key() do
    case System.get_env("OPENAI_API_KEY", nil) do
      nil -> raise @api_key_error
      api_key -> api_key
    end
  end

  defp get_auth_header(openai) do
    {"Authorization", "Bearer #{openai.api_key}"}
  end

  defp get_completion_response(%{"choices" => [%{"message" => response}]}) do
    get_completion_response(response)
  end

  defp get_completion_response(%{"tool_calls" => tool_calls}) do
    {:ok, :tool, Enum.map(tool_calls, &get_tool_call/1)}
  end

  defp get_completion_response(%{"content" => response}) do
    {:ok, :msg, response}
  end

  defp get_tool_call(%{"id" => id, "function" => %{"name" => name, "arguments" => args}}) do
    %{id: id, function: %{name: name, arguments: args}}
  end

  defp get_error_response(:closed), do: {:error, "Connection closed"}

  defp get_error_response({http_status, json_error_string}) do
    json_error_string
    |> Jason.decode()
    |> case do
      {:ok, %{"error" => %{"code" => code, "message" => msg}}} ->
        {:error, %{http_status: http_status, code: code, message: msg}}

      {:ok, error} ->
        {:error, %{http_status: http_status, error: inspect(error, pretty: true)}}

      {:error, _} ->
        {:error, %{http_status: http_status, error: json_error_string}}
    end
  end
end
