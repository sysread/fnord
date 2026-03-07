defmodule AI.Tools.SaveSkill do
  @moduledoc """
  Save a new skill definition into the current project's skills directory.

  The coordinator can use this tool to persist skill TOML files under:

    `~/.fnord/projects/<project>/skills/<name>.toml`

  Safety rules:
  - The tool is synchronous.
  - It requires explicit user confirmation via `UI.confirm/2`.
  - It refuses to create a project skill if a user-defined skill with the same
    name already exists in `~/fnord/skills` (because user definitions override
    project definitions).
  """

  @behaviour AI.Tools

  @tool_name "save_skill"

  @impl AI.Tools
  def async?, do: false

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def ui_note_on_request(%{"name" => name}) do
    {"Save skill", name}
  end

  @impl AI.Tools
  def ui_note_on_result(%{"name" => name}, _result) do
    {"Saved skill", name}
  end

  @impl AI.Tools
  def tool_call_failure_message(_args, _reason), do: :default

  @impl AI.Tools
  def read_args(%{} = args) do
    with {:ok, name} <- get_string(args, "name"),
         {:ok, description} <- get_string(args, "description"),
         {:ok, model} <- get_string(args, "model"),
         {:ok, tools} <- get_string_list(args, "tools"),
         {:ok, system_prompt} <- get_string(args, "system_prompt"),
         {:ok, response_format} <- get_optional_map(args, "response_format") do
      {:ok,
       %{
         "name" => name,
         "description" => description,
         "model" => model,
         "tools" => tools,
         "system_prompt" => system_prompt,
         "response_format" => response_format
       }}
    end
  end

  defp get_string(args, key) do
    case Map.fetch(args, key) do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, {:missing_arg, key}}
    end
  end

  defp get_string_list(args, key) do
    case Map.fetch(args, key) do
      {:ok, list} when is_list(list) ->
        list
        |> Enum.filter(&is_binary/1)
        |> case do
          [] -> {:error, {:missing_arg, key}}
          strings -> {:ok, strings}
        end

      _ ->
        {:error, {:missing_arg, key}}
    end
  end

  defp get_optional_map(args, key) do
    case Map.fetch(args, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> {:error, {:invalid_arg, key}}
    end
  end

  @impl AI.Tools
  def spec() do
    %{
      name: @tool_name,
      description:
        "Save a skill into the current project's skills directory (~/.fnord/projects/<project>/skills).",
      parameters_schema: %{
        type: "object",
        properties: %{
          name: %{type: "string", description: "Skill name"},
          description: %{type: "string", description: "Brief description"},
          model: %{
            type: "string",
            description: "Model preset (smart/balanced/fast/web/large_context...)"
          },
          tools: %{type: "array", items: %{type: "string"}, description: "Tool tags"},
          system_prompt: %{type: "string", description: "Base system prompt"},
          response_format: %{type: "object", description: "Optional response_format map"}
        },
        required: ["name", "description", "model", "tools", "system_prompt"]
      }
    }
  end

  @impl AI.Tools
  def call(%{
        "name" => name,
        "description" => description,
        "model" => model,
        "tools" => tools,
        "system_prompt" => system_prompt,
        "response_format" => response_format
      }) do
    with {:ok, project_dir} <- Skills.project_skills_dir(),
         :ok <- check_user_collision(name),
         {:ok, _model_preset} <- Skills.Runtime.model_from_string(model),
         {:ok, _toolbox} <- Skills.Runtime.toolbox_from_tags(tools),
         {:ok, toml} <-
           Skills.Toml.encode_skill(%Skills.Skill{
             name: name,
             description: description,
             model: model,
             tools: tools,
             system_prompt: system_prompt,
             response_format: response_format
           }),
         {:ok, path} <- skill_path(project_dir, name),
         :ok <- confirm_write(path),
         :ok <- write_skill_file(path, toml) do
      {:ok, "Saved skill #{name} to #{path}"}
    end
  end

  defp check_user_collision(name) do
    user_dir = Skills.user_skills_dir()

    case Skills.Loader.load_dir(user_dir, :user) do
      {:ok, loaded} ->
        if Enum.any?(loaded, &(&1.name == name)) do
          {:error, {:skill_exists_in_user_dir, name}}
        else
          :ok
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp skill_path(project_dir, name) do
    File.mkdir_p(project_dir)
    |> case do
      :ok -> {:ok, Path.join(project_dir, "#{name}.toml")}
      {:error, reason} -> {:error, reason}
    end
  end

  defp confirm_write(path) do
    if UI.confirm("Write skill to #{path}?", false) do
      :ok
    else
      {:error, :aborted}
    end
  end

  defp write_skill_file(path, toml) do
    lock_path = path <> ".lock"

    FileLock.with_lock(lock_path, fn ->
      Settings.write_atomic!(path, toml)
      :ok
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
