defmodule AI do
  @moduledoc """
  AI is a behavior module that defines the interface for interacting with
  OpenAI's API. It provides a common interface for the various OpenAI-powered
  operations used by the application.
  """

  defstruct [
    :client,
    :api_key
  ]

  @type t :: %__MODULE__{
          client: %OpenaiEx{}
        }

  @api_timeout 5 * 60 * 1000
  @default_max_attempts 3
  @retry_interval 250

  @doc """
  Create a new AI instance. Instances share the same client connection.
  """
  def new() do
    api_key = System.get_env("OPENAI_API_KEY")

    if is_nil(api_key) do
      raise "Missing OpenAI API key. Please set the OPENAI_API_KEY environment variable."
    end

    openai =
      api_key
      |> OpenaiEx.new()
      |> OpenaiEx.with_receive_timeout(@api_timeout)

    %AI{client: openai}
  end

  # -----------------------------------------------------------------------------
  # Completions
  # -----------------------------------------------------------------------------
  def get_completion(ai, options \\ []) do
    with {:ok, model} <- Keyword.fetch(options, :model),
         {:ok, messages} <- get_messages(options),
         {:ok, tools} <- get_tools(options) do
      max = Keyword.get(options, :attempts, @default_max_attempts)
      args = [model: model, messages: messages] ++ tools
      request = OpenaiEx.Chat.Completions.new(args)
      get_completion(ai, request, max, 1)
    end
  end

  defp get_completion(_ai, _request, max, attempt) when attempt > max do
    {:error, "Request timed out after #{attempt} attempts."}
  end

  defp get_completion(ai, request, max, attempt) do
    completion = OpenaiEx.Chat.Completions.create(ai.client, request)

    case completion do
      {:ok, %{"choices" => [event]}} ->
        {:ok, event}

      {:error, %OpenaiEx.Error{message: "Request timed out."}} ->
        Process.sleep(@retry_interval)
        get_completion(ai, request, max, attempt + 1)

      {:error, %OpenaiEx.Error{message: msg}} ->
        {:error, msg}
    end
  end

  defp get_tools(opts) do
    Keyword.get(opts, :tools, nil)
    |> case do
      nil -> {:ok, []}
      tools -> get_tools(tools: tools)
    end
  end

  defp get_messages(opts) do
    Keyword.get(opts, :messages, nil)
    |> case do
      nil ->
        with {:ok, system_prompt} <- Keyword.fetch(opts, :system),
             {:ok, user_prompt} <- Keyword.fetch(opts, :user) do
          {:ok, [AI.Util.system_msg(system_prompt), AI.Util.user_msg(user_prompt)]}
        end

      messages ->
        {:ok, messages}
    end
  end

  # -----------------------------------------------------------------------------
  # Embeddings
  # -----------------------------------------------------------------------------
  @token_limit 8192
  @model "text-embedding-3-large"

  @doc """
  Get embeddings for the given text. The text is split into chunks of 8192
  tokens to avoid exceeding the model's input limit. Returns a list of
  embeddings for each chunk.
  """
  def get_embeddings(ai, text) do
    embeddings =
      AI.Util.split_text(text, @token_limit)
      |> Enum.map(fn chunk ->
        OpenaiEx.Embeddings.create(
          ai.client,
          OpenaiEx.Embeddings.new(model: @model, input: chunk)
        )
        |> case do
          {:ok, %{"data" => [%{"embedding" => embedding}]}} -> embedding
          _ -> nil
        end
      end)
      |> Enum.filter(fn x -> not is_nil(x) end)

    {:ok, embeddings}
  end
end
