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

  @callback new() :: struct()
  @callback get_embeddings(struct(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  @callback get_summary(struct(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback get_outline(struct(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}

  @behaviour AI

  @impl AI
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

  def get_completion(ai, options \\ []) do
    with {:ok, model} <- Keyword.fetch(options, :model),
         {:ok, messages} <- get_messages(options),
         {:ok, tools} <- get_tools(options) do
      max_attempts = Keyword.get(options, :attempts, @default_max_attempts)
      args = [model: model, messages: messages] ++ tools
      request = OpenaiEx.Chat.Completions.new(args)
      get_completion(ai, request, max_attempts, 1)
    end
  end

  defp get_tools(options) do
    case Keyword.get(options, :tools) do
      nil -> []
      tools -> [tools: tools]
    end
    |> then(&{:ok, &1})
  end

  defp get_messages(options) do
    if Keyword.has_key?(options, :messages) do
      Keyword.get(options, :messages)
    else
      with {:ok, system_prompt} <- Keyword.fetch(options, :system_prompt),
           {:ok, user_prompt} <- Keyword.fetch(options, :user_prompt) do
        [
          OpenaiEx.ChatMessage.system(system_prompt),
          OpenaiEx.ChatMessage.user(user_prompt)
        ]
      end
    end
    |> case do
      {:error, reason} -> {:error, reason}
      messages -> {:ok, messages}
    end
  end

  defp get_completion(_ai, _request, max_attempts, current_attempt)
       when current_attempt > max_attempts do
    {:error, "Request timed out after #{current_attempt} attempts."}
  end

  defp get_completion(ai, request, max_attempts, current_attempt) do
    completion = OpenaiEx.Chat.Completions.create(ai.client, request)

    case completion do
      {:ok, %{"choices" => [event]}} ->
        {:ok, event}

      {:error, %OpenaiEx.Error{message: "Request timed out."}} ->
        Process.sleep(@retry_interval)
        get_completion(ai, request, max_attempts, current_attempt + 1)

      {:error, %OpenaiEx.Error{message: msg}} ->
        {:error, msg}
    end
  end

  # -----------------------------------------------------------------------------
  # Embeddings
  # -----------------------------------------------------------------------------
  @impl AI
  @doc """
  See `AI.EmbeddingsAgent.get_embeddings/2`.
  """
  defdelegate get_embeddings(ai, text), to: AI.Agent.Embeddings

  # -----------------------------------------------------------------------------
  # Summaries
  # -----------------------------------------------------------------------------
  @impl AI
  @doc """
  See `AI.FileSummaryAgent.get_summary/3`.
  """
  defdelegate get_summary(ai, file, text), to: AI.Agent.FileSummary

  @impl AI
  @doc """
  See `AI.Agent.CodeMapperAgent`.
  """
  def get_outline(ai, file_path, file_content) do
    ai
    |> AI.Agent.CodeMapper.new(file_path, file_content)
    |> AI.Agent.CodeMapper.get_outline()
  end
end
