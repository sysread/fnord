defmodule AI.Model.OpenAI do
  @moduledoc """
  OpenAI model catalog and named profiles.

  Concrete implementation of the model-catalog half of the provider
  abstraction. Each public factory below returns a fully-populated
  `AI.Model.t` with capability flags set to match what the OpenAI API
  actually accepts for that model.

  ## Capability matrix

  Capabilities are declared per model rather than inferred from name strings
  because OpenAI changes naming conventions between releases and silent
  payload drops are worse than loud failures.

  | Family                    | reasoning_effort | web_search_options |
  | ------------------------- | ---------------- | ------------------ |
  | gpt-5.5                   | yes              | no                 |
  | gpt-5.4 family            | no               | no                 |
  | gpt-4.1 family            | no               | no                 |
  | gpt-5-search-api          | no               | yes                |

  Models that do not support `reasoning_effort` are constructed with
  `reasoning: :none` and `supports_reasoning: false`. The request builder
  uses the capability flag (not the level) to decide whether to emit the
  field, so callers can ask for `:medium` against a non-reasoning model
  without producing a 400 - the field is simply omitted.
  """

  @behaviour AI.Model.Provider

  @type t :: %AI.Model{
          model: binary,
          context: non_neg_integer,
          reasoning: atom,
          verbosity: atom | nil,
          max_tokens: pos_integer | nil,
          supports_reasoning: boolean,
          supports_web_search: boolean
        }

  # ----------------------------------------------------------------------------
  # Common presets. Each maps a role (smart/balanced/fast/web/large) to a
  # specific model in the OpenAI catalog. Bumping a profile to a new model
  # is a single-line change here; callers reach profiles via AI.Model.smart/0
  # etc. and never name a model directly.
  # ----------------------------------------------------------------------------
  @impl AI.Model.Provider
  def smarter(), do: gpt55(:low)

  @impl AI.Model.Provider
  def smart(), do: gpt54(:low)

  @impl AI.Model.Provider
  def balanced(), do: gpt54(:none)

  @impl AI.Model.Provider
  def fast(), do: gpt54_mini(:none)

  @impl AI.Model.Provider
  def web_search(), do: gpt5_web()

  @impl AI.Model.Provider
  def large_context(:smart), do: gpt41()
  def large_context(:balanced), do: gpt41_mini()
  def large_context(:fast), do: gpt41_nano()

  # OpenAI does not ship a dedicated coding-tuned model in fnord's
  # catalog, so coding is an alias for balanced here. Venice has a
  # genuine coding-tuned model (kimi-k2-6) and overrides this in
  # AI.Model.Venice.coding/0; do not assume the alias generalizes.
  @impl AI.Model.Provider
  def coding(), do: balanced()

  # ----------------------------------------------------------------------------
  # API-specific model definitions
  #
  # Each factory declares the model's wire-level identifier, context window,
  # default reasoning level, and capability flags. The capability flag says
  # "this model accepts the reasoning_effort field at all"; the level
  # controls what we send when we do send. Both pieces of information are
  # needed.
  # ----------------------------------------------------------------------------
  @spec gpt55(atom) :: AI.Model.t()
  def gpt55(reasoning \\ :medium),
    do: AI.Model.new("gpt-5.5", 1_050_000, reasoning, supports_reasoning: true)

  # The gpt-5.4 family is not driven by reasoning_effort in fnord. The
  # one-arg signature is preserved so call sites can still pass a level
  # without breaking, but the value is ignored and the model is pinned
  # to :none. Capability flag stays false: the request builder will not
  # emit reasoning_effort.
  @spec gpt54(atom) :: AI.Model.t()
  def gpt54(_), do: AI.Model.new("gpt-5.4", 1_050_000, :none)

  @spec gpt54_mini(atom) :: AI.Model.t()
  def gpt54_mini(_), do: AI.Model.new("gpt-5.4-mini", 400_000, :none)

  @spec gpt54_nano(atom) :: AI.Model.t()
  def gpt54_nano(_), do: AI.Model.new("gpt-5.4-nano", 400_000, :none)

  # The 4.1 family predates `reasoning_effort` entirely; the field is not
  # part of their request schema. Capabilities default to false in the
  # AI.Model constructor, so we don't pass them explicitly.
  @spec gpt41() :: AI.Model.t()
  def gpt41(), do: AI.Model.new("gpt-4.1", 1_000_000, :none)

  @spec gpt41_mini() :: AI.Model.t()
  def gpt41_mini(), do: AI.Model.new("gpt-4.1-mini", 1_000_000, :none)

  @spec gpt41_nano() :: AI.Model.t()
  def gpt41_nano(), do: AI.Model.new("gpt-4.1-nano", 1_000_000, :none)

  # The lone web-search-capable OpenAI model in our catalog. Setting
  # `supports_web_search: true` is what unlocks the `web_search_options: %{}`
  # field in the request payload; on every other OpenAI model the request
  # builder drops that field rather than producing an API error.
  #
  # Per https://developers.openai.com/api/docs/guides/tools-web-search this
  # is the only model the completions API supports for web search since
  # the gpt-4o-mini-search-preview deprecation. Context window is taken
  # from the limitations section since the model is not advertised on the
  # standard models page.
  @spec gpt5_web() :: AI.Model.t()
  def gpt5_web(),
    do: AI.Model.new("gpt-5-search-api", 200_000, :none, supports_web_search: true)
end
