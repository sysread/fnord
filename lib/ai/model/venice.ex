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

  Reasoning support here means specifically `supportsReasoningEffort`
  (the model accepts the `reasoning_effort` field on the wire). Many
  Venice models advertise `supportsReasoning: true` while still
  rejecting the effort field; sending the field to those models can
  produce silently-degraded responses or `<think>` block leakage that
  overflows the output cap. The capability flag below tracks the wire-
  level acceptance, not the model's internal reasoning behavior.

  Verify with `curl /api/v1/models` against `model_spec.capabilities.
  supportsReasoningEffort` whenever bumping a profile to a new model.

  | Profile        | Model id            | Context | reasoning_effort | web_search |
  | -------------- | ------------------- | ------- | ---------------- | ---------- |
  | smarter        | kimi-k2-6           | 256k    | yes              | yes        |
  | smart          | zai-org-glm-5-1     | 200k    | no               | yes        |
  | balanced       | zai-org-glm-5       | 256k    | no               | yes        |
  | fast           | zai-org-glm-4.7     | 198k    | no               | yes        |
  | large_context  | grok-41-fast        | 1M      | no               | yes        |
  | web_search     | qwen3-5-35b-a3b     | 256k    | no               | yes        |
  | coding         | kimi-k2-6 (= smarter) | 256k  | yes              | yes        |

  ## Profile aliasing

  `coding` and `smarter` both resolve to `kimi-k2-6` because the user's
  picks point both roles at the same Venice model. This is an explicit
  Venice-side decision, not a generic property of the provider
  abstraction. Other providers may pick different models for these two
  roles. Do NOT add cross-profile aliases (e.g. `coding == balanced`)
  unless the user has actually picked the same model for both.

  ## Citation handling note

  When `web_search?: true` is requested against a Venice model, the
  response includes structured citations under
  `venice_parameters.web_search_citations`. The Venice response parser
  appends a "Sources:" section to the assistant text so callers
  consuming the existing `{:ok, :msg, binary, usage}` contract see the
  citations without any orchestration-layer changes. See
  `AI.Provider.ResponseParser.Venice` for the implementation.
  """

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

  @spec smart() :: AI.Model.t()
  def smart(), do: glm_5_1(:low)

  @spec smarter() :: AI.Model.t()
  def smarter(), do: kimi_k2_6(:low)

  @spec balanced() :: AI.Model.t()
  def balanced(), do: glm_5(:medium)

  @spec fast() :: AI.Model.t()
  def fast(), do: glm_4_7(:low)

  @spec web_search() :: AI.Model.t()
  def web_search(), do: qwen3_5_35b_a3b(:medium)

  # Venice ships a coding-tuned profile (instruct-style training
  # optimized for code generation). The user's pick in
  # scratch/venice-models.md points coding at kimi-k2-6, the same model
  # used for `smarter`. The alias is intentional and Venice-specific;
  # do not assume coding == balanced just because the OpenAI catalog
  # does that.
  @spec coding() :: AI.Model.t()
  def coding(), do: kimi_k2_6(:low)

  @spec large_context(:smart | :balanced | :fast) :: AI.Model.t()
  # All three tiers map to grok-41-fast for now; we have a single 1M-
  # context model in the catalog. Tiers are kept distinct so future
  # additions can differentiate without changing the call sites.
  def large_context(:smart), do: grok_41_fast(:low)
  def large_context(:balanced), do: grok_41_fast(:medium)
  def large_context(:fast), do: grok_41_fast(:low)

  # ---------------------------------------------------------------------------
  # Concrete model factories. Each declares the Venice model slug, context
  # window, default reasoning level, and capability flags.
  #
  # All current Venice profiles support reasoning and web search; this is
  # not a provider-wide invariant (Venice could add a non-reasoning model
  # tomorrow) so each factory states it explicitly.
  # ---------------------------------------------------------------------------

  # kimi-k2-6 is the only profile that currently accepts the wire-level
  # `reasoning_effort` field. All other configured Venice models advertise
  # supportsReasoning: true but supportsReasoningEffort: false; their
  # capability flag is therefore false.
  @spec kimi_k2_6(atom) :: AI.Model.t()
  def kimi_k2_6(reasoning \\ :medium),
    do:
      AI.Model.new("kimi-k2-6", 256_000, reasoning,
        supports_reasoning: true,
        supports_web_search: true
      )

  @spec glm_5_1(atom) :: AI.Model.t()
  def glm_5_1(reasoning \\ :medium),
    do:
      AI.Model.new("zai-org-glm-5-1", 200_000, reasoning,
        supports_reasoning: false,
        supports_web_search: true
      )

  @spec glm_5(atom) :: AI.Model.t()
  def glm_5(reasoning \\ :medium),
    do:
      AI.Model.new("zai-org-glm-5", 256_000, reasoning,
        supports_reasoning: false,
        supports_web_search: true
      )

  @spec glm_4_7(atom) :: AI.Model.t()
  def glm_4_7(reasoning \\ :medium),
    do:
      AI.Model.new("zai-org-glm-4.7", 198_000, reasoning,
        supports_reasoning: false,
        supports_web_search: true
      )

  @spec grok_41_fast(atom) :: AI.Model.t()
  def grok_41_fast(reasoning \\ :medium),
    do:
      AI.Model.new("grok-41-fast", 1_000_000, reasoning,
        supports_reasoning: false,
        supports_web_search: true
      )

  @spec qwen3_5_35b_a3b(atom) :: AI.Model.t()
  def qwen3_5_35b_a3b(reasoning \\ :medium),
    do:
      AI.Model.new("qwen3-5-35b-a3b", 256_000, reasoning,
        supports_reasoning: false,
        supports_web_search: true
      )
end
