defmodule Skills.Skill do
  @moduledoc """
  A single skill definition loaded from a TOML file.

  Skills are defined on disk as TOML and loaded at runtime.

  Fields in the struct reflect the stable skill schema:
  - `name`, `description`, `model`, `tools`, `system_prompt` are required
  - `response_format` is optional

  Validation is performed when loading a skill from TOML.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          model: String.t(),
          tools: [String.t()],
          system_prompt: String.t(),
          response_format: map() | nil
        }

  defstruct [:name, :description, :model, :tools, :system_prompt, :response_format]

  @type decode_error ::
          {:missing_key, String.t()}
          | {:invalid_type, String.t(), expected :: String.t(), got :: term()}
          | {:invalid_value, String.t(), term()}

  @doc """
  Convert a decoded TOML map into a validated skill struct.

  The TOML parser is expected to decode keys as strings.
  """
  @type warning :: {:dropped_non_strings, key :: String.t(), dropped :: [term()]}

  @spec from_map(map()) :: {:ok, t(), [warning]} | {:error, decode_error}
  def from_map(map) when is_map(map) do
    with {:ok, name} <- required_string(map, "name"),
         {:ok, description} <- required_string(map, "description"),
         {:ok, model} <- required_string(map, "model"),
         {:ok, tools, tools_warnings} <- required_string_list(map, "tools"),
         :ok <- require_basic_tag(tools),
         {:ok, system_prompt} <- required_string(map, "system_prompt"),
         {:ok, response_format} <- optional_map(map, "response_format") do
      {:ok,
       %__MODULE__{
         name: name,
         description: description,
         model: model,
         tools: tools,
         system_prompt: system_prompt,
         response_format: response_format
       }, tools_warnings}
    end
  end

  defp required_string(map, key) do
    case Map.fetch(map, key) do
      :error -> {:error, {:missing_key, key}}
      {:ok, value} when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      {:ok, value} when is_binary(value) -> {:error, {:invalid_value, key, value}}
      {:ok, value} -> {:error, {:invalid_type, key, "string", value}}
    end
  end

  defp required_string_list(map, key) do
    case Map.fetch(map, key) do
      :error ->
        {:error, {:missing_key, key}}

      {:ok, list} when is_list(list) ->
        {strings, non_strings} = Enum.split_with(list, &is_binary/1)

        warnings =
          case non_strings do
            [] -> []
            _ -> [{:dropped_non_strings, key, non_strings}]
          end

        case strings do
          [] -> {:error, {:invalid_value, key, list}}
          _ -> {:ok, strings, warnings}
        end

      {:ok, value} ->
        {:error, {:invalid_type, key, "array of strings", value}}
    end
  end

  # Fail at load time rather than deferring to runtime, where the error would
  # be surprising and harder to diagnose.
  defp require_basic_tag(tools) do
    if "basic" in tools do
      :ok
    else
      {:error, {:invalid_value, "tools", "must include \"basic\" tag, got: #{inspect(tools)}"}}
    end
  end

  defp optional_map(map, key) do
    case Map.fetch(map, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_type, key, "table/map", value}}
    end
  end
end
