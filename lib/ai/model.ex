defmodule AI.Model do
  defstruct [
    :model,
    :context,
    :reasoning
  ]

  @type reasoning_level ::
          :none
          | :minimal
          | :low
          | :medium
          | :high

  @type t :: %__MODULE__{
          model: String.t(),
          context: non_neg_integer,
          reasoning: reasoning_level
        }

  @spec new(String.t(), non_neg_integer) :: t
  def new(model, context, reasoning \\ :none) do
    %AI.Model{
      model: model,
      context: context,
      reasoning: reasoning
    }
  end

  @spec smart() :: t
  def smart() do
    # %AI.Model{model: "gpt-4.1", context: 1_000_000, reasoning: :none}
    %AI.Model{model: "gpt-5", context: 400_000, reasoning: :medium}
  end

  @spec balanced() :: t
  def balanced() do
    # %AI.Model{ model: "gpt-4.1-mini", context: 1_000_000, reasoning: :none }
    %AI.Model{model: "gpt-5-mini", context: 400_000, reasoning: :medium}
  end

  @spec fast() :: t
  def fast() do
    %AI.Model{model: "gpt-4.1-nano", context: 1_000_000, reasoning: :none}
    # %AI.Model{model: "gpt-5-nano", context: 400_000, reasoning: :minimal}
  end

  @spec large_context() :: t
  def large_context() do
    %AI.Model{model: "gpt-4.1", context: 1_000_000, reasoning: :none}
  end

  @spec reasoning(reasoning_level) :: t
  def reasoning(level) do
    %AI.Model{model: "o4-mini", context: 200_000, reasoning: level}
  end
end
