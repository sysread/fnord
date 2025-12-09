defmodule Memory.Session do
  # ----------------------------------------------------------------------------
  # Behaviour Implementation
  # ----------------------------------------------------------------------------
  @behaviour Memory

  @impl Memory
  def init() do
    case get_conversation_pid() do
      {:ok, _pid} -> :ok
      error -> error
    end
  end

  @impl Memory
  def list() do
    with {:ok, memories} <- get_conversation_memory() do
      titles = Enum.map(memories, & &1.title)
      {:ok, titles}
    end
  end

  @impl Memory
  def exists?(title) when is_binary(title) do
    with {:ok, memories} <- get_conversation_memory() do
      Enum.any?(memories, fn %Memory{title: t} -> t == title end)
    else
      _ -> false
    end
  end

  @impl Memory
  def read(title) when is_binary(title) do
    with {:ok, memories} <- get_conversation_memory() do
      memories
      |> Enum.find(fn %Memory{title: t} -> t == title end)
      |> case do
        nil -> {:error, :not_found}
        mem -> {:ok, mem}
      end
    end
  end

  @impl Memory
  def save(%Memory{title: title} = memory) do
    with {:ok, pid} <- get_conversation_pid(),
         {:ok, memories} <- get_conversation_memory() do
      updated =
        memories
        |> Enum.reject(fn %Memory{title: t} -> t == title end)
        |> Kernel.++([memory])

      Services.Conversation.put_memory(pid, updated)
      :ok
    end
  end

  @impl Memory
  def forget(title) when is_binary(title) do
    with {:ok, pid} <- get_conversation_pid(),
         {:ok, memories} <- get_conversation_memory() do
      updated = Enum.reject(memories, fn %Memory{title: t} -> t == title end)

      Services.Conversation.put_memory(pid, updated)
      :ok
    end
  end

  @impl Memory
  def is_available?() do
    case get_conversation_pid() do
      {:ok, _pid} -> true
      _ -> false
    end
  end

  # ----------------------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------------------
  defp get_conversation_pid() do
    Services.Globals.get_env(:fnord, :current_conversation)
    |> case do
      nil -> {:error, :no_conversation_set}
      pid when is_pid(pid) -> {:ok, pid}
      _ -> {:error, :invalid_conversation}
    end
  end

  defp get_conversation_memory() do
    with {:ok, pid} <- get_conversation_pid() do
      {:ok, Services.Conversation.get_memory(pid)}
    end
  end
end
