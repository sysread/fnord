defmodule AI.Model do
  @moduledoc """
  Provider-neutral model profile.

  An `AI.Model.t` is a small struct that captures everything the request-
  building layer needs to know about a model without taking a dependency on
  the underlying provider:

  - `:model` - the wire-level identifier the provider expects
  - `:context` - the model's context-window size in tokens
  - `:reasoning` - the desired reasoning-effort level for this profile
  - `:verbosity` - the desired verbosity level (currently a no-op on most
    paths; see the engram memory "Verbosity plumbing" for context)
  - `:supports_reasoning` - capability flag: does the model accept the
    `reasoning_effort` field on the wire? When false, the request builder
    must drop reasoning regardless of the configured `:reasoning` level.
  - `:supports_web_search` - capability flag: can the model perform a web
    search as part of its response? When false, requesting web search
    against this model is a caller bug and the request builder fails fast.

  ## Why capability flags live on the model

  Reasoning and web search are not universal. On OpenAI, only the gpt-5
  family accepts `reasoning_effort` and only the search-preview models
  honor `web_search_options`. On Venice, both are nominally available on
  any model, but a future model could break that. Encoding the truth on
  the profile struct (rather than inferring from the model-name string)
  keeps the contract auditable: a profile factory declares its capabilities
  explicitly, and the request builder checks the flag instead of pattern-
  matching on names that change between vendor releases.

  ## Profile factories

  The `smart/0`, `smarter/0`, `balanced/0`, `fast/0`, `web_search/0`,
  `large_context/0,1`, and `coding/0` functions return profiles for the
  configured provider by delegating to `AI.Provider.module_for(:model)`.
  Provider-specific profile modules (`AI.Model.OpenAI`, `AI.Model.Venice`)
  populate the capability flags accurately for each model in their catalog.
  """

  defstruct [
    :model,
    :context,
    :reasoning,
    :verbosity,
    # Capability flags. Default to `false` in `new/N`; profile factories
    # opt in by passing the appropriate options. A conservative default is
    # the safer choice: an unknown model is assumed to lack a capability
    # rather than to have it (which would produce silently-wrong wire
    # payloads).
    supports_reasoning: false,
    supports_web_search: false
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
          verbosity: verbosity_level | nil,
          supports_reasoning: boolean,
          supports_web_search: boolean
        }

  @doc """
  Construct a model profile.

  The two-arity form is for tests and ad-hoc construction; both capability
  flags default to `false`. Production profile factories should use the
  keyword form to declare capabilities accurately.
  """
  @spec new(String.t(), non_neg_integer) :: t
  @spec new(String.t(), non_neg_integer, reasoning_level) :: t
  @spec new(String.t(), non_neg_integer, reasoning_level, Keyword.t()) :: t
  def new(model, context, reasoning \\ :medium, opts \\ []) do
    %AI.Model{
      model: model,
      context: context,
      reasoning: reasoning,
      verbosity: nil,
      supports_reasoning: Keyword.get(opts, :supports_reasoning, false),
      supports_web_search: Keyword.get(opts, :supports_web_search, false)
    }
  end

  @doc """
  Override the reasoning level on an existing profile.

  Accepts atoms or string aliases (the latter resolved via
  `String.to_existing_atom/1` so callers cannot blow out the atom table by
  feeding in arbitrary user input). Does not change `:supports_reasoning`;
  capability is intrinsic to the model, not to the requested level.
  """
  @spec with_reasoning(t(), reasoning_level()) :: t()
  def with_reasoning(model = %__MODULE__{}, lvl) do
    case lvl do
      nil -> model
      "" -> model
      lvl when is_atom(lvl) -> %AI.Model{model | reasoning: lvl}
      lvl when is_binary(lvl) -> %AI.Model{model | reasoning: String.to_existing_atom(lvl)}
    end
  end

  @doc """
  Override verbosity on an existing profile. Same atom-safety rationale as
  `with_reasoning/2`.
  """
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

  # Provider resolution for model profiles. Indirected via AI.Provider so
  # that the same delegation chain that controls endpoint and request
  # builders also controls which catalog of profiles is in play.
  @spec provider_model_mod() :: module
  defp provider_model_mod(), do: AI.Provider.module_for(:model)
end
