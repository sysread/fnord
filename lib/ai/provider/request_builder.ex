defmodule AI.Provider.RequestBuilder do
  @moduledoc """
  Behaviour for building chat-completion HTTP requests for a specific
  provider.

  An implementation owns three concerns that vary across LLM backends:

  - **API key acquisition** - which environment variables hold the key,
    in what priority order. fnord follows a `FNORD_<PROVIDER>_API_KEY` >
    `<PROVIDER>_API_KEY` pattern; the implementation reads the right pair.
  - **Header assembly** - the wire-level Authorization scheme and any
    provider-specific headers (e.g. signed wallet headers for Venice's
    x402 auth).
  - **Payload assembly** - the JSON body. Provider-specific concerns
    include where reasoning effort is encoded, how web search is requested
    (top-level `web_search_options` for OpenAI vs nested
    `venice_parameters` for Venice), how verbosity is encoded, and which
    optional fields are silently rejected by the API.

  ## Why this is a behaviour and not a function pointer

  The three callbacks share state implicitly: the API key feeds into the
  headers, and capability flags on the model feed into payload field
  choices. Keeping them in one module means the per-provider logic stays
  cohesive - a reader looking at "how do we talk to Venice?" reads one
  module, not three scattered helpers.

  ## Capability gating

  The request builder is the enforcement point for `AI.Model` capability
  flags. When a caller asks for web search against a model whose
  `:supports_web_search` is false, the builder must raise. Silently
  dropping the request would produce a non-search response that looks
  successful but does not match the caller's intent.
  """

  @type model :: AI.Model.t()
  @type msgs :: [map()]
  @type tools :: nil | [AI.Tools.tool_spec()]
  @type response_format :: nil | map
  @type web_search? :: boolean
  @type verbosity :: nil | String.t()

  @type headers :: [{String.t(), String.t()}]
  @type payload :: map

  @doc """
  Read the API key for this provider from the environment.

  Raises if no key is present. The error message should name the env vars
  the implementation looked at so the user can fix the problem without
  reading source.
  """
  @callback api_key!() :: binary | no_return

  @doc """
  Build the HTTP headers for a chat-completion request. Includes the
  authorization scheme and any provider-specific headers.
  """
  @callback build_headers(api_key :: binary) :: headers

  @doc """
  Build the JSON payload for a chat-completion request.

  Receives all the abstract request inputs the orchestration layer knows
  about. Returns a map ready to be JSON-encoded and posted.

  Implementations must:
    - Honor capability flags on `model` (drop fields the model does not
      accept; raise on `web_search?` against a non-web-search model).
    - Default `response_format` to `%{type: "text"}` when nil so the
      result respects the OpenAI-compatible default.
    - Omit (rather than null-out) optional fields that do not apply.
  """
  @callback build_payload(
              model,
              msgs,
              tools,
              response_format,
              web_search?,
              verbosity
            ) :: payload
end
