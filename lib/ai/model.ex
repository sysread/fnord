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

  @doc """
  Return a provider-agnostic "smart" profile.
  Delegates to the configured provider implementation.
  """
  @spec smart() :: t()
  def smart(), do: apply(provider_model_mod(), :smart, [])

  @doc """
  Return a provider-agnostic "smarter" profile.
  Delegates to the configured provider implementation.
  """
  @spec smarter() :: t()
  def smarter(), do: apply(provider_model_mod(), :smarter, [])

  @doc """
  Return a provider-agnostic "balanced" profile.
  Delegates to the configured provider implementation.
  """
  @spec balanced() :: t()
  def balanced(), do: apply(provider_model_mod(), :balanced, [])

  @doc """
  Return a provider-agnostic "fast" profile.
  Delegates to the configured provider implementation.
  """
  @spec fast() :: t()
  def fast(), do: apply(provider_model_mod(), :fast, [])

  @doc """
  Shortcut for coding; currently equals balanced().
  """
  @spec coding() :: t()
  def coding(), do: balanced()

  @doc """
  Provider-agnostic web_search profile.
  Delegates to provider implementation.
  """
  @spec web_search() :: t()
  def web_search(), do: apply(provider_model_mod(), :web_search, [])

  @doc """
  Provider-agnostic large_context; default tier :smart.
  Delegates to provider implementation.
  """
  @spec large_context() :: t()
  def large_context(), do: large_context(:smart)

  @spec large_context(:smart | :balanced | :fast) :: t()
  def large_context(tier), do: apply(provider_model_mod(), :large_context, [tier])

  # Provider resolution for model profiles
  @spec provider_model_mod() :: module
  defp provider_model_mod(), do: AI.Provider.module_for(:model)
end
