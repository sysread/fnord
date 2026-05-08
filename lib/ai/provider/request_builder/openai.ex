defmodule AI.Provider.RequestBuilder.OpenAI do
  @moduledoc """
  OpenAI implementation of the `AI.Provider.RequestBuilder` behaviour.

  Owns the OpenAI-shaped wire format for chat-completion requests:

  - Bearer auth header with the API key
  - Top-level `reasoning_effort` field (gated on `model.supports_reasoning`)
  - Top-level `web_search_options` field (gated on
    `model.supports_web_search`)
  - Top-level `verbosity` field
  - `response_format` defaulting to `%{type: "text"}`

  ## API key resolution

  Reads `FNORD_OPENAI_API_KEY` first, falling back to `OPENAI_API_KEY`.
  The fnord-prefixed override exists so users can pin a different key per
  fnord invocation without disturbing other tools that read the canonical
  upstream env var.

  ## Capability flags drive payload shape

  Optional fields are emitted only when the model declares the matching
  capability. This is the authoritative place where capability flags get
  enforced - readers tracing "why didn't my reasoning_effort go through"
  should look here.
  """

  @behaviour AI.Provider.RequestBuilder

  @impl AI.Provider.RequestBuilder
  def api_key!() do
    # Priority order: fnord-specific override beats the upstream-canonical
    # name. Same pattern Venice will follow with FNORD_VENICE_API_KEY.
    #
    # Note: an empty-string env var passes through as a valid "key" here.
    # That looks like a bug but is load-bearing: the test harness sets
    # both vars to "" to prevent accidental live-API access, and many
    # tests mock `AI.Endpoint.post_json/3` rather than the request layer.
    # Tightening this to also reject "" is desirable but requires
    # upgrading those test mocks to set fake non-empty keys; left as a
    # follow-up.
    ["FNORD_OPENAI_API_KEY", "OPENAI_API_KEY"]
    |> Enum.find_value(fn k -> Util.Env.get_env(k, nil) end)
    |> case do
      nil ->
        raise "Either FNORD_OPENAI_API_KEY or OPENAI_API_KEY environment variable must be set"

      api_key ->
        api_key
    end
  end

  @impl AI.Provider.RequestBuilder
  # OpenAI's newer Responses-API-era models (GPT-5, GPT-4.1, o4) prefer
  # the `developer` role over the legacy `system` role. Both are still
  # accepted, but `developer` is the canonical one for the model class
  # fnord targets.
  def system_role(), do: "developer"

  @impl AI.Provider.RequestBuilder
  def build_headers(api_key) when is_binary(api_key) do
    [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]
  end

  @impl AI.Provider.RequestBuilder
  def build_payload(model, msgs, tools, response_format, web_search?, verbosity) do
    # If a caller asks for web search against a model that cannot perform
    # it, that is a programming error - the caller picked the wrong
    # profile. Raise here so the bug is caught at the call site rather
    # than at the API boundary, where the error would be a confusing 400.
    if web_search? and not Map.get(model, :supports_web_search, false) do
      raise ArgumentError,
            "web_search? requested but model #{inspect(model.model)} does not " <>
              "support web search. Use AI.Model.web_search() or another " <>
              "web-search-capable profile."
    end

    response_format =
      if is_nil(response_format) do
        # OpenAI's default. Send it explicitly so the request shape is
        # stable across nil-vs-not callers.
        %{type: "text"}
      else
        response_format
      end

    # Each `Map.merge/2` below either contributes a provider field or
    # contributes nothing. This keeps the payload free of nil-valued
    # keys that strict providers would reject.
    %{
      model: model.model,
      messages: msgs,
      response_format: response_format
    }
    |> Map.merge(
      case tools do
        nil -> %{}
        tools -> %{tools: tools}
      end
    )
    |> Map.merge(reasoning_effort_field(model))
    |> Map.merge(
      case verbosity do
        nil -> %{}
        value -> %{verbosity: value}
      end
    )
    |> Map.merge(
      if web_search? do
        # The OpenAI search-preview models accept this empty map as a
        # signal to perform a web search. Non-search models would reject
        # it, which is why the capability check above gates emission.
        %{web_search_options: %{}}
      else
        %{}
      end
    )
  end

  # Resolve the reasoning_effort field for the request payload.
  #
  # Two gates:
  #   1. The model must declare `supports_reasoning: true`. Without it,
  #      no reasoning_effort field is emitted regardless of the
  #      configured `model.reasoning` level. This prevents the API from
  #      rejecting the request on models that don't accept the field
  #      (4.1 family, mini/nano variants).
  #   2. The level itself must map to a wire string. OpenAI accepts
  #      "low" / "medium" / "high" today. `:none`, `:minimal`, `:default`
  #      and friends fall through to omission - safer to let the model
  #      use its built-in default than to guess at an unmapped wire form.
  #      When OpenAI ships acceptance for `"minimal"`, add the case below.
  @spec reasoning_effort_field(AI.Model.t()) :: map
  defp reasoning_effort_field(%{supports_reasoning: false}), do: %{}

  defp reasoning_effort_field(%{reasoning: level}) do
    case level do
      :low -> %{reasoning_effort: "low"}
      :medium -> %{reasoning_effort: "medium"}
      :high -> %{reasoning_effort: "high"}
      _ -> %{}
    end
  end
end
