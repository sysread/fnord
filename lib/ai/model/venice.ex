defmodule AI.Model.Venice do
  @moduledoc """
  Venice model catalog and named profiles.

  Concrete implementation of the model-catalog half of the provider
  abstraction for Venice. Each public factory below returns a fully-
  populated `AI.Model.t` with capability flags set.

  ## Catalog state

  Profile -> model mapping is in flux while the per-profile picks are
  tuned against the live Venice API. The impl block below is the
  authoritative source. The corresponding test in
  `test/ai/model/venice_test.exs` pins the wire-level model id per
  profile - update both together when swapping a model.

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

  Profile aliases (e.g. `coding == smarter` when both pick the same
  model) are valid only when explicitly picked - this is intentional,
  per-provider configuration, not a generic property of the
  abstraction. Do NOT carry over OpenAI's cross-profile aliases. The
  current `coding` and `smarter` both pick kimi-k2-6 (at different
  reasoning levels) and `fast` and `web_search` both pick mercury-2;
  these aliases are deliberate and may diverge as profile-specific
  models are selected.

  ## Citation handling note

  When `web_search?: true` is requested against a Venice model, the
  response includes structured citations under
  `venice_parameters.web_search_citations`. The Venice response parser
  appends a "Sources:" section to the assistant text so callers
  consuming the existing `{:ok, :msg, binary, usage}` contract see the
  citations without any orchestration-layer changes. See
  `AI.Provider.ResponseParser.Venice` for the implementation.

  # NOTE
  - do not use minimax-m27; it does not support response_format
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
  def smarter(), do: venice_coding(:high)

  @impl AI.Model.Provider
  def smart(), do: venice_coding(:low)

  @impl AI.Model.Provider
  def balanced(), do: venice_default(:none)

  @impl AI.Model.Provider
  def fast(), do: venice_fast()

  @impl AI.Model.Provider
  def web_search(), do: venice_fast()

  # Venice ships a coding-tuned profile (instruct-style training
  # optimized for code generation). The user's pick in
  # scratch/venice-models.md points coding at kimi-k2-6, the same model
  # used for `smarter`. The alias is intentional and Venice-specific;
  # do not assume coding == balanced just because the OpenAI catalog
  # does that.
  @impl AI.Model.Provider
  def coding(), do: venice_coding(:none)

  # All three large_context tiers route through deepseek-v4-flash (1M
  # context, Venice-native). Tiers are kept distinct so the reasoning
  # level can vary independently per tier - and so future moves to a
  # different per-tier model are a single-line change here.
  @impl AI.Model.Provider
  def large_context(:smart), do: venice_long_context(:high)
  def large_context(:balanced), do: venice_long_context(:medium)
  def large_context(:fast), do: venice_long_context(:low)

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
  def venice_default(reasoning \\ :low) do
    AI.Model.new("qwen-3-6-plus", 1_000_000, reasoning,
      supports_reasoning: true,
      supports_web_search: true
    )
  end

  def venice_coding(reasoning \\ :low) do
    AI.Model.new("kimi-k2-6", 256_000, reasoning,
      supports_reasoning: true,
      supports_web_search: true
    )
  end

  def venice_fast(reasoning \\ :low) do
    AI.Model.new("mercury-2", 128_000, reasoning,
      supports_reasoning: true,
      supports_web_search: true
    )
  end

  def venice_long_context(reasoning \\ :low) do
    AI.Model.new("deepseek-v4-flash", 1_000_000, reasoning,
      supports_reasoning: true,
      supports_web_search: true
    )
  end
end
