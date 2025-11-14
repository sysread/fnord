defmodule Frobs do
  @moduledoc """
  Frobs are external tool call integrations. They allow users to define
  external actions that can be executed by the LLM while researching the user's
  query.

  Frobs are stored in `$HOME/.fnord/tools/$frob_name` and are composed of:
  - `spec.json`:      A JSON file that defines the tool call's calling semantics
  - `main`:           A script or binary that performs the action
  - `available`:      A script or binary that exits non-zero if the frob is not
                      available in the current context (e.g. dependencies,
                      environment, etc.)

  Enablement via Settings.Frobs:
  Frobs are enabled via `settings.json` using approvals-style arrays managed by `Settings.Frobs`:
  - Global: top-level `frobs` array of names
  - Project: per-project `projects.<name>.frobs` arrays
  The effective enabled set is the union of global and the currently selected project's list.

  Runtime environment:
  Fnord communicates run-time information to the frob via environment variables:
  - `FNORD_PROJECT`     # The name of the currently selected project
  - `FNORD_CONFIG`      # JSON object of project config
  - `FNORD_ARGS_JSON`   # JSON object of LLM-provided arguments
  """

  import Bitwise

  defstruct [
    :name,
    :home,
    :spec,
    :available,
    :main,
    :module
  ]

  @type t :: %__MODULE__{}

  @json_spec "spec.json"
  @available "available"
  @main "main"

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

  @default_available """
  #!/usr/bin/env bash

  set -eu -o pipefail

  #-----------------------------------------------------------------------------
  # Validate required env vars
  #-----------------------------------------------------------------------------
  : "${FNORD_PROJECT:?FNORD_PROJECT is not set.}"
  : "${FNORD_CONFIG:?FNORD_CONFIG is not set.}"

  #-----------------------------------------------------------------------------
  # Check dependencies
  #-----------------------------------------------------------------------------
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: 'jq' is required but not installed." >&2
    exit 1
  fi

  #-----------------------------------------------------------------------------
  # Confirm that this is a $language project
  #-----------------------------------------------------------------------------
  # root="$(jq -r '.root' <<< "$FNORD_CONFIG")"
  # if [ ! -e "$root/spec.json" ]; then
  #   echo "Error: invalid project type" >&2
  #   exit 1
  # fi

  exit 0
  """

  @default_main """
  #!/usr/bin/env bash

  set -eu -o pipefail

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
         {:ok, spec} <- read_spec(home) do
      {:ok,
       %__MODULE__{
         name: name,
         home: home,
         spec: spec,
         available: Path.join(home, @available),
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
      json_spec = Path.join(home, @json_spec)
      available = Path.join(home, @available)
      main = Path.join(home, @main)

      [
        fn -> File.write!(json_spec, String.replace(@default_spec, "%FROB_NAME%", name)) end,
        fn ->
          File.write!(available, @default_available)
          File.chmod!(available, 0o755)
        end,
        fn ->
          File.write!(main, @default_main)
          File.chmod!(main, 0o755)
        end
      ]
      |> Util.async_stream(& &1.())
      |> Stream.run()

      load(name)
    end
  end

  @spec load_all_modules() :: :ok
  def load_all_modules() do
    get_home()
    |> Path.join("**/main")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      path
      |> Path.dirname()
      |> Path.basename()
    end)
    |> Enum.each(fn name ->
      case load(name) do
        {:ok, _frob} ->
          :ok

        error ->
          Services.Once.warn("Frob '#{name}' could not be loaded: #{inspect(error)}")
      end
    end)
  end

  @spec list() :: [t]
  def list() do
    Services.Once.run({:frobs, :migrate}, fn ->
      Frobs.Migrate.maybe_migrate_registry_to_settings()
    end)

    get_home()
    |> Path.join("**/main")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      path
      |> Path.dirname()
      |> Path.basename()
    end)
    |> Settings.Frobs.prune_missing!()
    |> Enum.reduce([], fn name, acc ->
      with {:ok, frob} <- load(name) do
        [frob | acc]
      else
        error ->
          Services.Once.warn("Frob '#{name}' could not be loaded: #{inspect(error)}")
          acc
      end
    end)
    |> Enum.filter(&is_available?/1)
    |> Enum.sort(fn a, b ->
      String.downcase(a.name) <= String.downcase(b.name)
    end)
  end

  def is_available?(name) when is_binary(name) do
    with {:ok, frob} <- load(name) do
      is_available?(frob)
    else
      _ -> false
    end
  end

  def is_available?(%__MODULE__{} = frob) do
    execute_available(frob) && Settings.Frobs.enabled?(frob.name)
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

    spec =
      spec
      |> Map.update!(:description, fn desc ->
        """
        #{desc}

        Note: This tool is a user-developed 'frob' using local tooling.
        """
      end)

    unless Code.ensure_loaded?(mod_name) do
      quoted =
        quote do
          @behaviour AI.Tools
          @tool_name unquote(Macro.escape(name))
          @tool_spec unquote(Macro.escape(spec))

          @impl AI.Tools
          def is_available? do
            Frobs.is_available?(@tool_name)
          end

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
            if map_size(args) == 0 do
              "Calling frob '#{@tool_name}'"
            else
              {"Calling frob '#{@tool_name}'", Jason.encode!(args, pretty: true)}
            end
          end

          @impl AI.Tools
          def ui_note_on_result(_args, result) when is_binary(result) do
            lines = String.split(result, ~r/\r\n|\n/)

            cond do
              length(lines) > 10 ->
                {first_lines, _rest} = Enum.split(lines, 10)
                remaining = length(lines) - 10

                truncated =
                  Enum.join(first_lines, "\n") <> "\n...plus #{remaining} additional lines"

                {"Frob '#{@tool_name}' result", truncated}

              String.trim(result) == "" ->
                {"Frob '#{@tool_name}' result", "<no output, but completed without error>"}

              true ->
                {"Frob '#{@tool_name}' result", result}
            end
          end

          def ui_note_on_result(_args, result) do
            {"Frob '#{@tool_name}' result", inspect(result, pretty: true, limit: :infinity)}
          end

          @impl AI.Tools
          def tool_call_failure_message(_args, _reason), do: :default

          @impl AI.Tools
          def async?, do: true
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
    home = Settings.get_user_home()
    Path.join([home, "fnord", "tools"])
  end

  defp init do
    File.mkdir_p!(get_home())
  end

  defp validate_frob(name) do
    home = Path.join(get_home(), name)

    with :ok <- validate_home(home),
         :ok <- validate_main(home),
         :ok <- validate_available(home),
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

        !is_map(props) ->
          {:error, :invalid_properties, "Tool parameters.properties must be an object"}

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

  defp validate_main(home) do
    path = Path.join(home, @main)

    if File.exists?(path) do
      validate_executable(path)
    else
      {:error, :main_not_found}
    end
  end

  defp validate_available(home) do
    path = Path.join(home, @available)

    if File.exists?(path) do
      validate_executable(path)
    else
      # optional
      :ok
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
        {"", 0} -> {:ok, "<no output, but completed without error>"}
        {output, 0} -> {:ok, output}
        {output, exit_code} -> {:error, exit_code, output}
      end
    end
  end

  defp execute_available(frob) do
    if File.exists?(frob.available) do
      with {:ok, project_name} <- Settings.get_selected_project(),
           {:ok, settings} <- Settings.get_project(Settings.new()),
           {:ok, settings_json} <- Jason.encode(settings) do
        env = [
          {"FNORD_PROJECT", project_name},
          {"FNORD_CONFIG", settings_json}
        ]

        frob.available
        |> System.cmd([], env: env, stderr_to_stdout: true)
        |> case do
          {_, 0} ->
            true

          {"", _} ->
            false

          {_output, _} ->
            false
        end
      else
        _ ->
          false
      end
    else
      true
    end
  end
end
