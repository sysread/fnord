defmodule AI.Tools.Params do
  @moduledoc """
  JSON Schema validation and coercion for tool call arguments.

  Provides centralized argument validation for all AI tools, including
  type coercion, required field checking, enum validation, and support
  for JSON Schema composition keywords (`anyOf`, `oneOf`, `allOf`).
  `$ref`/`$defs` are not supported.

  ## Usage

  Called centrally by `AI.Tools.perform_tool_call/3` to validate arguments
  against a tool's spec before execution. Also used by `Frobs.Prompt` for
  interactive parameter collection.
  """

  @composition_keywords ["anyOf", "oneOf", "allOf"]

  @doc """
  Validate and coerce tool call arguments against a tool spec.

  Accepts the full tool spec (as returned by `module.spec()`), a raw spec
  with a `parameters` key, or a pre-normalized `%{properties: ..., required: ...}`.

  Returns `{:ok, coerced_args}` or an `AI.Tools.args_error()`.
  """
  @spec validate_json_args(map(), map()) ::
          {:ok, map()}
          | {:error, :missing_argument, binary()}
          | {:error, :invalid_argument, binary()}
  def validate_json_args(%{function: %{parameters: params}}, args) do
    validate_json_args(%{parameters: params}, args)
  end

  def validate_json_args(spec, args) do
    case validate_all_args(spec, args) do
      {:ok, coerced} ->
        {:ok, coerced}

      {:error, {:missing_required, keys}} ->
        {:error, :missing_argument, "missing required arguments: #{Enum.join(keys, ", ")}"}

      {:error, _reason, msg} ->
        {:error, :invalid_argument, msg}
    end
  end

  @doc """
  Normalize a parsed spec (from Jason) into a canonical map with string keys.

  Returns `{:ok, %{properties: map, required: list}}` or `{:error, reason, msg}`.
  """
  @spec normalize_spec(map()) :: {:ok, map()} | {:error, atom(), String.t()}
  def normalize_spec(spec) do
    params = Map.get(spec, "parameters") || Map.get(spec, :parameters)

    cond do
      !is_map(params) ->
        {:error, :invalid_parameters, "spec.parameters must be an object"}

      true ->
        props = Map.get(params, "properties") || Map.get(params, :properties) || %{}
        required = Map.get(params, "required") || Map.get(params, :required) || []

        if !is_map(props) do
          {:error, :invalid_properties, "spec.parameters.properties must be an object"}
        else
          normalized_props =
            props
            |> Enum.map(fn {k, v} -> {to_string(k), normalize_schema(v)} end)
            |> Map.new()

          required_list =
            case required do
              list when is_list(list) -> Enum.map(list, &to_string/1)
              _ -> []
            end

          {:ok, %{properties: normalized_props, required: required_list}}
        end
    end
  end

  @doc """
  Recursively normalize a schema map to string keys, including any
  composition keyword sub-schemas.
  """
  @spec normalize_schema(map()) :: map()
  def normalize_schema(schema) do
    schema
    |> Enum.map(fn {k, v} -> {to_string(k), normalize_schema_value(to_string(k), v)} end)
    |> Map.new()
  end

  defp normalize_schema_value(key, value) when key in @composition_keywords do
    Enum.map(value, fn
      %{} = sub -> normalize_schema(sub)
      other -> other
    end)
  end

  defp normalize_schema_value("properties", value) do
    value
    |> Enum.map(fn {k, v} -> {to_string(k), normalize_schema(v)} end)
    |> Map.new()
  end

  defp normalize_schema_value("items", %{} = value) do
    normalize_schema(value)
  end

  defp normalize_schema_value(_key, value), do: value

  @doc """
  Return a deterministic parameter list: [{name, schema, required?}].
  """
  @spec param_list(map() | %{properties: map(), required: [binary()]}) ::
          {:ok, list()} | {:error, atom(), String.t()}
  def param_list(%{properties: _} = normalized) do
    build_param_list(normalized)
  end

  def param_list(spec) do
    with {:ok, normalized} <- normalize_spec(spec) do
      build_param_list(normalized)
    end
  end

  defp build_param_list(%{properties: props, required: required}) do
    list =
      props
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map(fn name -> {name, Map.fetch!(props, name), name in required} end)

    {:ok, list}
  end

  @doc """
  Validate and coerce a single parameter value according to schema.

  Supports flat `type`-based schemas and composition keywords (`anyOf`,
  `oneOf`, `allOf`). Resolution order: type > anyOf > oneOf > allOf.

  Returns `{:ok, coerced}` or `{:error, reason, message}`.
  """
  @spec validate_and_coerce_param(map(), any()) :: {:ok, any()} | {:error, atom(), String.t()}
  def validate_and_coerce_param(schema, value) do
    case resolve_schema_type(schema) do
      {:ok, type} ->
        coerce_by_type(type, schema, value)

      {:composition, "anyOf", sub_schemas} ->
        coerce_any_of(sub_schemas, value)

      {:composition, "oneOf", sub_schemas} ->
        coerce_one_of(sub_schemas, value)

      {:composition, "allOf", sub_schemas} ->
        coerce_all_of(sub_schemas, value)

      {:error, :unresolvable} ->
        {:error, :unresolvable_schema,
         "schema has no 'type' or composition keyword (anyOf, oneOf, allOf)"}
    end
  end

  # ---------------------------------------------------------------------------
  # Composition keyword handlers
  # ---------------------------------------------------------------------------

  defp coerce_any_of(sub_schemas, value) do
    result =
      Enum.reduce_while(sub_schemas, {:error, []}, fn sub, {:error, failures} ->
        case validate_and_coerce_param(normalize_schema(sub), value) do
          {:ok, coerced} -> {:halt, {:ok, coerced}}
          {:error, reason, msg} -> {:cont, {:error, [{reason, msg} | failures]}}
        end
      end)

    case result do
      {:ok, _} = ok ->
        ok

      {:error, failures} ->
        {:error, :no_matching_schema,
         "value #{inspect(value)} did not match any sub-schema: #{inspect(Enum.reverse(failures))}"}
    end
  end

  defp coerce_one_of(sub_schemas, value) do
    {matches, failures} =
      Enum.reduce(sub_schemas, {[], []}, fn sub, {matches, failures} ->
        case validate_and_coerce_param(normalize_schema(sub), value) do
          {:ok, coerced} -> {[coerced | matches], failures}
          {:error, reason, msg} -> {matches, [{reason, msg} | failures]}
        end
      end)

    case matches do
      [single] ->
        {:ok, single}

      [] ->
        {:error, :no_matching_schema,
         "value #{inspect(value)} did not match any oneOf sub-schema: #{inspect(Enum.reverse(failures))}"}

      _multiple ->
        {:error, :multiple_schemas_matched,
         "value #{inspect(value)} matched #{length(matches)} oneOf sub-schemas (expected exactly 1)"}
    end
  end

  defp coerce_all_of(sub_schemas, value) do
    merged = merge_schemas(sub_schemas)
    validate_and_coerce_param(merged, value)
  end

  @doc """
  Merge a list of schemas into a single schema. Used for `allOf` resolution.

  Combines `type` (last wins), `properties` (deep merge), `required` (union),
  and `enum` (intersection). Other keys are merged with last-wins semantics.
  """
  @spec merge_schemas([map()]) :: map()
  def merge_schemas(schemas) do
    schemas
    |> Enum.map(&normalize_schema/1)
    |> Enum.reduce(%{}, fn schema, acc ->
      acc
      |> merge_key("type", schema)
      |> merge_properties(schema)
      |> merge_required(schema)
      |> merge_enum(schema)
      |> merge_remaining(schema)
    end)
  end

  defp merge_key(acc, key, schema) do
    case Map.get(schema, key) do
      nil -> acc
      val -> Map.put(acc, key, val)
    end
  end

  defp merge_properties(acc, schema) do
    case Map.get(schema, "properties") do
      nil ->
        acc

      new_props ->
        existing = Map.get(acc, "properties", %{})

        merged =
          Map.merge(existing, new_props, fn _key, existing_prop, new_prop ->
            merge_schemas([existing_prop, new_prop])
          end)

        Map.put(acc, "properties", merged)
    end
  end

  defp merge_required(acc, schema) do
    case Map.get(schema, "required") do
      nil ->
        acc

      new_req ->
        existing = Map.get(acc, "required", [])
        Map.put(acc, "required", Enum.uniq(existing ++ new_req))
    end
  end

  defp merge_enum(acc, schema) do
    case Map.get(schema, "enum") do
      nil ->
        acc

      new_enum ->
        case Map.get(acc, "enum") do
          nil -> Map.put(acc, "enum", new_enum)
          existing -> Map.put(acc, "enum", Enum.filter(existing, &(&1 in new_enum)))
        end
    end
  end

  defp merge_remaining(acc, schema) do
    merge_keys = ["type", "properties", "required", "enum"]
    remaining = Map.drop(schema, merge_keys)
    Map.merge(acc, remaining)
  end

  # ---------------------------------------------------------------------------
  # Type-based coercion (existing behavior)
  # ---------------------------------------------------------------------------

  defp coerce_by_type(type, schema, value) do
    enum = Map.get(schema, "enum")

    case type do
      "string" ->
        coerce_string(value, enum)

      "integer" ->
        case coerce_integer(value) do
          {:ok, i} -> maybe_check_enum({:ok, i}, enum)
          {:error, msg} -> {:error, :coercion_failed, msg}
        end

      "number" ->
        case coerce_number(value) do
          {:ok, n} -> maybe_check_enum({:ok, n}, enum)
          {:error, msg} -> {:error, :coercion_failed, msg}
        end

      "boolean" ->
        case coerce_boolean(value) do
          {:ok, b} -> maybe_check_enum({:ok, b}, enum)
          {:error, msg} -> {:error, :coercion_failed, msg}
        end

      "null" ->
        if value == nil do
          {:ok, nil}
        else
          {:error, :coercion_failed, "expected null, got #{inspect(value)}"}
        end

      "array" ->
        coerce_array(schema, value)

      "object" ->
        coerce_object(schema, value)

      other ->
        {:error, :invalid_type, "unsupported or invalid type '#{inspect(other)}'"}
    end
  end

  defp coerce_string(nil, _enum), do: {:error, :coercion_failed, "expected string, got nil"}
  defp coerce_string(value, enum) when is_binary(value), do: maybe_check_enum({:ok, value}, enum)
  defp coerce_string(value, enum), do: maybe_check_enum({:ok, to_string(value)}, enum)

  defp coerce_array(schema, value) do
    if is_list(value) do
      items_schema = Map.get(schema, "items")

      if items_schema do
        Enum.with_index(value)
        |> Enum.reduce_while({:ok, []}, fn {el, idx}, {:ok, acc} ->
          case validate_and_coerce_param(normalize_schema(items_schema), el) do
            {:ok, coerced} ->
              {:cont, {:ok, acc ++ [coerced]}}

            {:error, a, m} ->
              {:halt, {:error, :invalid_param, "array item at index #{idx}: #{inspect({a, m})}"}}
          end
        end)
      else
        {:ok, value}
      end
    else
      {:error, :invalid_type, "expected array (list), got #{inspect(value)}"}
    end
  end

  defp coerce_object(schema, value) do
    if is_map(value) do
      properties = Map.get(schema, "properties", %{})
      required = Map.get(schema, "required", [])

      norm_props =
        properties
        |> Enum.map(fn {k, v} -> {to_string(k), normalize_schema(v)} end)
        |> Map.new()

      missing =
        required
        |> Enum.map(&to_string/1)
        |> Enum.filter(fn k -> not Map.has_key?(value, k) end)

      if missing != [] do
        {:error, :missing_required, "object missing required keys: #{inspect(missing)}"}
      else
        Enum.reduce_while(Map.to_list(value), {:ok, %{}}, fn {k, v}, {:ok, acc} ->
          name = to_string(k)

          case Map.get(norm_props, name) do
            nil ->
              {:cont, {:ok, Map.put(acc, name, v)}}

            sch ->
              case validate_and_coerce_param(sch, v) do
                {:ok, coerced} -> {:cont, {:ok, Map.put(acc, name, coerced)}}
                {:error, a, m} -> {:halt, {:error, a, "object.#{name}: #{m}"}}
              end
          end
        end)
      end
    else
      {:error, :invalid_type, "expected object (map), got #{inspect(value)}"}
    end
  end

  # ---------------------------------------------------------------------------
  # Enum and coercion helpers
  # ---------------------------------------------------------------------------

  defp maybe_check_enum({:ok, v}, nil), do: {:ok, v}

  defp maybe_check_enum({:ok, v}, enum) do
    if Enum.any?(enum, fn e -> e == v end) do
      {:ok, v}
    else
      {:error, :enum_mismatch, "value #{inspect(v)} not in enum #{inspect(enum)}"}
    end
  end

  defp coerce_integer(i) when is_integer(i), do: {:ok, i}
  defp coerce_integer(f) when is_float(f) and trunc(f) == f, do: {:ok, trunc(f)}

  defp coerce_integer(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {int, ""} -> {:ok, int}
      _ -> {:error, "cannot coerce #{inspect(s)} to integer"}
    end
  end

  defp coerce_integer(_), do: {:error, "cannot coerce value to integer"}

  defp coerce_number(n) when is_number(n), do: {:ok, n}

  defp coerce_number(s) when is_binary(s) do
    case Float.parse(String.trim(s)) do
      {f, ""} ->
        {:ok, f}

      _ ->
        case Integer.parse(String.trim(s)) do
          {i, ""} -> {:ok, i * 1.0}
          _ -> {:error, "cannot coerce #{inspect(s)} to number"}
        end
    end
  end

  defp coerce_number(_), do: {:error, "cannot coerce value to number"}

  defp coerce_boolean(b) when is_boolean(b), do: {:ok, b}

  defp coerce_boolean(s) when is_binary(s) do
    case String.trim(String.downcase(s)) do
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      "1" -> {:ok, true}
      "0" -> {:ok, false}
      "yes" -> {:ok, true}
      "no" -> {:ok, false}
      other -> {:error, "cannot coerce #{inspect(other)} to boolean"}
    end
  end

  defp coerce_boolean(1), do: {:ok, true}
  defp coerce_boolean(0), do: {:ok, false}
  defp coerce_boolean(_), do: {:error, "cannot coerce value to boolean"}

  # ---------------------------------------------------------------------------
  # Prefilled and full argument validation
  # ---------------------------------------------------------------------------

  @doc """
  Validate a map of prefilled args against a spec. Rejects unknown keys and
  coerces known keys. Returns {:ok, coerced_map} or {:error, reason, message}.
  """
  @spec validate_prefilled_args(map() | %{properties: map(), required: [binary()]}, map()) ::
          {:ok, map()} | {:error, atom(), any()}
  def validate_prefilled_args(spec_or_normalized, args_map) do
    normalized =
      case spec_or_normalized do
        %{properties: _} = n -> {:ok, n}
        _ -> normalize_spec(spec_or_normalized)
      end

    case normalized do
      {:error, reason, msg} ->
        {:error, reason, msg}

      {:ok, norm} ->
        case param_list(norm) do
          {:error, reason, msg} ->
            {:error, reason, msg}

          {:ok, _list} ->
            props = norm.properties

            unknown_keys =
              args_map
              |> Map.keys()
              |> Enum.map(&to_string/1)
              |> Enum.filter(fn k -> not Map.has_key?(props, k) end)

            if unknown_keys != [] do
              {:error, :unknown_prefill_keys, "unknown prefilled keys: #{inspect(unknown_keys)}"}
            else
              Enum.reduce_while(Map.to_list(args_map), {:ok, %{}}, fn {k, v}, {:ok, acc} ->
                name = to_string(k)
                schema = Map.fetch!(props, name)

                case validate_and_coerce_param(schema, v) do
                  {:ok, coerced} ->
                    {:cont, {:ok, Map.put(acc, name, coerced)}}

                  {:error, reason, msg} ->
                    {:halt,
                     {:error, :invalid_prefill,
                      "prefilled key #{name}: #{inspect({reason, msg})}"}}
                end
              end)
            end
        end
    end
  end

  @doc """
  Validate that required keys are present and coerce all provided values.

  Returns `{:ok, coerced_map}` or `{:error, {:missing_required, keys}}` or
  `{:error, {:invalid, reason}}`.
  """
  @spec validate_all_args(map() | %{properties: map(), required: [binary()]}, map()) ::
          {:ok, map()} | {:error, {:missing_required, [binary()]}} | {:error, atom(), any()}
  def validate_all_args(spec_or_normalized, args_map) do
    normalized =
      case spec_or_normalized do
        %{properties: _} = n -> {:ok, n}
        _ -> normalize_spec(spec_or_normalized)
      end

    case normalized do
      {:error, reason, msg} ->
        {:error, reason, msg}

      {:ok, norm} ->
        case param_list(norm) do
          {:error, reason, msg} ->
            {:error, reason, msg}

          {:ok, _} ->
            missing = Enum.filter(norm.required, fn key -> not Map.has_key?(args_map, key) end)

            if missing != [] do
              {:error, {:missing_required, missing}}
            else
              validate_prefilled_args(norm, args_map)
            end
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Schema introspection helpers (used by Frobs.Prompt)
  # ---------------------------------------------------------------------------

  @doc """
  Resolve a schema to its effective type. Returns the type string for flat
  schemas, or `{:composition, keyword, sub_schemas}` for composition schemas.
  """
  @spec resolve_schema_type(map()) ::
          {:ok, String.t()}
          | {:composition, String.t(), [map()]}
          | {:error, :unresolvable}
  def resolve_schema_type(schema) do
    type = Map.get(schema, "type")
    type = if is_atom(type) and not is_nil(type), do: Atom.to_string(type), else: type

    cond do
      is_binary(type) ->
        {:ok, type}

      Map.has_key?(schema, "anyOf") ->
        {:composition, "anyOf", schema["anyOf"]}

      Map.has_key?(schema, "oneOf") ->
        {:composition, "oneOf", schema["oneOf"]}

      Map.has_key?(schema, "allOf") ->
        {:composition, "allOf", schema["allOf"]}

      true ->
        {:error, :unresolvable}
    end
  end

  @doc """
  Check whether a composition schema represents a nullable type — i.e.,
  `anyOf`/`oneOf` with exactly two sub-schemas where one is `{type: "null"}`.

  Returns `{:nullable, non_null_schema}` or `:not_nullable`.
  """
  @spec nullable_schema?(String.t(), [map()]) :: {:nullable, map()} | :not_nullable
  def nullable_schema?(keyword, sub_schemas)
      when keyword in ["anyOf", "oneOf"] and length(sub_schemas) == 2 do
    null_sub = Enum.find(sub_schemas, fn s -> Map.get(s, "type") == "null" end)
    non_null_sub = Enum.find(sub_schemas, fn s -> Map.get(s, "type") != "null" end)

    if null_sub && non_null_sub do
      {:nullable, non_null_sub}
    else
      :not_nullable
    end
  end

  def nullable_schema?(_, _), do: :not_nullable

  @doc """
  Check whether all sub-schemas in a composition have simple, promptable types
  (string, integer, number, boolean).
  """
  @spec all_simple_types?([map()]) :: boolean()
  def all_simple_types?(sub_schemas) do
    simple = ~w(string integer number boolean)
    Enum.all?(sub_schemas, fn s -> Map.get(s, "type") in simple end)
  end
end
