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
          | :default

  @type speed ::
          :smart
          | :balanced
          | :fast

  @type t :: %__MODULE__{
          model: String.t(),
          context: non_neg_integer,
          reasoning: reasoning_level
        }

  @spec new(String.t(), non_neg_integer) :: t
  @spec new(String.t(), non_neg_integer, reasoning_level) :: t
  def new(model, context, reasoning \\ :medium) do
    %AI.Model{
      model: model,
      context: context,
      reasoning: reasoning
    }
  end

  def smart(), do: gpt5_mini(:medium)
  def balanced(), do: gpt5_mini(:low)
  def fast(), do: gpt41_nano()

  def coding(), do: o4_mini(:medium)
  def web_search(), do: gpt_4o_mini_search_preview()

  def large_context(), do: large_context(:smart)
  def large_context(:smart), do: gpt41()
  def large_context(:balanced), do: gpt41_mini()
  def large_context(:fast), do: gpt41_nano()

  # ----------------------------------------------------------------------------
  # OpenAI Models
  # ----------------------------------------------------------------------------
  def gpt5(reasoning \\ :medium), do: new("gpt-5.1", 400_000, reasoning)
  def gpt5_mini(reasoning \\ :medium), do: new("gpt-5-mini", 400_000, reasoning)
  def gpt5_nano(reasoning \\ :medium), do: new("gpt-5-nano", 400_000, reasoning)

  def o4_mini(reasoning \\ :medium), do: new("o4-mini", 200_000, reasoning)
  def gpt_4o_mini_search_preview(), do: new("gpt-4o-mini-search-preview", 128_000, :none)

  def gpt41(), do: new("gpt-4.1", 1_000_000, :none)
  def gpt41_mini(), do: new("gpt-4.1-mini", 1_000_000, :none)
  def gpt41_nano(), do: new("gpt-4.1-nano", 1_000_000, :none)
end
