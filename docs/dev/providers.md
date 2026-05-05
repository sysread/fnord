# AI providers

fnord talks to LLMs through a small provider abstraction so the same code paths can target OpenAI, Venice, or any future backend without rewrites. This doc covers how the abstraction is shaped today, what each piece is responsible for, and how to add a new provider.

## Layers

The provider abstraction is split across a few modules so each one owns a single concern.

| Layer | Module | Responsibility |
| --- | --- | --- |
| Selection | `AI.Provider` | Resolve the active provider from CLI/env/settings; route behaviour kinds (`:endpoint`, `:model`, `:request_builder`, `:response_parser`, ...) to concrete modules. |
| HTTP | `AI.Endpoint` | Provider-agnostic retry/backoff harness. Uses the active provider's `endpoint_path/0` + `endpoint_error_classify/4`. |
| Endpoint | `AI.Endpoint.OpenAI` (and future `AI.Endpoint.Venice`) | URL + provider-specific error classification. |
| Orchestration | `AI.CompletionAPI` | Thin spine: get key + headers + payload from the active provider's request builder, post via `AI.Endpoint`, dispatch the body through the active provider's response parser. Owns no provider-specific logic. |
| Request builder | `AI.Provider.RequestBuilder.OpenAI` (and future `AI.Provider.RequestBuilder.Venice`) | API key acquisition (env var lookup), header assembly (Authorization scheme), and JSON payload assembly. Honors `AI.Model` capability flags - drops fields the model does not accept; raises on `web_search?` against a non-search model. |
| Response parser | `AI.Provider.ResponseParser.OpenAI` (and future `AI.Provider.ResponseParser.Venice`) | Turn raw HTTP success/error bodies into the `{:ok, :msg, ...}` / `{:ok, :tool, ...}` / `{:error, ...}` tuples the orchestration loop in `AI.Completion` understands. Owns the special-case `:context_length_exceeded` extraction. |
| Web search | `AI.Provider.WebSearch.OpenAI` (and future `AI.Provider.WebSearch.Venice`) | Provider-native web search. OpenAI runs a sub-completion against a search-preview model; Venice will set `venice_parameters.enable_web_search` on a single inline call. Single string-in, string-out contract for `AI.Tools.WebSearch`. |
| Model catalog | `AI.Model.OpenAI` (and future `AI.Model.Venice`) | Named profile factories (`smart/0`, `balanced/0`, `web_search/0`, ...). Each profile is an `AI.Model.t` populated with model identifier, context window, default reasoning level, and capability flags. |

## `AI.Model` capability flags

`AI.Model.t` carries two boolean capability flags that the request builder uses to gate optional payload fields.

| Flag | Meaning |
| --- | --- |
| `:supports_reasoning` | The model accepts the `reasoning_effort` field on the wire. When `false`, the request builder must omit the field regardless of `model.reasoning`. |
| `:supports_web_search` | The model can perform a web search as part of its response. When `false` and the caller passes `web_search?: true`, the request builder raises - asking for a search against a non-search model is a caller bug. |

Why on the model and not the provider:

- Capability is per-model, not per-provider. OpenAI has a mix today (gpt-5 family supports `reasoning_effort`; gpt-4.1 family does not; only `gpt-4o-mini-search-preview` accepts `web_search_options`). Venice currently has uniformity but that is not guaranteed forever.
- Encoding the truth on the profile struct keeps the contract auditable. Profile factories declare capabilities explicitly; the request builder consults the flag instead of pattern-matching on model-name strings (which change between vendor releases and silently break inferred behavior).

Default behavior in `AI.Model.new/N`: both flags default to `false`. New profile factories must opt in by passing `supports_reasoning: true` or `supports_web_search: true` for capabilities the model actually has.

## Provider resolution

`AI.Provider.init/0` runs once at startup from `Fnord.set_globals/1`. It resolves the active provider with this priority (highest first):

1. Runtime override at `Services.Globals.get_env(:fnord, :ai_provider, ...)`. Written by `set_globals/1` when a command's spec declares a `--provider` option.
2. `FNORD_AI_PROVIDER` environment variable.
3. `settings.json` top-level `"ai_provider"` key.
4. Default: `"openai"`.

Resolution validates against `AI.Provider.known_providers/0` and raises immediately on an unknown value. Silent fallback to the default would hide configuration bugs that are easier to diagnose at startup than at first-LLM-call time.

After `init/0` runs, `AI.Provider.current/0` is a cheap globals read; callers can hit it as often as they need.

## Adding a new provider

The high-level recipe:

1. **Endpoint module**: implement `AI.Endpoint` behaviour - `endpoint_path/0` and `endpoint_error_classify/4`. Don't add retry logic here; the harness owns it.
2. **Model catalog module**: factories for each named profile (`smart/0`, `balanced/0`, ...). Set capability flags accurately for each model. Document the capability matrix in the moduledoc.
3. **Request builder module**: implement `AI.Provider.RequestBuilder` behaviour - `api_key!/0`, `build_headers/1`, `build_payload/6`. Honor capability flags on the model. Drop fields the API does not accept (rather than emit nil-valued keys that strict providers reject).
4. **Response parser module**: implement `AI.Provider.ResponseParser` behaviour - `parse_success/1` and `parse_error/2`. Surface the orchestration layer's tagged tuples; preserve `:context_length_exceeded` and `:api_unavailable` special cases.
5. **Web search module**: implement `AI.Provider.WebSearch` behaviour - `search/1`. The strategy is whatever fits the provider best (sub-completion, inline flag, external service); the contract is a string in, string out.
6. **Provider key**: add the new key to `AI.Provider.known_providers/0` and add dispatch branches in `AI.Provider.module_for/1` for each behaviour kind.

API key conventions follow the existing OpenAI pattern: a fnord-specific override (`FNORD_<PROVIDER>_API_KEY`) takes precedence over the upstream-canonical name (`<PROVIDER>_API_KEY`).

## Why the indirection

The single string `ai_provider` is an explicit pivot. Avoiding it would mean either:

- Hard-coding provider names at every call site (which is what we had before this abstraction).
- Inferring the provider from a model identifier (fragile - model names move between vendors and within vendors).

Keeping the pivot explicit means a single place to flip the provider for a single request (override globals before the call) and a single place to add a new provider's plumbing.
