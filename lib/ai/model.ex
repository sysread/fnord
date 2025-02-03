defmodule AI.Model do
  defstruct [
    :model,
    :reasoning,
    :context
  ]

  @type reasoning :: nil | :low | :medium | :high

  @type t :: %__MODULE__{
          model: String.t(),
          reasoning: reasoning,
          context: non_neg_integer
        }

  @spec new(String.t(), reasoning, non_neg_integer) :: t
  def new(model, reasoning, context) do
    %AI.Model{
      model: model,
      reasoning: reasoning,
      context: context
    }
  end

  @spec smart() :: t
  def smart() do
    %AI.Model{
      model: "o3-mini",
      reasoning: :high,
      context: 200_000
    }
  end

  @spec balanced() :: t
  def balanced() do
    %AI.Model{
      model: "o3-mini",
      reasoning: :medium,
      context: 200_000
    }
  end

  @spec fast() :: t
  def fast() do
    %AI.Model{
      model: "o3-mini",
      reasoning: :low,
      context: 200_000
    }
  end

  @spec embeddings() :: t
  def embeddings() do
    %AI.Model{
      model: "text-embedding-3-large",
      reasoning: nil,
      # It's actually 8192 for this model, but this gives us a little bit of
      # wiggle room in case the tokenizer we are using falls behind.
      context: 6500
    }
  end
end
