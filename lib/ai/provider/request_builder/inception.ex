defmodule AI.Provider.RequestBuilder.Inception do
  @moduledoc """
  Inception Labs implementation of the `AI.Provider.RequestBuilder` behaviour.

  Inception is OpenAI-API-compatible at the chat-completions surface
  for the basics: `messages`, `model`, `tools`, `response_format`. The
  builder emits exactly those fields and nothing else - the single
  hosted model (`mercury-2`) does not accept `reasoning_effort`,
  `web_search_options`, or `verbosity`, so we don't emit them.

  ## API key resolution

  Reads `FNORD_INCEPTION_API_KEY` first, falling back to
  `INCEPTION_API_KEY`. Same fnord-prefix-wins pattern the other
  providers use, so a user can pin a different key per fnord
  invocation without disturbing other tools that read the canonical
  upstream env var.

  ## System role

  Inception follows the legacy `system` role convention (no
  `developer` role per the OpenAI Responses API). Sending `developer`-
  shaped messages would likely be silently downgraded the way Venice
  does it.
  """

  @behaviour AI.Provider.RequestBuilder

  @impl AI.Provider.RequestBuilder
  def api_key!() do
    ["FNORD_INCEPTION_API_KEY", "INCEPTION_API_KEY"]
    |> Enum.find_value(fn k -> Util.Env.get_env(k, nil) end)
    |> case do
      nil ->
        raise "Either FNORD_INCEPTION_API_KEY or INCEPTION_API_KEY environment variable must be set"

      api_key ->
        api_key
    end
  end

  @impl AI.Provider.RequestBuilder
  def system_role(), do: "system"

  @impl AI.Provider.RequestBuilder
  def build_headers(api_key) when is_binary(api_key) do
    [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]
  end

  @impl AI.Provider.RequestBuilder
  def build_payload(model, msgs, tools, response_format, web_search?, _verbosity) do
    # Same fail-fast contract as the other providers: a caller asking
    # for web search against a model that cannot perform it is a
    # programming error. Inception has no web-search-capable model
    # today; this raise surfaces the bug at the call site rather than
    # at the API boundary.
    if web_search? and not Map.get(model, :supports_web_search, false) do
      raise ArgumentError,
            "web_search? requested but model #{inspect(model.model)} does not " <>
              "support web search on Inception. Inception has no web-search-" <>
              "capable model today; route web search to a different provider."
    end

    response_format = response_format || %{type: "text"}

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
  end

  # Inception accepts the OpenAI-shaped `reasoning_effort` field on
  # reasoning-capable models. Two gates apply, mirroring the OpenAI
  # builder:
  #   1. `model.supports_reasoning` must be true. Without it, no field
  #      is emitted regardless of the configured level.
  #   2. The level must map to a documented wire string. Unmapped
  #      levels (e.g. `:none`) fall through to omission rather than
  #      guessing at an unsupported wire form.
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
