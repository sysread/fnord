defmodule Frobs do
  @moduledoc """
  Frobs are external tool call integrations. They allow users to define
  external actions that can be executed by the LLM while researching the user's
  query.

  Frobs are stored in `$HOME/.fnord/tools/$frob_name` and are composed of:
  - `registry.json`:  A JSON file that registers the frob for the user's projects
  - `spec.json`:      A JSON file that defines the tool call's calling semantics
  - `main`:           A script or binary that performs the action

  The `registry.json` file contains the following fields:
  ```json
  {
    // When true, the frob is available to all projects and the "projects"
    // field is ignored.
    "global": true,

    // An array of project names for which fnord should make the frob
    // available. Superseded by the "global" field when set to true.
    "projects": ["my_project", "other_project"]
  }
  ```

  The "name" field in `spec.json` is used to register the frob with the LLM.
  This name must match the frob's directory name.

  If desired, the user can add a lib/util/etc directory to hold any utility or
  helper code to be used by `main`.

  Fnord communicates run-time information to the frob via environment variables:
  - FNORD_PROJECT     # The name of the currently selected project
  - FNORD_CONFIG      # JSON object of project config
  - FNORD_ARGS_JSON   # JSON object of LLM-provided arguments
  """

  import Bitwise

  defstruct [
    :name,
    :home,
    :registry,
    :spec,
    :main,
    :module
  ]

  @type t :: %__MODULE__{}

  @registry "registry.json"
  @json_spec "spec.json"
  @main "main"

  @default_registry """
  {
    "global": false,
    "projects": []
  }
  """

  @default_spec """
  {
    "name": "%FROB_NAME%",
    "description": "Says hello to the user",
    "parameters": {
      "type": "object",
      "required": ["name"],
      "properties": {
        "name": {
          "type": "string",
          "description": "The name of the person to greet"
        }
      }
    }
  }
  """

  @default_main """
  #!/usr/bin/env bash

  set -eu -o pipefail

  #-----------------------------------------------------------------------------
  # Check dependencies
  #-----------------------------------------------------------------------------
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: 'jq' is required but not installed." >&2
    exit 1
  fi

  #-----------------------------------------------------------------------------
  # Validate required env vars
  #-----------------------------------------------------------------------------
  : "${FNORD_PROJECT:?FNORD_PROJECT is not set.}"
  : "${FNORD_CONFIG:?FNORD_CONFIG is not set.}"
  : "${FNORD_ARGS_JSON:?FNORD_ARGS_JSON is not set.}"

  #-----------------------------------------------------------------------------
  # Read input arguments from FNORD_ARGS_JSON
  #-----------------------------------------------------------------------------
  name=$(echo "$FNORD_ARGS_JSON" | jq -r '.name // empty')

  if [[ -z "$name" ]]; then
    echo "Error: Missing required parameter 'name'." >&2
    exit 1
  fi

  #-----------------------------------------------------------------------------
  # Echo project info and greeting
  #-----------------------------------------------------------------------------
  echo "Frob invoked from project: $FNORD_PROJECT"

  echo "Project config:"
  echo "$FNORD_CONFIG" | jq

  echo "---"
  echo "Hello, $name!"
  """

  @allowed_param_types ~w(
    boolean
    integer
    number
    string
    array
    object
  )

  # -----------------------------------------------------------------------------
  # Public API
  # -----------------------------------------------------------------------------
  def load(name) do
    init()

    with {:ok, home} <- validate_frob(name),
         {:ok, registry} <- read_registry(home),
         {:ok, spec} <- read_spec(home) do
      {:ok,
       %__MODULE__{
         name: name,
         home: home,
         registry: registry,
         spec: spec,
         main: Path.join(home, @main),
         module: create_tool_module(name, spec)
       }}
    end
  end

  def create(name) do
    init()

    home = Path.join(get_home(), name)

    if File.exists?(home) do
      {:error, :frob_exists}
    else
      home |> File.mkdir_p!()

      Path.join(home, @registry) |> File.write!(@default_registry)

      Path.join(home, @json_spec)
      |> File.write!(String.replace(@default_spec, "%FROB_NAME%", name))

      Path.join(home, @main) |> File.write!(@default_main)
      Path.join(home, @main) |> File.chmod!(0o755)

      load(name)
    end
  end

  @spec list() :: [t]
  def list() do
    get_home()
    |> Path.join("**/main")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      path
      |> Path.dirname()
      |> Path.basename()
    end)
    |> Enum.reduce([], fn name, acc ->
      with {:ok, frob} <- load(name) do
        [frob | acc]
      else
        error ->
          Once.warn("Frob '#{name}' could not be loaded: #{inspect(error)}")
          acc
      end
    end)
    |> Enum.filter(&is_available?/1)
    |> Enum.sort(fn a, b ->
      String.downcase(a.name) <= String.downcase(b.name)
    end)
  end

  def is_available?(%__MODULE__{registry: %{"global" => true}}), do: true

  def is_available?(%__MODULE__{registry: registry}) do
    with {:ok, project} <- Store.get_project() do
      Enum.member?(registry["projects"], project)
    else
      _ -> false
    end
  end

  def is_available?(frob) when is_binary(frob) do
    with {:ok, home} <- validate_frob(frob),
         {:ok, registry} <- read_registry(home) do
      registry["global"] ||
        with {:ok, project} <- Store.get_project() do
          Enum.member?(registry["projects"], project)
        else
          _ -> false
        end
    end
  end

  @spec module_map() :: %{binary => module()}
  def module_map() do
    list()
    |> Enum.map(fn %{name: name, module: module} -> {name, module} end)
    |> Map.new()
  end

  def perform_tool_call(name, args_json) do
    with {:ok, frob} <- load(name) do
      execute_main(frob, args_json)
    end
  end

  def create_tool_module(name, spec) do
    tool_name = sanitize_module_name(name)
    mod_name = Module.concat([AI.Tools.Frob.Dynamic, tool_name])
    is_available? = is_available?(name)

    unless Code.ensure_loaded?(mod_name) do
      quoted =
        quote do
          @behaviour AI.Tools
          @tool_name unquote(Macro.escape(name))
          @tool_spec unquote(Macro.escape(spec))
          @is_available? unquote(is_available?)

          @impl AI.Tools
          def is_available?, do: @is_available?

          @impl AI.Tools
          def spec, do: %{type: "function", function: @tool_spec}

          @impl AI.Tools
          def read_args(args), do: {:ok, args}

          @impl AI.Tools
          def call(args) do
            Frobs.perform_tool_call(@tool_name, Jason.encode!(args))
          end

          @impl AI.Tools
          def ui_note_on_request(args) do
            {"Calling frob `#{@tool_name}`", inspect(args)}
          end

          @impl AI.Tools
          def ui_note_on_result(_args, result) do
            {"Frob `#{@tool_name}` result", inspect(result)}
          end
        end

      Module.create(mod_name, quoted, Macro.Env.location(__ENV__))
    end

    mod_name
  end

  def create_tool_module(%__MODULE__{name: name, spec: spec}) do
    create_tool_module(name, spec)
  end

  # -----------------------------------------------------------------------------
  # Private functions
  # -----------------------------------------------------------------------------
  defp get_home do
    home = System.get_env("HOME") || System.user_home!()
    Path.join([home, "fnord", "tools"])
  end

  defp init do
    File.mkdir_p!(get_home())
  end

  defp validate_frob(name) do
    home = Path.join(get_home(), name)

    with :ok <- validate_home(home),
         :ok <- validate_registry(home),
         :ok <- validate_main(home),
         :ok <- validate_spec(home),
         :ok <- validate_spec_json(name, home) do
      {:ok, home}
    end
  end

  defp validate_home(path) do
    if File.exists?(path) do
      :ok
    else
      {:error, :frob_not_found}
    end
  end

  defp validate_spec(home) do
    path = Path.join(home, @json_spec)

    if File.exists?(path) do
      :ok
    else
      {:error, :spec_not_found}
    end
  end

  defp validate_spec_json(name, path) do
    spec_path = Path.join(path, @json_spec)

    with {:ok, json} <- File.read(spec_path),
         {:ok, spec} <- Jason.decode(json),
         %{
           "name" => tool_name,
           "description" => description,
           "parameters" =>
             %{
               "type" => "object",
               "properties" => props
             } = params
         } <- spec do
      cond do
        tool_name != name ->
          {:error, :name_mismatch,
           "Tool name '#{tool_name}' does not match frob directory '#{name}'"}

        String.trim(description) == "" ->
          {:error, :empty_description, "Tool description must not be empty"}

        !is_map(props) or map_size(props) == 0 ->
          {:error, :empty_properties, "Tool parameters.properties must be a non-empty object"}

        error = missing_or_invalid_property(props) ->
          error

        !Map.has_key?(params, "required") ->
          {:error, :missing_required,
           "Tool parameters must include a 'required' field (array of strings)"}

        Map.has_key?(params, "required") and not is_list(params["required"]) ->
          {:error, :invalid_required_type, "'required' must be an array of strings"}

        Map.has_key?(params, "required") and
            not Enum.all?(params["required"], &is_binary/1) ->
          {:error, :invalid_required_entries, "'required' must only contain strings"}

        Map.has_key?(params, "required") and
            not Enum.all?(params["required"], &Map.has_key?(props, &1)) ->
          {:error, :missing_required_keys, "Some 'required' keys are not in 'properties'"}

        true ->
          :ok
      end
    else
      {:error, decode_error} ->
        {:error, :invalid_json, "Could not parse spec.json: #{inspect(decode_error)}"}

      _ ->
        {:error, :invalid_structure,
         "spec.json is missing required fields or has incorrect structure"}
    end
  end

  defp missing_or_invalid_property(props) do
    Enum.find_value(props, fn {key, val} ->
      cond do
        !is_map(val) ->
          {:error, :invalid_property, "Property '#{key}' must be a JSON object"}

        !Map.has_key?(val, "type") ->
          {:error, :missing_type, "Property '#{key}' must include a 'type'"}

        !Map.has_key?(val, "description") or String.trim(val["description"]) == "" ->
          {:error, :missing_description,
           "Property '#{key}' must include a non-empty 'description'"}

        val["type"] not in @allowed_param_types ->
          {:error, :invalid_type,
           "Property '#{key}' has invalid type '#{val["type"]}'. Allowed types: #{@allowed_param_types |> Enum.join(", ")}"}

        true ->
          false
      end
    end)
  end

  defp validate_registry(home) do
    path = Path.join(home, @registry)

    if File.exists?(path) do
      :ok
    else
      {:error, :registry_not_found}
    end
  end

  defp validate_main(home) do
    path = Path.join(home, @main)

    if File.exists?(path) do
      validate_executable(path)
    else
      {:error, :main_not_found}
    end
  end

  defp validate_executable(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        if (mode &&& 0o111) != 0 do
          :ok
        else
          {:error, :not_executable}
        end

      {:ok, %File.Stat{type: type}} ->
        {:error, {:not_a_regular_file, type}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_registry(home) do
    with {:ok, content} <- Path.join(home, @registry) |> File.read() do
      Jason.decode(content)
    end
  end

  defp read_spec(home) do
    with {:ok, content} <- Path.join(home, @json_spec) |> File.read() do
      Jason.decode(content, keys: :atoms)
    end
  end

  defp sanitize_module_name(name) do
    hash = :crypto.hash(:md5, name) |> Base.encode16() |> binary_part(0, 6)

    name
    |> String.replace(~r/[^a-zA-Z0-9]/, "_")
    |> Macro.camelize()
    |> then(&"#{&1}_#{hash}")
  end

  defp execute_main(frob, args_json) do
    with {:ok, project_name} <- Settings.get_selected_project(),
         {:ok, settings} <- Settings.get_project(Settings.new()),
         {:ok, settings_json} <- Jason.encode(settings) do
      env = [
        {"FNORD_PROJECT", project_name},
        {"FNORD_CONFIG", settings_json},
        {"FNORD_ARGS_JSON", args_json}
      ]

      frob.main
      |> System.cmd([], env: env, stderr_to_stdout: true)
      |> case do
        {output, 0} -> {:ok, output}
        {output, exit_code} -> {:error, exit_code, output}
      end
    end
  end
end
