defmodule DockerSandbox.Runner do
  @moduledoc false
  # removed compile-time CLI binding; will fetch dynamically at runtime for testability

  @managed_label "fnord.managed"
  @sandbox_name_label "fnord.sandbox_name"
  @sandbox_nonce_label "fnord.sandbox_nonce"
  @sandbox_base_hash_label "fnord.base_hash"

  @spec build_image(String.t(), String.t(), String.t()) ::
          {:ok, String.t()}
          | {:warning, %{tag: String.t(), warning: term()}}
          | {:error, term()}
  def build_image(name, dockerfile_body, project_source_root) do
    cli = Application.get_env(:fnord, :docker_cli, DockerSandbox.CLI)

    case DockerSandbox.BaseImage.ensure_base_image() do
      base_result ->
        base_warning =
          case base_result do
            {:warning, msg} -> msg
            _ -> nil
          end

        nonce = :erlang.unique_integer([:positive]) |> Integer.to_string()
        tag = "fnord/sandbox-#{name}:#{nonce}"

        tmp_dir = Services.TempFile.mktemp!(directory: true)

        try do
          dockerfile_path = Path.join(tmp_dir, "Dockerfile")
          context_tar_path = Path.join(tmp_dir, "context.tar")

          # Generate full Dockerfile content with boilerplate header and base image
          boilerplate = """
          # fnord-docker-sandbox
          # ---
          FROM #{DockerSandbox.BaseImage.tag()}
          """

          full_dockerfile = boilerplate <> "\n" <> dockerfile_body
          File.write!(dockerfile_path, full_dockerfile)

          # Build context must not be a host path directory. We build a tarball of the repo.
          # Prefer `git archive` (respects committed state). Fall back to a plain tar of the
          # working directory if the project is not a git repo.
          case build_context_tar(project_source_root, context_tar_path) do
            :ok ->
              args = [
                "build",
                "-t",
                tag,
                "--label",
                "#{@managed_label}=true",
                "--label",
                "#{@sandbox_name_label}=#{name}",
                "--label",
                "#{@sandbox_nonce_label}=#{nonce}",
                "--label",
                "#{@sandbox_base_hash_label}=#{DockerSandbox.BaseImage.base_hash()}",
                "-f",
                dockerfile_path,
                context_tar_path
              ]

              case cli.cmd("docker", args, []) do
                {_, 0} ->
                  if base_warning do
                    {:warning, %{tag: tag, warning: base_warning}}
                  else
                    {:ok, tag}
                  end

                {err, code} ->
                  {:error, %{code: code, err: err}}
              end

            {:error, reason} ->
              {:error, reason}
          end
        after
          File.rm_rf!(tmp_dir)
        end
    end
  end

  @spec build_context_tar(String.t(), String.t()) :: :ok | {:error, term()}
  defp build_context_tar(project_source_root, out_tar_path) do
    cond do
      System.find_executable("git") == nil ->
        tar_workdir(project_source_root, out_tar_path)

      git_repo?(project_source_root) ->
        git_archive(project_source_root, out_tar_path)

      true ->
        tar_workdir(project_source_root, out_tar_path)
    end
  end

  defp git_repo?(dir) do
    case System.cmd("git", ["rev-parse", "--is-inside-work-tree"],
           cd: dir,
           stderr_to_stdout: true
         ) do
      {out, 0} -> String.trim(out) == "true"
      _ -> false
    end
  end

  defp git_archive(dir, out_tar_path) do
    args = ["archive", "--format=tar", "--output=#{out_tar_path}", "HEAD"]

    case System.cmd("git", args, cd: dir, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, code} -> {:error, %{code: code, err: out}}
    end
  end

  defp tar_workdir(dir, out_tar_path) do
    cond do
      System.find_executable("tar") == nil ->
        {:error, :tar_not_available}

      true ->
        # `tar -C <dir> -cf <out> .`
        case System.cmd("tar", ["-C", dir, "-cf", out_tar_path, "."], stderr_to_stdout: true) do
          {_, 0} -> :ok
          {out, code} -> {:error, %{code: code, err: out}}
        end
    end
  end

  @spec run_container(String.t(), [String.t()], keyword()) ::
          {:ok, String.t()} | {:error, %{code: non_neg_integer(), err: String.t()}}
  def run_container(image, run_args, opts \\ []) do
    cli = Application.get_env(:fnord, :docker_cli, DockerSandbox.CLI)
    timeout_ms = Keyword.get(opts, :timeout_ms)

    flags = [
      "run",
      "--rm",
      "--network=none",
      "--read-only",
      "--cap-drop=ALL",
      "--security-opt=no-new-privileges",
      "--pull=never",
      "--memory=512m",
      "--cpus=0.5",
      "--pids-limit=64",
      "--tmpfs",
      "/tmp:rw,nodev,nosuid,size=65536k"
    ]

    args = flags ++ [image] ++ run_args
    cmd_opts = if timeout_ms, do: [timeout: timeout_ms], else: []

    case cli.cmd("docker", args, cmd_opts) do
      {out, 0} -> {:ok, out}
      {err, code} -> {:error, %{code: code, err: err}}
    end
  end
end
