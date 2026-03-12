defmodule Services.SkillDepth do
  @moduledoc """
  Tracks nested skill execution depth per process tree.

  Skills can be configured to include the `skills` toolset tag, which gives them
  access to the skill runner tool. This enables skill-to-skill calls.

  To prevent runaway recursion, we track depth across nested calls and refuse
  execution once a maximum is reached.

  Depth is scoped to the current process tree via `Services.Globals`, so
  concurrent skill chains (e.g., parallel delegate steps) each maintain their
  own independent counter.
  """

  require Logger

  @type depth_result :: {:ok, non_neg_integer()} | {:error, :max_depth_reached}

  @max_depth 3
  @globals_key :skill_depth

  @doc """
  Increment depth.

  Returns `{:error, :max_depth_reached}` once the configured max is exceeded.
  """
  @spec inc_depth() :: depth_result
  def inc_depth do
    current = depth()

    if current >= @max_depth do
      {:error, :max_depth_reached}
    else
      new_depth = current + 1
      Services.Globals.put_env(:fnord, @globals_key, new_depth)
      {:ok, new_depth}
    end
  end

  @doc """
  Decrement depth.
  """
  @spec dec_depth() :: {:ok, non_neg_integer()}
  def dec_depth do
    current = depth()

    if current == 0 do
      Logger.warning("dec_depth called at 0 (underflow), clamping to 0")
      {:ok, 0}
    else
      new_depth = current - 1
      Services.Globals.put_env(:fnord, @globals_key, new_depth)
      {:ok, new_depth}
    end
  end

  @doc """
  Return current depth.
  """
  @spec depth() :: non_neg_integer()
  def depth do
    Services.Globals.get_env(:fnord, @globals_key, 0)
  end
end
