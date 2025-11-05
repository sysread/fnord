defmodule AI.Tools.Spec do
  @moduledoc """
  Normalization utilities for tool specs.

  Many tools historically returned a nested spec of the form:
    %{type: "function", function: %{name: ..., description: ..., parameters: ...}}

  Newer paths expect a flattened map:
    %{type: "function", name: ..., description: ..., parameters: ...}

  This module provides helpers to normalize either shape into the flattened
  representation used internally when validating and exposing tool specs.
  """

  @type flat_spec :: %{
          required(:type) => binary,
          required(:name) => binary,
          required(:description) => binary,
          required(:parameters) => map,
          optional(:strict) => boolean
        }

  @doc """
  Convert a tool spec into its flattened representation. Accepts either the
  nested %{function: %{...}} form or an already flattened map. Unknown shapes
  are returned as-is.
  """
  @spec normalize_tool_spec(map) :: flat_spec | map
  def normalize_tool_spec(%{type: type, function: %{name: _name} = fun}) when is_binary(type) do
    %{
      type: type,
      name: fetch_string(fun, :name),
      description: fetch_string(fun, :description),
      parameters: Map.get(fun, :parameters) || Map.get(fun, "parameters", %{})
    }
    |> maybe_put_strict(fun)
  end

  def normalize_tool_spec(%{"type" => type, "function" => %{"name" => name} = fun})
      when is_binary(type) and is_binary(name) do
    %{
      type: type,
      name: Map.get(fun, "name"),
      description: Map.get(fun, "description", ""),
      parameters: Map.get(fun, "parameters", %{})
    }
    |> maybe_put_strict(fun)
  end

  def normalize_tool_spec(%{function: %{name: name} = fun}) when is_binary(name) do
    %{
      type: "function",
      name: fetch_string(fun, :name),
      description: fetch_string(fun, :description),
      parameters: Map.get(fun, :parameters) || Map.get(fun, "parameters", %{})
    }
    |> maybe_put_strict(fun)
  end

  def normalize_tool_spec(%{"function" => %{"name" => name} = fun}) when is_binary(name) do
    %{
      type: "function",
      name: Map.get(fun, "name"),
      description: Map.get(fun, "description", ""),
      parameters: Map.get(fun, "parameters", %{})
    }
    |> maybe_put_strict(fun)
  end
  def normalize_tool_spec(%{type: type, name: _} = flat) when is_binary(type), do: flat
  def normalize_tool_spec(%{"type" => type, "name" => _} = flat) when is_binary(type), do: flat
  def normalize_tool_spec(other), do: other

  defp maybe_put_strict(map, fun) do
    case {Map.get(fun, :strict), Map.get(fun, "strict")} do
      {bool, _} when is_boolean(bool) -> Map.put(map, :strict, bool)
      {_, bool} when is_boolean(bool) -> Map.put(map, :strict, bool)
      _ -> map
    end
  end

  defp fetch_string(map, key) do
    case {Map.get(map, key), Map.get(map, to_string(key))} do
      {val, _} when is_binary(val) -> val
      {_, val} when is_binary(val) -> val
      _ -> ""
    end
  end
end
