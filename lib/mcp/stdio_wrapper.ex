defmodule MCP.STDIOWrapper do
  @moduledoc """
  Creates a small executable wrapper for stdio MCP servers.

  Hermes' stdio transport reads JSON-RPC from the child's stdout. Many MCP servers
  also write human-readable logs to stderr.

  This module generates a temporary wrapper script that:

  - Executes the real server command (passed as the wrapper's first argument)
  - Captures the server's stderr to a temp file
  - Replays captured stderr only when the server exits non-zero

  This keeps successful runs quiet while preserving debugging output for failures.
  """

  @type path :: binary()

  @spec script_path() :: {:ok, path()} | {:error, term()}
  def script_path do
    with {:ok, path} <- Services.TempFile.mktemp(prefix: "fnord-mcp-stdio-", suffix: "-wrapper"),
         :ok <- File.write(path, script_body()),
         :ok <- File.chmod(path, 0o700) do
      {:ok, path}
    end
  end

  @spec script_path!() :: path()
  def script_path! do
    case script_path() do
      {:ok, path} -> path
      {:error, reason} -> raise "Failed to create MCP stdio wrapper: #{inspect(reason)}"
    end
  end

  defp script_body do
    """
    #!/usr/bin/env bash

    set -eu -o pipefail

    if [[ "$#" -lt 1 ]]; then
      echo "fnord mcp stdio wrapper: missing command" >&2
      exit 127
    fi

    cmd="$1"
    shift

    stderr_file=""

    cleanup() {
      if [[ -n "${stderr_file}" && -e "${stderr_file}" ]]; then
        rm -f "${stderr_file}" || true
      fi
    }

    trap cleanup EXIT

    stderr_file="$(mktemp -t fnord-mcp-stderr.XXXXXX)"

    set +e
    "${cmd}" "$@" 2>"${stderr_file}"
    status=$?
    set -e

    if [[ ${status} -ne 0 ]]; then
      cat "${stderr_file}" >&2 || true
    fi

    exit ${status}
    """
  end
end
