defmodule Frobs.Prompt do
  @moduledoc """
  UI-driven prompting for frob parameters. This module uses `UI` to prompt the
  user for each property defined in a frob's `spec.json` and returns a map of
  coerced values. It relies on `AI.Tools.Params` for validation/coercion.

  Supports JSON Schema composition keywords (`anyOf`, `oneOf`, `allOf`) via
  schema resolution: nullable unions prompt for the non-null type, simple
  multi-type unions offer a type chooser, `allOf` merges and prompts the merged
  schema, and anything else falls back to raw JSON input.
  """

  @doc """
  Prompt the user for parameters described by `spec`.

  Returns `{:ok, map}` or `{:error, reason}`.
  """
  @spec prompt_for_params(map(), module()) :: {:ok, map()} | {:error, term()}
  def prompt_for_params(spec, ui \\ UI) do
    with {:ok, normalized} <- AI.Tools.Params.normalize_spec(spec),
         {:ok, params} <- AI.Tools.Params.param_list(normalized) do
      if not ui.is_tty?() or ui.quiet?() do
        non_interactive_collect(params, normalized)
      else
        interactive_collect(params, normalized, ui)
      end
    end
  end

  defp non_interactive_collect(params, normalized) do
    defaults = collect_defaults(params)

    missing =
      params
      |> Enum.filter(fn {name, _schema, req} -> req and not Map.has_key?(defaults, name) end)
      |> Enum.map(fn {name, _, _} -> name end)

    if missing != [] do
      {:error, {:non_interactive_missing_required, missing}}
    else
      AI.Tools.Params.validate_all_args(normalized, defaults)
    end
  end

  defp collect_defaults(list) do
    Enum.reduce(list, %{}, fn {name, schema, _req}, acc ->
      case Map.get(schema, "default") do
        nil -> acc
        v -> Map.put(acc, name, v)
      end
    end)
  end

  defp interactive_collect(params, normalized, ui) do
    result =
      Enum.reduce_while(params, {:ok, %{}}, fn {name, schema, required?}, {:ok, acc} ->
        case prompt_property(name, schema, required?, ui) do
          {:ok, v} -> {:cont, {:ok, Map.put(acc, name, v)}}
          {:error, :user_cancelled} -> {:halt, {:error, :user_cancelled}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, answers} ->
        case AI.Tools.Params.validate_all_args(normalized, answers) do
          {:ok, coerced} -> {:ok, coerced}
          {:error, reason} -> {:error, reason}
        end

      other ->
        other
    end
  end

  # ---------------------------------------------------------------------------
  # Property prompting — dispatches by schema resolution
  # ---------------------------------------------------------------------------

  defp prompt_property(name, schema, _required?, ui) do
    label = name |> to_string() |> String.replace("_", " ")
    desc = Map.get(schema, "description", "")

    unless ui.quiet?() do
      if desc != "", do: ui.puts(desc)
    end

    case AI.Tools.Params.resolve_schema_type(schema) do
      {:ok, type} ->
        prompt_by_type(type, name, label, schema, ui)

      {:composition, keyword, sub_schemas} ->
        prompt_composition(keyword, sub_schemas, name, label, schema, ui)

      {:error, :unresolvable} ->
        prompt_raw_json(label, schema, ui)
    end
  end

  # ---------------------------------------------------------------------------
  # Type-based prompting
  # ---------------------------------------------------------------------------

  defp prompt_by_type(_type, _name, label, %{"enum" => choices} = _schema, ui) do
    display = Enum.map(choices, &to_string/1)
    sel = ui.choose(label, display)
    idx = Enum.find_index(display, &(&1 == sel)) || 0
    {:ok, Enum.at(choices, idx)}
  end

  defp prompt_by_type("boolean", _name, label, _schema, ui) do
    sel = ui.choose(label, ["Yes", "No"]) || "No"
    {:ok, sel in ["Yes", "yes", "Y", "y"]}
  end

  defp prompt_by_type(type, _name, label, schema, ui)
       when type in ["string", "integer", "number"] do
    default = Map.get(schema, "default")
    prompt_text = if default, do: "#{label} (default: #{inspect(default)})", else: label
    raw = ui.prompt(prompt_text)
    val = if raw in [nil, ""], do: default, else: raw
    {:ok, val}
  end

  defp prompt_by_type("array", name, _label, schema, ui) do
    items_schema = Map.get(schema, "items") || %{"type" => "string"}
    collect_array_items(name, items_schema, ui, [])
  end

  defp prompt_by_type("object", _name, _label, schema, ui) do
    nested_spec = %{
      "parameters" => %{
        "type" => "object",
        "properties" => Map.get(schema, "properties", %{}),
        "required" => Map.get(schema, "required", [])
      }
    }

    case prompt_for_params(nested_spec, ui) do
      {:ok, m} -> {:ok, m}
      other -> other
    end
  end

  defp prompt_by_type(_type, _name, label, schema, ui) do
    prompt_raw_json(label, schema, ui)
  end

  # ---------------------------------------------------------------------------
  # Composition prompting
  # ---------------------------------------------------------------------------

  defp prompt_composition(keyword, sub_schemas, name, label, schema, ui) do
    case AI.Tools.Params.nullable_schema?(keyword, sub_schemas) do
      {:nullable, non_null_schema} ->
        prompt_nullable(name, label, non_null_schema, ui)

      :not_nullable when keyword in ["anyOf", "oneOf"] ->
        if AI.Tools.Params.all_simple_types?(sub_schemas) do
          prompt_type_chooser(sub_schemas, label, ui)
        else
          prompt_raw_json(label, schema, ui)
        end

      :not_nullable when keyword == "allOf" ->
        merged = AI.Tools.Params.merge_schemas(sub_schemas)
        prompt_property(name, merged, false, ui)

      _ ->
        prompt_raw_json(label, schema, ui)
    end
  end

  defp prompt_nullable(name, label, non_null_schema, ui) do
    case AI.Tools.Params.resolve_schema_type(non_null_schema) do
      {:ok, type} ->
        prompt_text = "#{label} (optional, enter blank to skip)"
        raw = ui.prompt(prompt_text)

        if raw in [nil, ""] do
          {:ok, nil}
        else
          case AI.Tools.Params.validate_and_coerce_param(non_null_schema, raw) do
            {:ok, coerced} -> {:ok, coerced}
            {:error, _, _} -> prompt_by_type(type, name, label, non_null_schema, ui)
          end
        end

      _ ->
        # Non-null sub-schema is itself complex; fall back to raw JSON
        prompt_text = "#{label} (optional, enter blank to skip, or enter JSON)"
        raw = ui.prompt(prompt_text)

        if raw in [nil, ""] do
          {:ok, nil}
        else
          parse_and_validate_json(raw, non_null_schema, label, ui)
        end
    end
  end

  defp prompt_type_chooser(sub_schemas, label, ui) do
    types = Enum.map(sub_schemas, fn s -> Map.get(s, "type") end)
    sel = ui.choose("#{label} (type)", types)
    idx = Enum.find_index(types, &(&1 == sel)) || 0
    chosen_schema = Enum.at(sub_schemas, idx)

    prompt_text = "#{label} (#{sel})"
    raw = ui.prompt(prompt_text)
    default = Map.get(chosen_schema, "default")
    val = if raw in [nil, ""], do: default, else: raw

    case AI.Tools.Params.validate_and_coerce_param(chosen_schema, val) do
      {:ok, coerced} -> {:ok, coerced}
      {:error, _, msg} -> {:error, {:coercion_failed, msg}}
    end
  end

  # ---------------------------------------------------------------------------
  # Raw JSON fallback
  # ---------------------------------------------------------------------------

  defp prompt_raw_json(label, schema, ui) do
    prompt_text = "#{label} (enter as JSON)"
    raw = ui.prompt(prompt_text)

    default = Map.get(schema, "default")

    if raw in [nil, ""] and default != nil do
      {:ok, default}
    else
      parse_and_validate_json(raw, schema, label, ui)
    end
  end

  defp parse_and_validate_json(raw, schema, label, ui) do
    case Jason.decode(raw || "") do
      {:ok, parsed} ->
        case AI.Tools.Params.validate_and_coerce_param(schema, parsed) do
          {:ok, coerced} ->
            {:ok, coerced}

          {:error, _, msg} ->
            ui.puts("Invalid value: #{msg}")
            prompt_raw_json(label, schema, ui)
        end

      {:error, _} ->
        ui.puts("Invalid JSON. Please enter a valid JSON value.")
        prompt_raw_json(label, schema, ui)
    end
  end

  # ---------------------------------------------------------------------------
  # Array item collection
  # ---------------------------------------------------------------------------

  defp collect_array_items(_name, items_schema, ui, acc) do
    idx = length(acc) + 1
    prompt_text = "Item ##{idx} (enter blank to finish)"
    raw = ui.prompt(prompt_text)

    cond do
      raw in [nil, ""] and acc == [] ->
        {:ok, []}

      raw in [nil, ""] ->
        {:ok, acc}

      true ->
        case AI.Tools.Params.validate_and_coerce_param(items_schema, raw) do
          {:ok, coerced} ->
            collect_array_items(nil, items_schema, ui, acc ++ [coerced])

          {:error, _reason, _msg} ->
            ui.puts("Invalid item, try again")
            collect_array_items(nil, items_schema, ui, acc)
        end
    end
  end
end
