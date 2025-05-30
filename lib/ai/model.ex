defmodule AI.Model do
  defstruct [
    :model,
    :context
  ]

  @type t :: %__MODULE__{
          model: String.t(),
          context: non_neg_integer
        }

  @spec new(String.t(), non_neg_integer) :: t
  def new(model, context) do
    %AI.Model{
      model: model,
      context: context
    }
  end

  @spec smart() :: t
  def smart() do
    %AI.Model{
      model: "gpt-4.1",
      context: 1_000_000
    }
  end

  @spec balanced() :: t
  def balanced() do
    %AI.Model{
      model: "gpt-4.1-mini",
      context: 1_000_000
    }
  end

  @spec fast() :: t
  def fast() do
    %AI.Model{
      model: "gpt-4.1-nano",
      context: 1_000_000
    }
  end
end
