defmodule AI.Model.Venice do
  @moduledoc """
  Venice model catalog and named profiles.

  Concrete implementation of the model-catalog half of the provider
  abstraction for Venice. Each public factory below returns a fully-
  populated `AI.Model.t` with capability flags set.

  ## Current catalog state: single-model testing

  All profile factories currently route through `test_model/1`, which
  returns `qwen-3-6-plus` (1M context) at the reasoning level the
  caller's profile name implies. This is a deliberate consolidation
  for end-to-end provider testing on the `venice` branch - the
  mechanical wiring (request builder, response parser, retry harness,
  rate limiting, role handling) is being validated against a single
  model before the per-profile catalog is restored.

  Per-profile picks (from `scratch/venice-models.md`, partial state at
  time of writing):
  - `smart`, `balanced`: validated on `qwen-3-6-plus`; keepers
  - `smarter`, `coding`: originally `kimi-k2-6` at different reasoning
    levels; revert before the branch ships
  - `fast`, `large_context`: originally `grok-41-fast` (1M context)
  - `web_search`: originally `qwen3-5-35b-a3b`

  Restoring the per-profile catalog is a single-file change in this
  module; the test in `test/ai/model/venice_test.exs` will need
  matching updates.

  ## Reasoning effort levels

  Venice supports the same OpenAI-compatible flat `reasoning_effort`
  field with extra levels (`xhigh`, `max`) beyond OpenAI's three. The
  `:xhigh` and `:max` atoms are deliberately not added to
  `AI.Model.reasoning_level` - they would force OpenAI to define a
  mapping. Venice's request builder handles them as Venice-only levels
  internally.

  ## Capability flags

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

  ## Profile aliasing

  While the catalog is consolidated, `smart`, `smarter`, `balanced`,
  `fast`, `web_search`, `coding`, and all `large_context` tiers
  resolve to the same model with different reasoning levels. Profile
  aliases (e.g. `coding == smarter` when both pick the same model)
  are valid only when explicitly picked - this is intentional, per-
  provider configuration, not a generic property of the abstraction.
  Do NOT carry over OpenAI's cross-profile aliases.

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
  def large_context(:smart), do: deepseek_v4_flash(:high)
  def large_context(:balanced), do: deepseek_v4_flash(:medium)
  def large_context(:fast), do: deepseek_v4_flash(:low)

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
  def test_model(reasoning \\ :medium) do
    AI.Model.new("qwen-3-6-plus", 1_000_000, reasoning,
      supports_reasoning: true,
      supports_web_search: true
    )
  end

  def deepseek_v4_flash(reasoning \\ :medium) do
    AI.Model.new("deepseek-v4-flash", 1_000_000, reasoning,
      supports_reasoning: true,
      supports_web_search: true
    )
  end
end
