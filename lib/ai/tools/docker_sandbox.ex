defmodule AI.Tools.DockerSandbox do
  @moduledoc false
  @behaviour AI.Tools

  alias DockerSandbox.Store, as: SandboxStore
  alias DockerSandbox.Runner
  alias DockerSandbox.CLI

  @impl AI.Tools
  def async?, do: false

  @impl AI.Tools
  def is_available? do
    cli = Application.get_env(:fnord, :docker_cli, CLI)

    if cli.executable?("docker") do
      case cli.cmd("docker", ["version"], []) do
        {_, 0} -> true
        _ -> false
      end
    else
      false
    end
  rescue
    _ -> false
  end

  @impl AI.Tools
  def spec do
    %{
      name: "docker_sandbox_tool",
      description: "Manage and run isolated Docker sandboxes",
      parameters: %{
        type: "object",
        required: ["action"],
        properties: %{
          "action" => %{type: "string", enum: ["list", "get", "put", "delete", "run"]},
          "name" => %{type: "string"},
          "description" => %{type: "string"},
          "dockerfile_body" => %{type: "string"},
          "default_run_args" => %{type: "array", items: %{type: "string"}},
          "run_args" => %{type: "array", items: %{type: "string"}},
          "timeout_ms" => %{type: "integer"}
        }
      }
    }
  end

  @impl AI.Tools
  def read_args(%{"action" => action} = args) do
    case action do
      "list" ->
        {:ok, %{"action" => "list"}}

      "get" ->
        with {:ok, name} <- Map.fetch(args, "name") do
          {:ok, %{"action" => "get", "name" => name}}
        else
          :error -> {:error, "Missing required field: name"}
        end

      "put" ->
        with {:ok, name} <- Map.fetch(args, "name"),
             {:ok, description} <- Map.fetch(args, "description"),
             {:ok, dockerfile_body} <- Map.fetch(args, "dockerfile_body") do
          default_run_args = Map.get(args, "default_run_args", [])

          {:ok,
           %{
             "action" => "put",
             "name" => name,
             "description" => description,
             "dockerfile_body" => dockerfile_body,
             "default_run_args" => default_run_args
           }}
        else
          :error -> {:error, "Missing required fields: name, description, dockerfile_body"}
        end

      "delete" ->
        with {:ok, name} <- Map.fetch(args, "name") do
          {:ok, %{"action" => "delete", "name" => name}}
        else
          :error -> {:error, "Missing required field: name"}
        end

      "run" ->
        with {:ok, name} <- Map.fetch(args, "name") do
          run_args = Map.get(args, "run_args", Map.get(args, "default_run_args", []))
          timeout_ms = Map.get(args, "timeout_ms", 60_000)

          {:ok,
           %{
             "action" => "run",
             "name" => name,
             "run_args" => run_args,
             "timeout_ms" => timeout_ms
           }}
        else
          :error -> {:error, "Missing required field: name"}
        end

      _ ->
        {:error, "Invalid action: #{action}"}
    end
  end

  def read_args(_),
    do: {:error, "Missing required field: action"}

  @impl AI.Tools
  def call(%{"action" => "list"}) do
    sandboxes = SandboxStore.list(current_project())
    {:ok, sandboxes}
  end

  @impl AI.Tools
  def call(%{"action" => "get", "name" => name}) do
    case SandboxStore.get(current_project(), name) do
      {:ok,
       %{
         "name" => name,
         "description" => description,
         "dockerfile_body" => dockerfile_body,
         "default_run_args" => default_run_args
       }} ->
        {:ok,
         %{
           name: name,
           description: description,
           dockerfile: dockerfile_body,
           default_run_args: default_run_args
         }}

      {:error, :not_found} ->
        {:error, :not_found}

      _ ->
        {:error, "Failed to get sandbox #{name}"}
    end
  end

  @impl AI.Tools
  def call(%{
        "action" => "put",
        "name" => name,
        "description" => description,
        "dockerfile_body" => dockerfile_body,
        "default_run_args" => default_run_args
      }) do
    case SandboxStore.put(current_project(), %{
           name: name,
           description: description,
           dockerfile_body: dockerfile_body,
           default_run_args: default_run_args
         }) do
      {:ok, sandbox} ->
        {:ok, sandbox}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl AI.Tools
  def call(%{"action" => "delete", "name" => name}) do
    case SandboxStore.delete(current_project(), name) do
      :ok -> {:ok, :deleted}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl AI.Tools
  def call(%{
        "action" => "run",
        "name" => name,
        "run_args" => run_args,
        "timeout_ms" => timeout_ms
      }) do
    project = current_project()

    case SandboxStore.get(project, name) do
      {:ok, %{"dockerfile_body" => dockerfile_body, "default_run_args" => default_run_args}} ->
        args_to_use = if run_args != [], do: run_args, else: default_run_args

        case Runner.build_image(name, dockerfile_body, project.source_root) do
          {:ok, image_tag} ->
            warning_prefix = ""

            case Runner.run_container(image_tag, args_to_use, timeout_ms: timeout_ms) do
              {:ok, output} ->
                {:ok, warning_prefix <> output}

              {:error, reason} ->
                {:error, reason}
            end

          {:warning, %{tag: image_tag, warning: warning_text}} ->
            warning_prefix = "WARNING: #{warning_text}\n"

            case Runner.run_container(image_tag, args_to_use, timeout_ms: timeout_ms) do
              {:ok, output} ->
                {:ok, warning_prefix <> output}

              {:error, reason} ->
                {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, "Failed to run sandbox #{name}"}
    end
  end

  defp current_project do
    case Store.get_project() do
      {:ok, project} -> project
      {:error, reason} -> raise "Failed to get project: #{reason}"
    end
  end

  @impl AI.Tools
  def ui_note_on_request(%{"action" => "list"}) do
    "Listing Docker sandboxes"
  end

  def ui_note_on_request(%{"action" => action, "name" => name}) do
    "#{String.capitalize(action)} Docker sandbox #{name}"
  end

  @impl AI.Tools
  def ui_note_on_result(%{"action" => "list"}, sandboxes) do
    "Found #{length(sandboxes)} sandboxes"
  end

  def ui_note_on_result(%{"action" => "get", "name" => name}, _result) do
    "Fetched sandbox #{name}"
  end

  def ui_note_on_result(%{"action" => "put", "name" => name}, _result) do
    "Saved sandbox #{name}"
  end

  def ui_note_on_result(%{"action" => "delete", "name" => name}, _result) do
    "Deleted sandbox #{name}"
  end

  def ui_note_on_result(%{"action" => "run", "name" => name}, _result) do
    "Ran sandbox #{name}"
  end

  @impl AI.Tools
  def tool_call_failure_message(_args, reason) do
    "Docker sandbox tool failed: #{reason}"
  end
end
