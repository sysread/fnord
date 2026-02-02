defmodule DockerSandbox.BaseImage do
  @moduledoc false

  alias Jason

  @image_repo "fnord/sandbox-base"
  @managed_label "fnord.managed"
  @base_hash_label "fnord.base_hash"
  @base_version_label "fnord.base_version"

  @spec dockerfile_text() :: String.t()
  def dockerfile_text do
    # NOTE: this base Dockerfile is intentionally embedded in code (not on disk)
    # so callers cannot tamper with it.
    # Keep it minimal; sandboxes should add what they need in their own Dockerfile.
    """
    FROM alpine:latest
    WORKDIR /workdir
    RUN mkdir -p /workdir
    """
  end

  @spec base_hash() :: String.t()
  def base_hash do
    :crypto.hash(:sha256, dockerfile_text())
    |> Base.encode16(case: :lower)
  end

  @spec tag() :: String.t()
  def tag do
    short = String.slice(base_hash(), 0, 12)
    "#{@image_repo}:#{short}"
  end

  @spec ensure_base_image() :: {:ok, :unchanged} | {:warning, String.t()}
  def ensure_base_image do
    cli = Application.get_env(:fnord, :docker_cli, DockerSandbox.CLI)
    tag = tag()
    version = Settings.get_running_version()

    expected = %{
      @managed_label => "true",
      @base_hash_label => base_hash(),
      @base_version_label => version
    }

    case cli.cmd("docker", ["image", "inspect", "--format", "{{json .Config.Labels}}", tag], []) do
      {labels_json, 0} ->
        labels =
          case Jason.decode(labels_json) do
            {:ok, decoded} when is_map(decoded) -> decoded
            _ -> %{}
          end

        if Map.take(labels, Map.keys(expected)) == expected do
          {:ok, :unchanged}
        else
          rebuild_base(cli, tag)
        end

      _ ->
        rebuild_base(cli, tag)
    end
  end

  @spec rebuild_base(module(), String.t()) :: {:warning, String.t()}
  defp rebuild_base(cli, tag) do
    version = Settings.get_running_version()
    temp_dir = Services.TempFile.mktemp!(directory: true)

    try do
      dockerfile_path = Path.join(temp_dir, "Dockerfile")
      File.write!(dockerfile_path, dockerfile_text())

      {out, _code} =
        cli.cmd(
          "docker",
          [
            "build",
            "-t",
            tag,
            "--label",
            "#{@managed_label}=true",
            "--label",
            "#{@base_hash_label}=#{base_hash()}",
            "--label",
            "#{@base_version_label}=#{version}",
            temp_dir
          ],
          []
        )

      {:warning, "Rebuilt base image #{tag}: #{String.trim(out)}"}
    after
      File.rm_rf!(temp_dir)
    end
  end
end
