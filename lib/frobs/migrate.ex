defmodule Frobs.Migrate do
  @moduledoc """
  One-time migration from per-frob registry.json files to settings.json
  frob arrays. After successful migration of a frob, its registry.json is
  deleted to prevent stale configuration.
  """

  defp tools_dir() do
    Path.join([Settings.get_user_home(), "fnord", "tools"])
  end

  @spec maybe_migrate_registry_to_settings() :: :ok
  def maybe_migrate_registry_to_settings() do
    # Guard to avoid repeated migrations.
    if Application.get_env(:fnord, :frobs_migrated_runtime, false) do
      :ok
    else
      migrate_all()
      Application.put_env(:fnord, :frobs_migrated_runtime, true)
      :ok
    end
  end

  defp migrate_all() do
    tools_dir()
    |> Path.join("*/registry.json")
    |> Path.wildcard()
    |> Enum.each(&migrate_one/1)
  end

  defp migrate_one(registry_path) do
    frob_name = registry_path |> Path.dirname() |> Path.basename()

    with {:ok, json} <- File.read(registry_path),
         {:ok, data} <- Jason.decode(json) do
      if Map.get(data, "global") == true do
        Settings.Frobs.enable(:global, frob_name)
      end

      if is_list(data["projects"]) do
        Enum.each(data["projects"], fn pn ->
          unless project_migrated?(pn) do
            Settings.Frobs.enable({:project, pn}, frob_name)
          end
        end)
      end

      safe_delete(registry_path)
    else
      _ -> :ok
    end
  end

  defp project_migrated?(project_name) do
    settings = Settings.new()
    pdata = Settings.get_project_data(settings, project_name) || %{}
    Map.has_key?(pdata, "frobs")
  end

  defp safe_delete(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, _} -> :ok
    end
  end
end

