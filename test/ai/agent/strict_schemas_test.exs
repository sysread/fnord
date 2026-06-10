defmodule AI.Agent.StrictSchemasTest do
  use Fnord.TestCase, async: true

  # OpenAI's Responses-API strict structured-output validator rejects any
  # JSON schema where the `required` array does not list every key in
  # `properties`. Chat Completions used to silently accept partial-required
  # schemas; the Responses API does not. Missing a key in `required`
  # surfaces at runtime as:
  #
  #     Invalid schema for response_format 'X': In context=(), 'required' is
  #     required to be supplied and to be an array including every key in
  #     properties. Missing 'Y'.
  #
  # ...which kills the call after retries. This test walks every
  # @response_format module attribute we expose and asserts the strict
  # rule recursively, so a new schema with this bug fails CI instead of
  # production.
  #
  # Optionality is expressed via nullable union types
  # (`type: ["string", "null"]`) AND the key being in `required`.
  #
  # To register a new schema-exposing agent, add its module + accessor to
  # @sources below.

  @single_accessor [
    AI.Agent.Nomenclater,
    AI.Agent.Code.RePatcher,
    AI.Agent.Code.TaskValidator,
    AI.Agent.Code.TaskImplementor,
    AI.Agent.Code.Patcher
  ]

  @multi_accessor [
    AI.Agent.Code.TaskPlanner,
    AI.Agent.Review.Decomposer,
    AI.Agent.Review.Reviewer
  ]

  describe "every response_format is strict-mode legal" do
    for mod <- @single_accessor do
      test "#{inspect(mod)}.__response_format__/0" do
        schema = unquote(mod).__response_format__()
        violations = strict_violations(schema, [inspect(unquote(mod))])

        assert violations == [],
               "Strict-mode violations in #{inspect(unquote(mod))}:\n" <>
                 Enum.map_join(violations, "\n", &"  - #{&1}")
      end
    end

    for mod <- @multi_accessor do
      test "#{inspect(mod)}.__response_formats__/0" do
        violations =
          unquote(mod).__response_formats__()
          |> Enum.with_index()
          |> Enum.flat_map(fn {schema, idx} ->
            strict_violations(schema, ["#{inspect(unquote(mod))}[#{idx}]"])
          end)

        assert violations == [],
               "Strict-mode violations in #{inspect(unquote(mod))}:\n" <>
                 Enum.map_join(violations, "\n", &"  - #{&1}")
      end
    end
  end

  # -----------------------------------------------------------------------
  # Validator
  # -----------------------------------------------------------------------

  # A response_format wrapper has shape:
  #   %{type: "json_schema", json_schema: %{name:, schema: ...}}
  # The actual schema lives at .json_schema.schema. Walk from there.
  defp strict_violations(%{type: "json_schema", json_schema: %{schema: schema}}, path) do
    walk(schema, path)
  end

  defp strict_violations(%{"type" => "json_schema", "json_schema" => %{"schema" => schema}}, path) do
    walk(schema, path)
  end

  defp strict_violations(other, path),
    do: ["#{Enum.join(path, ".")}: not a json_schema wrapper (#{inspect(other, limit: 3)})"]

  # Walk a schema fragment. The strict rule fires on any object-type node
  # with `properties`. Array `items` and nested `properties` values are
  # walked recursively.
  defp walk(node, path) when is_map(node) do
    own =
      if object_with_properties?(node) do
        check_object(node, path)
      else
        []
      end

    own ++ walk_children(node, path)
  end

  defp walk(_other, _path), do: []

  defp object_with_properties?(node) do
    type = type_of(node)
    Map.has_key?(node, :properties) and (type == "object" or "object" in List.wrap(type))
  end

  defp check_object(node, path) do
    properties = Map.get(node, :properties, %{})
    required = Map.get(node, :required, []) |> Enum.sort()

    prop_names =
      properties
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.sort()

    missing = prop_names -- required
    extra = required -- prop_names

    cond do
      missing != [] and extra != [] ->
        [
          "#{Enum.join(path, ".")}: required missing #{inspect(missing)}, required has unknown keys #{inspect(extra)}"
        ]

      missing != [] ->
        [
          "#{Enum.join(path, ".")}: required missing #{inspect(missing)} - " <>
            "Responses-API strict mode requires every property in `required`. Use " <>
            "`type: [\"X\", \"null\"]` for genuinely-optional fields."
        ]

      extra != [] ->
        [
          "#{Enum.join(path, ".")}: required has unknown keys #{inspect(extra)} not in properties"
        ]

      true ->
        []
    end
  end

  defp walk_children(node, path) do
    props_children =
      case Map.get(node, :properties) do
        %{} = props ->
          Enum.flat_map(props, fn {k, v} -> walk(v, path ++ ["properties.#{k}"]) end)

        _ ->
          []
      end

    items_children =
      case Map.get(node, :items) do
        nil -> []
        items -> walk(items, path ++ ["items"])
      end

    props_children ++ items_children
  end

  defp type_of(%{type: t}), do: t
  defp type_of(%{"type" => t}), do: t
  defp type_of(_), do: nil
end
