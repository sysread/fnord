defmodule Cmd.Skills do
  @moduledoc """
  CLI management for Skills.

  This command family supports:
  - listing skills (including overridden definitions),
  - creating/editing/removing skill TOML files under the project skills directory,
  - enabling/disabling skills via settings at global and project scope.

  Skill definitions are stored as TOML in:
  - user dir: `~/fnord/skills`
  - project dir: `~/.fnord/projects/<project>/skills`

  User definitions override project definitions by name.
  """

  @behaviour Cmd

  @impl Cmd
  def requires_project?(), do: false

  @impl Cmd
  def spec do
    [
      skills: [
        name: "skills",
        about: "Manage skills",
        subcommands: [
          list: [
            name: "list",
            about: "List skills",
            options: [
              project: Cmd.project_arg()
            ]
          ],
          new: [
            name: "new",
            about: "Create a new skill in your editor",
            options: [
              project: Cmd.project_arg()
            ]
          ],
          edit: [
            name: "edit",
            about: "Edit an existing skill in your editor",
            options: [
              project: Cmd.project_arg(),
              skill: [
                value_name: "SKILL",
                long: "--skill",
                short: "-s",
                help: "Skill name to edit",
                required: true
              ]
            ]
          ],
          remove: [
            name: "remove",
            about: "Remove a project skill definition",
            options: [
              project: Cmd.project_arg(),
              skill: [
                value_name: "SKILL",
                long: "--skill",
                short: "-s",
                help: "Skill name",
                required: true
              ]
            ]
          ],
          enable: [
            name: "enable",
            about: "Enable a skill in settings",
            options: [
              skill: [
                value_name: "SKILL",
                long: "--skill",
                short: "-s",
                help: "Skill name",
                required: true
              ],
              project: [
                long: "--project",
                value_name: "PROJECT",
                help: "Apply to the named project (overrides selected project)"
              ]
            ],
            flags: [
              global: [
                long: "--global",
                short: "-g",
                help: "Apply to global settings (otherwise current project)",
                required: false,
                default: false
              ]
            ]
          ],
          disable: [
            name: "disable",
            about: "Disable a skill in settings",
            options: [
              skill: [
                value_name: "SKILL",
                long: "--skill",
                short: "-s",
                help: "Skill name",
                required: true
              ],
              project: [
                long: "--project",
                value_name: "PROJECT",
                help: "Apply to the named project (overrides selected project)"
              ]
            ],
            flags: [
              global: [
                long: "--global",
                short: "-g",
                help: "Apply to global settings (otherwise current project)",
                required: false,
                default: false
              ]
            ]
          ],
          generate: [
            name: "generate",
            about: "Generate a skill using an LLM",
            options: [
              project: Cmd.project_arg(),
              description: [
                value_name: "DESCRIPTION",
                long: "--description",
                short: "-d",
                help: "What the skill should do",
                required: true
              ],
              name: [
                value_name: "NAME",
                long: "--name",
                short: "-n",
                help: "Requested skill name slug"
              ]
            ],
            flags: [
              global: [
                long: "--global",
                short: "-g",
                help: "Generate a user-global skill",
                required: false,
                default: false
              ],
              enable: [
                long: "--enable",
                short: "-e",
                help: "Print commands to enable/disable this skill after generation",
                required: false,
                default: false
              ]
            ]
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(opts, subcommands, unknown) do
    Services.Once.set(:cli_skills_used, true)

    try do
      with {:ok, msg} <- call_subcommand(opts, subcommands, unknown) do
        msg
        |> UI.Formatter.format_output()
        |> UI.puts()

        {:ok, msg}
      else
        {:error, reason} ->
          UI.fatal("skills", inspect(reason))
      end
    rescue
      e in RuntimeError ->
        UI.fatal("skills", Exception.message(e))
    end
  end

  defp call_subcommand(opts, [:list], _unknown), do: list(opts)
  defp call_subcommand(opts, [:new], _unknown), do: new_skill(opts)
  defp call_subcommand(opts, [:edit], _unknown), do: edit_skill(opts)
  defp call_subcommand(opts, [:remove], _unknown), do: remove_skill(opts)
  defp call_subcommand(opts, [:enable], _unknown), do: enable_skill(opts)
  defp call_subcommand(opts, [:disable], _unknown), do: disable_skill(opts)
  defp call_subcommand(opts, [:generate], _unknown), do: generate_skill(opts)
  defp call_subcommand(_opts, _sub, _unknown), do: {:error, :invalid_subcommand}

  defp list(opts) do
    # Read-only: use project from opts without persisting the selection
    current_project =
      case opts do
        %{project: pn} when is_binary(pn) ->
          pn

        _ ->
          case Settings.get_selected_project() do
            {:ok, pn} -> pn
            _ -> nil
          end
      end

    with {:ok, skills} <- Skills.list_all() do
      skills
      |> Enum.map(&format_skill(&1, current_project))
      |> Enum.join("\n\n---\n\n")
      |> then(&{:ok, &1})
    end
  end

  defp format_skill(%{name: name, effective: eff, definitions: defs}, current_project) do
    status = format_enabled_scopes(name, current_project)

    tools = Enum.map_join(eff.skill.tools, ", ", &"`#{&1}`")

    defined_in =
      defs
      |> Enum.map(fn %{path: path, source: source} = defn ->
        formatted = format_path(path, source)

        if defn.path == eff.path do
          "- `#{formatted}`"
        else
          "- ~~`#{formatted}`~~"
        end
      end)
      |> Enum.join("\n")

    """
    ### #{name}

    #{eff.skill.description}

    | | |
    |---|---|
    | **Tools** | #{tools} |
    | **Model** | `#{eff.skill.model}` |
    | **Enabled** | #{status} |

    **Defined in:**
    #{defined_in}\
    """
    |> String.trim()
  end

  # Build a scope list showing where a skill is enabled. Global and the
  # current project are bolded for visibility.
  defp format_enabled_scopes(name, current_project) do
    settings = Settings.new()
    projects = Settings.list_projects(settings)

    global_enabled = Enum.member?(Settings.Skills.list(:global), name)

    project_scopes =
      projects
      |> Enum.filter(fn pn -> Enum.member?(Settings.Skills.list({:project, pn}), name) end)

    scopes =
      if(global_enabled, do: [:global], else: []) ++
        Enum.map(project_scopes, fn pn -> {:project, pn} end)

    case scopes do
      [] ->
        "disabled"

      _ ->
        scopes
        |> Enum.map(fn
          :global -> "**global**"
          {:project, pn} when pn == current_project -> "**#{pn}**"
          {:project, pn} -> pn
        end)
        |> Enum.join(" ")
    end
  end

  defp format_path(path, source) do
    case source do
      :user -> String.replace_prefix(path, Settings.get_user_home(), "$HOME")
      :project -> String.replace_prefix(path, Settings.fnord_home(), "~/.fnord")
    end
  end

  # Both `new` and `edit` open a TOML file in the user's editor. After the
  # user saves and exits, the TOML is decoded, validated (structure, model,
  # tools), string fields are trimmed, and the result is written to the user
  # skills dir. The user is then prompted to configure enablement scope.

  defp new_skill(opts) do
    maybe_set_project_from_opts(opts)

    target_dir = skill_write_dir()
    toml = skill_template()

    with {:ok, skill} <- edit_skill_in_editor(toml, toml),
         :ok <- write_skill_toml(target_dir, skill.name, skill) do
      prompt_enablement(skill.name, opts)
      {:ok, "Saved skill #{skill.name} to #{Path.join(target_dir, "#{skill.name}.toml")}"}
    end
  end

  defp edit_skill(opts) do
    maybe_set_project_from_opts(opts)

    target_dir = skill_write_dir()
    name = opts.skill

    # Intentionally using Skills.get/1 (not get_enabled/1) so disabled skills can be edited
    with {:ok, resolved} <- Skills.get(name),
         {:ok, toml} <- Skills.Toml.encode_skill(resolved.effective.skill),
         {:ok, skill} <- edit_skill_in_editor(toml),
         :ok <- write_skill_toml(target_dir, name, skill) do
      prompt_enablement(name, opts)
      {:ok, "Saved skill #{name} to #{Path.join(target_dir, "#{name}.toml")}"}
    end
  end

  # Open TOML in the editor, then decode, validate, and trim the result.
  # Returns {:ok, %Skills.Skill{}} or {:error, reason}.
  defp edit_skill_in_editor(toml, original \\ nil) do
    edited = UI.open_in_editor(toml, extension: ".toml")

    if original != nil && edited == original do
      {:error, "No changes made - skill was not saved"}
    else
      with {:ok, map} <- Fnord.Toml.decode(edited),
           {:ok, skill, _warnings} <- Skills.Skill.from_map(map),
           skill <- trim_skill_strings(skill),
           :ok <- validate_model_and_tools(skill.model, skill.tools) do
        {:ok, skill}
      else
        {:error, reason} -> {:error, format_skill_error(reason)}
      end
    end
  end

  defp format_skill_error({:missing_key, key}),
    do: "Missing required field: #{key}"

  defp format_skill_error({:invalid_value, key, _value}),
    do: "Field '#{key}' cannot be empty"

  defp format_skill_error({:invalid_type, key, expected, _got}),
    do: "Field '#{key}' must be a #{expected}"

  defp format_skill_error({:unknown_model_preset, model}),
    do:
      "Unknown model preset '#{model}'. Valid presets: #{Enum.join(Skills.Runtime.allowed_model_presets(), ", ")}"

  defp format_skill_error({:unknown_tool_tag, tag}),
    do:
      "Unknown tool tag '#{tag}'. Valid tags: #{Enum.join(Skills.Runtime.allowed_toolboxes(), ", ")}"

  defp format_skill_error({:toml_decode_error, msg}),
    do: "Invalid TOML: #{msg}"

  defp format_skill_error(other),
    do: inspect(other)

  # Trim leading/trailing whitespace from all string fields in the skill.
  defp trim_skill_strings(%Skills.Skill{} = skill) do
    %{
      skill
      | name: String.trim(skill.name),
        description: String.trim(skill.description),
        model: String.trim(skill.model),
        system_prompt: String.trim(skill.system_prompt),
        tools: Enum.map(skill.tools, &String.trim/1)
    }
  end

  @valid_name_pattern ~r/^[a-z0-9][a-z0-9_-]*$/

  defp remove_skill(opts) do
    maybe_set_project_from_opts(opts)

    name = opts.skill

    if not Regex.match?(@valid_name_pattern, name) do
      {:error, "Invalid skill name '#{name}'. Names must match [a-z0-9][a-z0-9_-]*."}
    else
      with {:ok, _project, project_dir} <- ensure_project_selected() do
        path = Path.join(project_dir, "#{name}.toml")

        if UI.confirm("Remove skill file #{path}?", false) do
          case File.rm(path) do
            :ok ->
              {:ok, "Removed #{path}"}

            {:error, :enoent} ->
              {:error, "Skill file not found: #{path}"}

            {:error, :eacces} ->
              {:error, "Permission denied: #{path}"}

            {:error, reason} ->
              {:error, "Could not remove #{path}: #{reason}"}
          end
        else
          {:error, "Aborted"}
        end
      else
        {:error, :no_project_selected} -> return_no_project_error()
      end
    end
  end

  defp enable_skill(opts) do
    with {:ok, scope} <- resolve_scope(opts) do
      Settings.Skills.enable(scope, opts.skill)
      {:ok, "Enabled #{opts.skill} in #{scope_label(scope)} scope."}
    end
  end

  defp disable_skill(opts) do
    with {:ok, scope} <- resolve_scope(opts) do
      Settings.Skills.disable(scope, opts.skill)
      {:ok, "Disabled #{opts.skill} in #{scope_label(scope)} scope."}
    end
  end

  @spec generate_skill(map()) :: {:ok, String.t()} | {:error, any()}
  defp generate_skill(opts) do
    scope = save_scope(opts)
    toolbox = %{"save_skill" => AI.Tools.SaveSkill, "notify_tool" => AI.Tools.Notify}

    with :ok <- ensure_generate_prereqs(scope, opts),
         {:ok, user_prompt} <- generate_user_prompt(opts),
         {:ok, completion} <-
           AI.Completion.get(
             model: AI.Model.balanced(),
             toolbox: toolbox,
             log_msgs: true,
             replay_conversation: false,
             messages: [
               AI.Util.system_msg(generate_system_prompt(scope)),
               AI.Util.user_msg(user_prompt)
             ]
           ) do
      tools = AI.Completion.tools_used(completion)

      case Map.get(tools, "save_skill", 0) do
        count when count < 1 ->
          {:error, "Skill generation failed: model did not call save_skill."}

        _ ->
          hint = enablement_hint(opts, skill_placeholder(opts))
          {:ok, append_hint(completion.response, hint)}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec ensure_generate_prereqs(String.t(), map()) :: :ok | {:error, String.t()}
  defp ensure_generate_prereqs("global", _opts), do: :ok
  defp ensure_generate_prereqs("project", opts), do: ensure_project_for_generate(opts)

  @spec save_scope(map()) :: String.t()
  defp save_scope(%{global: true}), do: "global"
  defp save_scope(_opts), do: "project"

  @spec ensure_project_for_generate(map()) :: :ok | {:error, String.t()}
  defp ensure_project_for_generate(%{project: project})
       when is_binary(project) and project != "" do
    Settings.set_project(project)
    :ok
  end

  defp ensure_project_for_generate(_opts) do
    case ResolveProject.resolve() do
      {:ok, pn} ->
        Settings.set_project(pn)
        :ok

      _ ->
        {:error,
         "No project provided and could not auto-detect from cwd. Pass --project or use --global to create a global skill."}
    end
  end

  @spec generate_system_prompt(String.t()) :: String.t()
  defp generate_system_prompt(scope) do
    """
    You are generating a fnord Skill definition.

    Rules:
    - You MUST call the `save_skill` tool exactly once.
    - The tool call MUST include a `scope` argument equal to "#{scope}".
    - Tool tags are not tool names. You MUST choose tool tags ONLY from this list:
      #{Enum.join(Skills.Runtime.allowed_toolboxes(), ", ")}
    - The tool tag "basic" is REQUIRED in every skill.
    - If the skill needs to use the cursor-agent frob, include the "frobs" tag (do not invent a tag like "cursor-agent").
    - You cannot enable or disable skills; you cannot change permissions.
    - If you include the "rw" tool tag, explain that the user must run fnord with `--edit`; you cannot bypass this.

    After the tool call succeeds, print the exact CLI commands from the enablement hints in the user prompt.
    """
    |> String.trim()
  end

  @spec generate_user_prompt(map()) :: {:ok, String.t()} | {:error, String.t()}
  defp generate_user_prompt(opts) do
    name_hint = generate_name_hint(opts)
    scope_hint = generate_scope_hint(opts)

    case enablement_command_hints(opts) do
      {:ok, enablement_hints} ->
        prompt =
          """
          Skill request:
          #{opts.description}

          #{name_hint}
          #{scope_hint}

          Enablement hints (print these commands after saving; do not claim you ran them):
          #{enablement_hints}
          """
          |> String.trim()

        {:ok, prompt}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec generate_name_hint(map()) :: String.t()
  defp generate_name_hint(%{name: name}) when is_binary(name) and name != "" do
    "Use skill name: #{name}"
  end

  defp generate_name_hint(_opts) do
    "Choose a short, descriptive slug name matching [a-z0-9][a-z0-9_-]*."
  end

  @spec generate_scope_hint(map()) :: String.t()
  defp generate_scope_hint(%{global: true}), do: "Save as a global (user) skill."

  defp generate_scope_hint(%{project: project}) when is_binary(project) and project != "" do
    "Save as a project skill for project: #{project}."
  end

  defp generate_scope_hint(_opts) do
    case Settings.get_selected_project() do
      {:ok, project} -> "Save as a project skill for the selected project: #{project}."
      _ -> "Save as a project skill (project selection should already be set)."
    end
  end

  @spec enablement_command_hints(map()) :: {:ok, String.t()} | {:error, String.t()}
  defp enablement_command_hints(%{enable: false} = _opts), do: {:ok, "(none)"}

  defp enablement_command_hints(%{enable: true, global: true} = opts) do
    skill = skill_placeholder(opts)

    commands =
      "fnord skills enable --skill #{skill} --global\n" <>
        "fnord skills disable --skill #{skill} --global"

    {:ok, commands}
  end

  defp enablement_command_hints(%{enable: true, project: project} = opts)
       when is_binary(project) and project != "" do
    with :ok <- validate_project_exists(project) do
      skill = skill_placeholder(opts)

      commands =
        "fnord skills enable --skill #{skill} --project #{project}\n" <>
          "fnord skills disable --skill #{skill} --project #{project}"

      {:ok, commands}
    end
  end

  defp enablement_command_hints(%{enable: true} = opts) do
    with {:ok, project} <- ResolveProject.resolve(),
         :ok <- validate_project_exists(project) do
      skill = skill_placeholder(opts)

      commands =
        "fnord skills enable --skill #{skill} --project #{project}\n" <>
          "fnord skills disable --skill #{skill} --project #{project}"

      {:ok, commands}
    end
  end

  @spec validate_project_exists(String.t()) :: :ok | {:error, String.t()}
  defp validate_project_exists(project) do
    projects = Settings.list_projects(Settings.new())

    if project in projects do
      :ok
    else
      {:error, "Unknown project '#{project}'."}
    end
  end

  @spec skill_placeholder(map()) :: String.t()
  defp skill_placeholder(%{name: name}) when is_binary(name) and name != "", do: name
  defp skill_placeholder(_opts), do: "<SKILL>"

  @spec enablement_hint(map(), String.t()) :: String.t()
  defp enablement_hint(%{enable: true}, _skill), do: ""

  defp enablement_hint(%{enable: false, global: true}, skill) do
    "Use `fnord skills enable --skill #{skill} --global` to enable this skill."
  end

  defp enablement_hint(%{enable: false}, skill) do
    "Use `fnord skills enable --skill #{skill}` to enable this skill for the selected project."
  end

  @spec append_hint(String.t(), String.t()) :: String.t()
  defp append_hint(response, ""), do: response
  defp append_hint(response, hint), do: response <> "\n\n" <> hint

  # Resolve --global / --project flags into a scope, defaulting to the
  # currently selected project when neither is given.
  defp resolve_scope(opts) do
    cond do
      opts[:global] ->
        {:ok, :global}

      is_binary(opts[:project]) and byte_size(opts[:project]) > 0 ->
        {:ok, {:project, opts[:project]}}

      true ->
        case Settings.get_selected_project() do
          {:ok, _pn} -> {:ok, :project}
          _ -> {:error, "No project selected. Use --global or --project <name>."}
        end
    end
  end

  defp scope_label(:global), do: "global"
  defp scope_label({:project, name}), do: "project: #{name}"
  defp scope_label(:project), do: "project (selected)"

  # ---------------------------------------------------------------------------
  # Skill TOML template
  #
  # Used by `new` to pre-populate the editor with a commented skeleton showing
  # all fields and their allowed values.
  # ---------------------------------------------------------------------------

  defp skill_template do
    models = Skills.Runtime.allowed_model_presets() |> Enum.join(", ")
    tools = Skills.Runtime.allowed_toolboxes() |> Enum.join(", ")

    """
    # Skill definition
    #
    # Required fields: name, description, model, tools, system_prompt
    # Optional fields: [response_format] table

    # A unique identifier for this skill (used in CLI commands and settings).
    name = "my-skill"

    # Shown to fnord's coordinator when deciding whether to use this skill.
    # Include caller-facing instructions here: what input to provide, what
    # scope or context the agent expects, etc.
    description = "A short description of what this skill does"

    # Model presets: #{models}
    model = "balanced"

    # Tool tags (pick one or more): #{tools}
    tools = ["basic"]

    # The system prompt sent to the model when this skill is invoked.
    # This is the agent's private instructions - the coordinator does not see it.
    # Use triple-quoted strings for multi-line prompts.
    system_prompt = \"\"\"
    You are a helpful assistant.
    \"\"\"
    """
  end

  # Write a skill TOML file to the given directory using atomic writes.
  defp write_skill_toml(dir, name, %Skills.Skill{} = skill) do
    with {:ok, toml} <- Skills.Toml.encode_skill(skill) do
      File.mkdir_p!(dir)
      path = Path.join(dir, "#{name}.toml")
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

  # After saving a new skill, prompt the user to enable it for specific
  # projects, globally, or not at all.
  defp prompt_enablement(name, _opts) do
    projects = Settings.list_projects(Settings.new())
    choices = ["(global)" | projects] ++ ["(skip)"]

    label = "Enable #{name} for which scopes? (space-separated numbers or ranges)"

    case UI.choose_multi(label, choices, default: []) do
      selections when is_list(selections) ->
        global? = Enum.member?(selections, "(global)")

        Enum.each(selections, fn
          "(skip)" ->
            :ok

          "(global)" ->
            Settings.Skills.enable(:global, name)

          project ->
            # Skip per-project enablement if global was also selected
            unless global? do
              Settings.Skills.enable({:project, project}, name)
            end
        end)

      _ ->
        :ok
    end
  end

  defp maybe_set_project_from_opts(%{project: nil}), do: :ok

  defp maybe_set_project_from_opts(%{project: project}) when is_binary(project) do
    Settings.set_project(project)
    :ok
  end

  # Validate model and tools
  defp validate_model_and_tools(model, tools) do
    with {:ok, _} <- Skills.Runtime.model_from_string(model),
         {:ok, _} <- Skills.Runtime.toolbox_from_tags(tools) do
      :ok
    end
  end

  # Ensures that a project has been selected before proceeding.
  # Returns {:ok, project_name, project_dir} if a project is set,
  # or {:error, :no_project_selected} otherwise.
  defp ensure_project_selected do
    case Settings.get_selected_project() do
      {:ok, project} ->
        case Skills.project_skills_dir() do
          {:ok, project_dir} -> {:ok, project, project_dir}
          {:error, reason} -> {:error, reason}
        end

      {:error, _} ->
        {:error, :no_project_selected}
    end
  end

  # Returns the project skills dir when a project is selected, otherwise the
  # user-global skills dir. Ensures new/edit write to the same location that
  # remove operates on.
  defp skill_write_dir do
    case Skills.project_skills_dir() do
      {:ok, dir} -> dir
      _ -> Skills.user_skills_dir()
    end
  end

  defp return_no_project_error(), do: {:error, "No project selected. Pass --project <name>."}
end
