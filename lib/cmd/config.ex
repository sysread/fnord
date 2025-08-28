defmodule Cmd.Config do
  @behaviour Cmd

  @impl Cmd
  def requires_project?(), do: false

  @impl Cmd
  def spec do
    [
      config: [
        name: "config",
        about: "Manage configuration settings",
        subcommands: [
          list: [
            name: "list",
            about: "List configuration settings (global or project-specific)",
            options: [
              project: Cmd.project_arg()
            ]
          ],
          set: [
            name: "set",
            about: "Set a configuration directive for a project",
            options: [
              project: Cmd.project_arg(),
              root: [
                value_name: "ROOT",
                long: "--root",
                short: "-r",
                help: "Root directory for the project",
                required: false
              ],
              exclude: [
                value_name: "EXCLUDE",
                long: "--exclude",
                short: "-x",
                help: "Exclude files from the project",
                required: false,
                multiple: true
              ]
            ]
          ],
          approvals: [
            name: "approvals",
            about: "List approval patterns (global or project)",
            options: [
              project: Cmd.project_arg()
            ],
            flags: [
              global: [
                long: "--global",
                short: "-g",
                help: "Use global approvals",
                required: false
              ]
            ]
          ],
          approve: [
            name: "approve",
            about: "Add an approval regex under a kind (scope: global|project)",
            args: [
              pattern: [
                value_name: "PATTERN",
                help: "Regex to approve",
                required: true
              ]
            ],
            options: [
              project: Cmd.project_arg(),
              kind: [
                value_name: "KIND",
                long: "--kind",
                short: "-k",
                help: "Approval kind",
                required: true
              ]
            ],
            flags: [
              global: [
                long: "--global",
                short: "-g",
                help: "Add to global scope. If not set, new patterns are added to project scope.",
                required: false
              ]
            ]
          ],
          mcp: [
            name: "mcp",
            about: "Manage MCP server configuration",
            subcommands: [
              list: [
                name: "list",
                about: "List MCP config (global, project, or effective merge)",
                options: [
                  project: Cmd.project_arg()
                ],
                flags: [
                  global: [
                    long: "--global",
                    short: "-g",
                    help: "Use global scope",
                    required: false
                  ],
                  effective: [
                    long: "--effective",
                    short: "-e",
                    help: "Show merged effective config",
                    required: false
                  ]
                ]
              ],
              enable: [
                name: "enable",
                about: "Enable MCP server scope",
                options: [
                  project: Cmd.project_arg()
                ],
                flags: [
                  global: [
                    long: "--global",
                    short: "-g",
                    help: "Enable global MCP configuration",
                    required: false
                  ]
                ]
              ],
              disable: [
                name: "disable",
                about: "Disable MCP server scope",
                options: [
                  project: Cmd.project_arg()
                ],
                flags: [
                  global: [
                    long: "--global",
                    short: "-g",
                    help: "Disable global MCP configuration",
                    required: false
                  ]
                ]
              ],
              add: [
                name: "add",
                about: "Add an MCP server (global or project)",
                args: [
                  name: [value_name: "NAME", help: "Server identifier", required: true]
                ],
                options: [
                  project: Cmd.project_arg(),
                  transport: [
                    value_name: "TRANSPORT",
                    long: "--transport",
                    short: "-t",
                    help: "Transport type (stdio|streamable_http|websocket)",
                    required: true
                  ],
                  command: [
                    value_name: "CMD",
                    long: "--command",
                    help: "Command for stdio transport",
                    required: false
                  ],
                  arg: [
                    value_name: "ARG",
                    long: "--arg",
                    help: "Argument for stdio transport (repeatable)",
                    required: false,
                    multiple: true
                  ],
                  base_url: [
                    value_name: "URL",
                    long: "--base-url",
                    help: "Base URL for HTTP/WebSocket transports",
                    required: false
                  ],
                  header: [
                    value_name: "HEADER",
                    long: "--header",
                    help: "Header for HTTP/WebSocket transports (KEY=VALUE, repeatable)",
                    required: false,
                    multiple: true
                  ],
                  env: [
                    value_name: "ENV",
                    long: "--env",
                    help: "Environment variable for stdio transport (KEY=VALUE, repeatable)",
                    required: false,
                    multiple: true
                  ],
                  timeout_ms: [
                    value_name: "MS",
                    long: "--timeout-ms",
                    help: "Timeout in milliseconds",
                    required: false
                  ]
                ],
                flags: [
                  global: [
                    long: "--global",
                    short: "-g",
                    help: "Add server to global configuration",
                    required: false
                  ]
                ]
              ],
              update: [
                name: "update",
                about: "Update an MCP server configuration",
                args: [
                  name: [value_name: "NAME", help: "Server identifier", required: true]
                ],
                options: [
                  project: Cmd.project_arg(),
                  transport: [
                    value_name: "TRANSPORT",
                    long: "--transport",
                    short: "-t",
                    help: "Transport type (stdio|streamable_http|websocket)",
                    required: true
                  ],
                  command: [
                    value_name: "CMD",
                    long: "--command",
                    help: "Command for stdio transport",
                    required: false
                  ],
                  arg: [
                    value_name: "ARG",
                    long: "--arg",
                    help: "Argument for stdio transport (repeatable)",
                    required: false,
                    multiple: true
                  ],
                  base_url: [
                    value_name: "URL",
                    long: "--base-url",
                    help: "Base URL for HTTP/WebSocket transports",
                    required: false
                  ],
                  header: [
                    value_name: "HEADER",
                    long: "--header",
                    help: "Header for HTTP/WebSocket transports (KEY=VALUE, repeatable)",
                    required: false,
                    multiple: true
                  ],
                  env: [
                    value_name: "ENV",
                    long: "--env",
                    help: "Environment variable for stdio transport (KEY=VALUE, repeatable)",
                    required: false,
                    multiple: true
                  ],
                  timeout_ms: [
                    value_name: "MS",
                    long: "--timeout-ms",
                    help: "Timeout in milliseconds",
                    required: false
                  ]
                ],
                flags: [
                  global: [
                    long: "--global",
                    short: "-g",
                    help: "Update server in global configuration",
                    required: false
                  ]
                ]
              ],
              remove: [
                name: "remove",
                about: "Remove an MCP server (global or project)",
                args: [
                  name: [value_name: "NAME", help: "Server identifier", required: true]
                ],
                options: [
                  project: Cmd.project_arg()
                ],
                flags: [
                  global: [
                    long: "--global",
                    short: "-g",
                    help: "Remove server from global configuration",
                    required: false
                  ]
                ]
              ]
            ]
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(_opts, [:list], _unknown) do
    settings = Settings.new()

    global = %{
      "approvals" => Settings.Approvals.get_approvals(settings, :global)
    }

    with {:ok, project} <- Store.get_project() do
      case Settings.get_project_data(settings, project.name) do
        nil ->
          UI.error("Project not found")

        config ->
          global
          |> Map.merge(config)
          |> Jason.encode!(pretty: true)
          |> IO.puts()
      end
    else
      {:error, _} -> UI.error("Project not found")
    end
  end

  def run(opts, [:set], _unknown) do
    case opts[:project] do
      nil ->
        UI.error("Project option is required for set command. Use --project PROJECT_NAME.")

      project_name ->
        Settings.set_project(project_name)

        with {:ok, project} <- Store.get_project() do
          if !Store.Project.exists_in_store?(project) do
            UI.error("""
            Project '#{project.name}' does not exist.
            Please create it with: `fnord index`
            """)
          else
            Store.Project.save_settings(project, opts[:root], opts[:exclude])
            run(opts, [:list], [])
          end
        else
          {:error, _} -> UI.error("Project not found")
        end
    end
  end

  def run(opts, [:approvals], _unknown) do
    cond do
      opts[:global] && opts[:project] ->
        build_list()
        |> Jason.encode!(pretty: true)
        |> IO.puts()

      opts[:global] ->
        build_list(:global)
        |> Jason.encode!(pretty: true)
        |> IO.puts()

      true ->
        case Settings.get_selected_project() do
          {:ok, _proj} ->
            build_list(:project)
            |> Jason.encode!(pretty: true)
            |> IO.puts()

          {:error, _} ->
            UI.error("Project not specified or not found")
        end
    end
  end

  def run(opts, [:approve], [pattern]) do
    cond do
      opts[:global] && opts[:project] ->
        UI.error("Cannot use both --global and --project.")

      is_nil(opts[:kind]) ->
        UI.error("Missing --kind option.")

      true ->
        scope = if opts[:global], do: :global, else: :project
        if scope == :project && opts[:project], do: Settings.set_project(opts[:project])
        settings = Settings.new()

        case build_approve(settings, scope, opts[:kind], pattern) do
          {:ok, data} ->
            data
            |> Jason.encode!(pretty: true)
            |> IO.puts()

          {:error, msg} ->
            UI.error(msg)
        end
    end
  end

  def run(opts, [:mcp, :list], _unknown) do
    settings = Settings.new()

    cond do
      opts[:effective] ->
        Settings.MCP.effective_config(settings)
        |> Jason.encode!(pretty: true)
        |> IO.puts()

      opts[:global] ->
        Settings.MCP.get_config(settings, :global)
        |> Jason.encode!(pretty: true)
        |> IO.puts()

      true ->
        if opts[:project], do: Settings.set_project(opts[:project])

        case Settings.get_selected_project() do
          {:ok, _proj} ->
            Settings.MCP.get_config(settings, :project)
            |> Jason.encode!(pretty: true)
            |> IO.puts()

          {:error, _} ->
            UI.error("Project not specified or not found")
        end
    end
  end

  def run(opts, [:mcp, :enable], _unknown) do
    if opts[:project], do: Settings.set_project(opts[:project])
    settings = Settings.new()
    scope = if opts[:global], do: :global, else: :project
    updated = Settings.MCP.enable(settings, scope)

    Settings.MCP.get_config(updated, scope)
    |> Jason.encode!(pretty: true)
    |> IO.puts()
  end

  def run(opts, [:mcp, :disable], _unknown) do
    if opts[:project], do: Settings.set_project(opts[:project])
    settings = Settings.new()
    scope = if opts[:global], do: :global, else: :project
    updated = Settings.MCP.disable(settings, scope)

    Settings.MCP.get_config(updated, scope)
    |> Jason.encode!(pretty: true)
    |> IO.puts()
  end

  def run(opts, [:mcp, :add], [name]) do
    if opts[:project], do: Settings.set_project(opts[:project])
    raw_cfg = build_server_config_from_opts(opts)
    settings = Settings.new()
    scope = if opts[:global], do: :global, else: :project

    case Settings.MCP.add_server(settings, scope, name, raw_cfg) do
      {:ok, updated} ->
        scfg = Settings.MCP.list_servers(updated, scope)[name]

        %{name => scfg}
        |> Jason.encode!(pretty: true)
        |> IO.puts()

      {:error, :exists} ->
        UI.error("Server '#{name}' already exists")

      {:error, msg} ->
        UI.error(msg)
    end
  end

  def run(opts, [:mcp, :update], [name]) do
    if opts[:project], do: Settings.set_project(opts[:project])
    raw_cfg = build_server_config_from_opts(opts)
    settings = Settings.new()
    scope = if opts[:global], do: :global, else: :project

    case Settings.MCP.update_server(settings, scope, name, raw_cfg) do
      {:ok, updated} ->
        scfg = Settings.MCP.list_servers(updated, scope)[name]

        %{name => scfg}
        |> Jason.encode!(pretty: true)
        |> IO.puts()

      {:error, :not_found} ->
        UI.error("Server '#{name}' not found")

      {:error, msg} ->
        UI.error(msg)
    end
  end

  def run(opts, [:mcp, :remove], [name]) do
    if opts[:project], do: Settings.set_project(opts[:project])
    settings = Settings.new()
    scope = if opts[:global], do: :global, else: :project

    case Settings.MCP.remove_server(settings, scope, name) do
      {:ok, new_settings} ->
        Settings.MCP.list_servers(new_settings, scope)
        |> Jason.encode!(pretty: true)
        |> IO.puts()

      {:error, :not_found} ->
        UI.error("Server '#{name}' not found")
    end
  end

  def run(_opts, [], _unknown) do
    UI.error("No subcommand specified. Use 'fnord help config' for help.")
  end

  def run(_opts, _subcommands, _unknown) do
    UI.error("Unknown subcommand. Use 'fnord help config' for help.")
  end

  # Helpers to parse CLI options for MCP server configuration
  defp build_server_config_from_opts(opts) do
    %{}
    |> Map.put("transport", opts[:transport])
    |> maybe_put("command", opts[:command])
    |> maybe_put("args", opts[:arg] || [])
    |> maybe_put("base_url", opts[:base_url])
    |> maybe_put("headers", parse_kv_list(opts[:header] || []))
    |> maybe_put("env", parse_kv_list(opts[:env] || []))
    |> maybe_put("timeout_ms", opts[:timeout_ms])
  end

  @spec maybe_put(map(), String.t(), any()) :: map()
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @spec parse_kv_list(nil | [String.t()]) :: map()
  defp parse_kv_list(nil), do: %{}

  defp parse_kv_list(list) when is_list(list) do
    Enum.reduce(list, %{}, fn kv, acc ->
      case String.split(kv, "=", parts: 2) do
        [k, v] -> Map.put(acc, k, v)
        _ -> acc
      end
    end)
  end

  defp build_list(:global) do
    Settings.new()
    |> Settings.Approvals.get_approvals(:global)
  end

  defp build_list(:project) do
    Settings.new()
    |> Settings.Approvals.get_approvals(:project)
  end

  defp build_list() do
    global = build_list(:global)
    project = build_list(:project)

    Enum.concat([
      Map.keys(global),
      Map.keys(project)
    ])
    |> Enum.uniq()
    |> Enum.map(fn kind ->
      {
        kind,
        %{
          global: Map.get(global, kind, []),
          project: Map.get(project, kind, [])
        }
      }
    end)
    |> Enum.into(%{})
  end

  defp build_approve(settings, scope, kind, pattern) do
    try do
      new_settings = Settings.Approvals.approve(settings, scope, kind, pattern)
      patterns = Settings.Approvals.get_approvals(new_settings, scope, kind)
      {:ok, %{kind => patterns}}
    rescue
      e in Regex.CompileError ->
        {:error, "Invalid regex: #{e.message}"}
    end
  end
end
