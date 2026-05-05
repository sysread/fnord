defmodule AI.Model.Provider do
  @moduledoc """
  Behaviour contract for a provider's model catalog.

  Every provider that fnord can target must implement this behaviour
  and supply a complete set of named profiles. The compiler enforces
  the contract: forgetting a callback is a `@behaviour` warning, not a
  runtime surprise on first use.

  ## Why a behaviour and not a duck-typed module

  Earlier iterations dispatched profile factories through
  `apply(AI.Provider.module_for(:model), :coding, [])` and similar.
  Adding a new provider was easy to get wrong - if the new module
  forgot to implement `coding/0`, the failure mode was a runtime
  `UndefinedFunctionError` at the first request, after fnord had
  already been running for a while. Codifying the contract here turns
  that into a compile-time guarantee.

  ## What every provider must supply

  Each callback returns a fully-populated `AI.Model.t` with capability
  flags set to match what the provider's API actually accepts for that
  model. Callbacks are intentionally arity-0 (no caller-side knobs):
  per-call overrides like `with_reasoning/2` happen on the returned
  struct, not on the factory.

  Profiles map to roles, not to model families. The `coding/0` profile
  is a role - "the model we use for code-edit pipelines" - and the
  provider chooses whichever model in its catalog best fits the role.
  Some providers (Venice) ship a coding-tuned model and `coding/0`
  returns that; some (OpenAI) do not, and `coding/0` aliases another
  profile. The aliasing decision is per-provider, not generic. Callers
  must never assume that two different profile factories return the
  same model.

  ## large_context arity

  `large_context/1` takes a tier hint (`:smart` / `:balanced` / `:fast`)
  to let callers express "I need a 1M-context model and I want it to
  be cheap" vs "I need a 1M-context model and I want it to be smart."
  Providers may collapse all three tiers to one model when their
  catalog has a single large-context option (Venice does today); the
  arity is preserved so call sites do not have to change when the
  provider catalog grows a tiered set.
  """

  @doc "The user-facing 'smart' profile. Default for the coordinator's main loop."
  @callback smart() :: AI.Model.t()

  @doc "The user-facing 'smarter' profile. Used when the user opts into a heavier model."
  @callback smarter() :: AI.Model.t()

  @doc "The user-facing 'balanced' profile. Mid-tier; used by per-tool sub-agents."
  @callback balanced() :: AI.Model.t()

  @doc """
  The user-facing 'fast' profile.

  This profile runs constantly in fnord (nomenclater, intuition, motd,
  notes, compaction, summaries) and is the cost-sensitive tier. Pick
  the cheapest model in the catalog that still produces usable output
  for short, structured tasks.
  """
  @callback fast() :: AI.Model.t()

  @doc """
  The web-search profile. Returned model must have
  `supports_web_search: true` because the request builder will reject
  a `web_search?: true` request against any other model.
  """
  @callback web_search() :: AI.Model.t()

  @doc """
  Large-context profile, with a tier hint for cost/quality preference.
  Providers may collapse all three tiers to a single model when the
  catalog has a single large-context option.
  """
  @callback large_context(:smart | :balanced | :fast) :: AI.Model.t()

  @doc """
  Coding-tuned profile. Used by the code-edit pipeline (planner,
  implementor, validator, patcher, repatcher).

  Implementations must NOT assume that `coding/0` aliases any other
  profile - that is a per-provider decision. Some providers ship
  dedicated coding-tuned models; some do not.
  """
  @callback coding() :: AI.Model.t()
end
