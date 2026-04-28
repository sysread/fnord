defmodule AI.Model do
  defstruct [
    :model,
    :context,
    :reasoning,
    :verbosity
  ]

  @type reasoning_level ::
          :none
          | :minimal
          | :low
          | :medium
          | :high
          | :default

  @type verbosity_level :: :low | :medium | :high

  @type speed ::
          :smart
          | :balanced
          | :fast

  @type t :: %__MODULE__{
          model: String.t(),
          context: non_neg_integer,
          reasoning: reasoning_level,
          verbosity: verbosity_level | nil
        }

  @spec new(String.t(), non_neg_integer) :: t
  @spec new(String.t(), non_neg_integer, reasoning_level) :: t
  def new(model, context, reasoning \\ :medium) do
    %AI.Model{
      model: model,
      context: context,
      reasoning: reasoning,
      verbosity: nil
    }
  end

  @spec with_reasoning(t(), reasoning_level()) :: t()
  def with_reasoning(model = %__MODULE__{}, lvl) do
    case lvl do
      nil -> model
      "" -> model
      lvl when is_atom(lvl) -> %AI.Model{model | reasoning: lvl}
      lvl when is_binary(lvl) -> %AI.Model{model | reasoning: String.to_existing_atom(lvl)}
    end
  end

  @spec with_verbosity(t(), verbosity_level() | binary | nil) :: t()
  def with_verbosity(model = %__MODULE__{}, lvl) do
    case lvl do
      nil -> model
      "" -> model
      lvl when is_atom(lvl) -> %AI.Model{model | verbosity: lvl}
      lvl when is_binary(lvl) -> %AI.Model{model | verbosity: String.to_existing_atom(lvl)}
    end
  end

  def smart(), do: gpt5(:low)
  def smarter(), do: gpt55(:low)
  def balanced(), do: gpt5_mini()
  def fast(), do: gpt5_nano()
  def coding(), do: balanced()
  def web_search(), do: gpt_4o_mini_search_preview()

  def large_context(), do: large_context(:smart)
  def large_context(:smart), do: gpt41()
  def large_context(:balanced), do: gpt41_mini()
  def large_context(:fast), do: gpt41_nano()

  # ----------------------------------------------------------------------------
  # OpenAI Models
  # ----------------------------------------------------------------------------
  def gpt55(reasoning \\ :medium), do: new("gpt-5.5", 1_050_000, reasoning)
  def gpt54(reasoning \\ :medium), do: new("gpt-5.4", 1_050_000, reasoning)
  def gpt55(reasoning \\ :medium), do: new("gpt-5.5", 1_050_000, reasoning)
  def gpt5(reasoning \\ :medium), do: new("gpt-5-2025-08-07", 400_000, reasoning)

  # does not support reasoning_effort through the chat completions api
  def gpt5_mini(), do: new("gpt-5.4-mini", 400_000, :none)

  # does not support reasoning_effort through the chat completions api
  def gpt5_nano(), do: new("gpt-5.4-nano", 400_000, :none)

  def gpt41(), do: new("gpt-4.1", 1_000_000, :none)
  def gpt41_mini(), do: new("gpt-4.1-mini", 1_000_000, :none)
  def gpt41_nano(), do: new("gpt-4.1-nano", 1_000_000, :none)
  def gpt_4o_mini_search_preview(), do: new("gpt-4o-mini-search-preview", 128_000, :none)
end
