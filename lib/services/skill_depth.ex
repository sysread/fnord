defmodule Services.SkillDepth do
  @moduledoc """
  Tracks nested skill execution depth.

  Skills can be configured to include the `skills` toolset tag, which gives them
  access to the skill runner tool. This enables skill-to-skill calls.

  To prevent runaway recursion, we track depth across nested calls and refuse
  execution once a maximum is reached.

  This service is started as part of `Services.start_all/0`.
  """

  use Agent
  require Logger

  @type depth_result :: {:ok, non_neg_integer()} | {:error, :max_depth_reached}

  @max_depth 3

  @doc """
  Start the depth tracker.
  """
  @spec start_link() :: {:ok, pid()} | {:error, term()}
  def start_link() do
    Agent.start_link(fn -> 0 end, name: __MODULE__)
  end

  @doc """
  Increment depth.

  Returns `{:error, :max_depth_reached}` once the configured max is exceeded.
  """
  @spec inc_depth() :: depth_result
  def inc_depth() do
    Agent.get_and_update(__MODULE__, fn
      depth when depth >= @max_depth ->
        {{:error, :max_depth_reached}, depth}

      depth ->
        {{:ok, depth + 1}, depth + 1}
    end)
  end

  @doc """
  Decrement depth.
  """
  @spec dec_depth() :: {:ok, non_neg_integer()}
  def dec_depth() do
    Agent.get_and_update(__MODULE__, fn
      0 ->
        Logger.warning("dec_depth called at 0 (underflow), clamping to 0")
        {{:ok, 0}, 0}

      depth ->
        {{:ok, depth - 1}, depth - 1}
    end)
  end

  @doc """
  Return current depth.
  """
  @spec depth() :: non_neg_integer()
  def depth() do
    Agent.get(__MODULE__, fn depth -> depth end)
  end
end
