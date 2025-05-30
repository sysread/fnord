defmodule AI do
  @moduledoc """
  AI is a behavior module that defines the interface for interacting with
  OpenAI's API. It provides a common interface for the various OpenAI-powered
  operations used by the application.
  """

  defstruct [
    :client
  ]

  @type t :: %__MODULE__{
          client: %AI.OpenAI{}
        }

  @default_max_attempts 3
  @retry_interval 250

  @doc """
  Create a new AI instance. Instances share the same client connection.
  """
  def new() do
    client = AI.OpenAI.new()
    %AI{client: client}
  end

  # -----------------------------------------------------------------------------
  # Completions
  # -----------------------------------------------------------------------------
  def get_completion(ai, model, msgs, tools) do
    request = [ai.client, model, msgs, tools]
    do_get_completion(ai, request, @default_max_attempts, 1)
  end

  defp do_get_completion(_ai, _request, max, attempt) when attempt > max do
    {:error, "Request timed out after #{attempt} attempts."}
  end

  defp do_get_completion(ai, request, max, attempt) do
    if attempt > 1, do: Process.sleep(@retry_interval)

    AI.OpenAI
    |> apply(:get_completion, request)
    |> case do
      {:error, :timeout} -> do_get_completion(ai, request, max, attempt + 1)
      etc -> etc
    end
  end
end
