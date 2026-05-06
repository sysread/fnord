defmodule AI.Model.Venice do
  @moduledoc """
  Venice model catalog and named profiles.

  Concrete implementation of the model-catalog half of the provider
  abstraction for Venice. Each public factory below returns a fully-
  populated `AI.Model.t` with capability flags set.

  Model selections come from `scratch/venice-models.md` (the user's
  pre-picked Venice model preferences). All chosen models support both
  reasoning and web search. Note that on Venice web search is enabled
  per-request via `venice_parameters.enable_web_search` rather than
  being gated to specific models, so in principle every Venice profile
  could carry `supports_web_search: true`. We keep that explicit on each
  profile rather than relying on a provider-level invariant - if Venice
  later ships a model that does not support web search, the contract
  still works.

  ## Reasoning effort levels

  Venice supports the same OpenAI-compatible flat `reasoning_effort`
  field with extra levels (`xhigh`, `max`) beyond OpenAI's three. The
  `:xhigh` and `:max` atoms are deliberately not added to
  `AI.Model.reasoning_level` - they would force OpenAI to define a
  mapping. Venice's request builder handles them as Venice-only levels
  internally.

  ## Capability matrix

  All configured Venice models reason (`supportsReasoning: true`).
  Venice's `supportsReasoningEffort` flag distinguishes models with a
  tunable effort level from those with a fixed one - it is NOT a
  field-acceptance flag. Venice tolerates the `reasoning_effort` field
  on every reasoning model: tunable models honor the level, fixed
  models silently use their built-in setting. The reference web app
  (~/dev/nak) sends the field unconditionally for this reason.

  fnord's `supports_reasoning` flag therefore tracks `supportsReasoning`
  (does the model reason at all?) rather than `supportsReasoningEffort`
  (is the level tunable?). The request builder emits the field on any
  reasoning-capable model; Venice handles the rest.

  | Profile        | Model id              | Context | reasoning level | web_search |
  | -------------- | --------------------- | ------- | --------------- | ---------- |
  | large_context  | grok-4-20     | 1M      | high/med/low    | yes        |

  ## Profile aliasing

  `smart`, `smarter`, and `coding` all resolve to `grok-4-20` at
  different reasoning levels. The reasoning-level dial is the only
  thing distinguishing them; the model itself is shared. This is an
  explicit Venice-side decision based on the user's picks, not a
  generic property of the provider abstraction. Other providers may
  pick different models for these roles. Do NOT add cross-profile
  aliases (e.g. `coding == balanced`) unless the user has actually
  picked the same model for both.

  ## Citation handling note

  When `web_search?: true` is requested against a Venice model, the
  response includes structured citations under
  `venice_parameters.web_search_citations`. The Venice response parser
  appends a "Sources:" section to the assistant text so callers
  consuming the existing `{:ok, :msg, binary, usage}` contract see the
  citations without any orchestration-layer changes. See
  `AI.Provider.ResponseParser.Venice` for the implementation.
  """

  @behaviour AI.Model.Provider

  @type t :: %AI.Model{
          model: binary,
          context: non_neg_integer,
          reasoning: atom,
          verbosity: atom | nil,
          supports_reasoning: boolean,
          supports_web_search: boolean
        }

  # ---------------------------------------------------------------------------
  # Named profiles. Each maps a role (smart/balanced/fast/web/large) to a
  # specific model in the Venice catalog. Bumping a profile to a new model
  # is a single-line change here.
  # ---------------------------------------------------------------------------
  @impl AI.Model.Provider
  def smarter(), do: test_model(:high)

  @impl AI.Model.Provider
  def smart(), do: test_model(:medium)

  @impl AI.Model.Provider
  def balanced(), do: test_model(:low)

  @impl AI.Model.Provider
  def fast(), do: test_model(:none)

  @impl AI.Model.Provider
  def web_search(), do: test_model(:medium)

  # Venice ships a coding-tuned profile (instruct-style training
  # optimized for code generation). The user's pick in
  # scratch/venice-models.md points coding at kimi-k2-6, the same model
  # used for `smarter`. The alias is intentional and Venice-specific;
  # do not assume coding == balanced just because the OpenAI catalog
  # does that.
  @impl AI.Model.Provider
  def coding(), do: test_model(:medium)

  # All three tiers map to grok-41-fast for now; we have a single 1M-
  # context model in the catalog. Tiers are kept distinct so future
  # additions can differentiate without changing the call sites.
  @impl AI.Model.Provider
  def large_context(:smart), do: test_model(:high)
  def large_context(:balanced), do: test_model(:medium)
  def large_context(:fast), do: test_model(:low)

  # ---------------------------------------------------------------------------
  # Concrete model factories. Each declares the Venice model slug, context
  # window, default reasoning level, and capability flags.
  #
  # All current Venice profiles support reasoning and web search; this is
  # not a provider-wide invariant (Venice could add a non-reasoning model
  # tomorrow) so each factory states it explicitly.
  # ---------------------------------------------------------------------------

  # All configured Venice profiles set supports_reasoning: true. Venice
  # tolerates the reasoning_effort field on every reasoning-capable
  # model; the supportsReasoningEffort flag in /api/v1/models reports
  # whether the level is *tunable* on that model, not whether the field
  # is accepted.
  def test_model(reasoning \\ :medium),
    do:
      AI.Model.new("qwen-3-6-plus", 1_000_000, reasoning,
        supports_reasoning: true,
        supports_web_search: true
      )
end
