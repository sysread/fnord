defmodule Settings.Migrate do
  # ----------------------------------------------------------------------------
  # Cleans up the "default" project directory within the store on startup.
  #
  # This function exists to remove any lingering "default" project data which
  # might cause inconsistencies or conflicts. It is safe to call repeatedly
  # and will not raise errors if the directory does not exist. Moreover, no
  # code depends on this directory being present, so removing it has no adverse
  # side effects.
  # ----------------------------------------------------------------------------
  def cleanup_default_project_dir do
    path = Path.join(Settings.home(), "default")

    if File.exists?(path) do
      File.rm_rf!(path)
    end
  end

  def maybe_migrate_settings(path) do
    ver = Settings.get_running_version()

    if Version.compare(ver, "0.8.30") != :lt do
      data =
        with {:ok, content} <- File.read(path),
             {:ok, parsed} <- Jason.decode(content) do
          parsed
        else
          _ ->
            raise """
            Corrupted settings file: #{path}

            You may need to reset your fnord settings. Consider backing up the file
            and running 'fnord init' to recreate it.
            """
        end

      globals = ["approvals", "projects", "version"]
      {projects, globals_map} = Enum.split_with(data, fn {k, _v} -> k not in globals end)

      if Map.has_key?(data, "projects") do
        :ok
      else
        new_data =
          globals_map
          |> Map.new()
          |> Map.put("projects", Map.new(projects))
          |> Map.put("version", "0.8.30")
          |> Map.put_new("approvals", %{})
          |> Jason.encode!(pretty: true)

        Settings.write_atomic!(path, new_data)
      end
    end
  end
end
