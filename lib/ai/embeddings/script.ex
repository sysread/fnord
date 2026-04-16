defmodule AI.Embeddings.Script do
  @moduledoc """
  Manages the standalone embed.exs script that runs the local embedding model.

  The script is stored as a module attribute and written to ~/.fnord/embed.exs
  on first use. It uses Bumblebee with all-MiniLM-L12-v2 (384-dim vectors,
  mean pooling) and supports both single-input and pooled JSONL streaming modes.
  """

  @script_filename "embed.exs"

  # The clang workaround wrapper invokes elixir with the CXX override needed
  # for Apple clang 17+ to compile EXLA's NIF without hard errors.
  @wrapper_filename "embed.sh"

  @embed_script ~S"""
  #!/usr/bin/env elixir

  #-------------------------------------------------------------------------------
  # Embedding generator
  #
  # Generates embedding vectors using Bumblebee with the all-MiniLM-L12-v2
  # sentence transformer (384-dimensional vectors, mean pooling).
  #
  # Two modes, dispatched by System.argv():
  #
  #   Single-input mode:
  #     elixir embed.exs <file>      # embed file contents, output JSON array
  #     echo "text" | elixir embed.exs -   # embed stdin text, output JSON array
  #
  #   Pool mode (JSONL streaming):
  #     ... | elixir embed.exs -n 4  # read JSONL from stdin, output JSONL
  #
  #     Pool mode loads the model once, then processes a stream of inputs
  #     via Task.Supervisor.async_stream_nolink with bounded concurrency.
  #     Each input line is a JSON object with "id" and "text" fields. Each
  #     output line is a JSON object with "id" and "embedding" fields.
  #     Results arrive in completion order.
  #
  #     Self-termination: when stdin closes (parent exit / broken pipe), the
  #     stream ends naturally and the BEAM exits. This prevents orphaned
  #     elixir processes when the caller is killed.
  #
  #
  # Dependencies: elixir (with Mix.install support)
  #
  # Compilation notes:
  #
  #   EXLA pins: EXLA 0.10.0 has a duplicate symbol linker error in the
  #   `fine` library's init functions across multiple translation units.
  #   Pinned to 0.9.2.
  #
  #   Clang workaround: Apple clang 17+ promotes a template warning to a
  #   hard error that breaks EXLA's NIF compilation. The caller (embed.sh)
  #   sets CXX with -Wno-error=missing-template-arg-list-after-template-kw
  #   before invoking this script.
  #-------------------------------------------------------------------------------

  # Route Elixir/EXLA log noise to stderr so stdout stays clean for JSON output.
  # Level is :critical rather than :warning because at shutdown the stdout pipe
  # may close before our async_stream workers finish writing. OTP's default
  # writer logs "Writer crashed (:epipe)" at :error level, which users would
  # see as spurious indexing noise. The actual write failures are handled
  # gracefully in the main loop below.
  {:ok, cfg} = :logger.get_handler_config(:default)
  cfg = Map.update!(cfg, :config, &Map.put(&1, :type, :standard_error))
  :ok = :logger.remove_handler(:default)
  :ok = :logger.add_handler(:default, :logger_std_h, cfg)
  :ok = :logger.set_primary_config(:level, :critical)

  # HuggingFace model weights live under ~/.fnord/models/. Bumblebee picks
  # this up via BUMBLEBEE_CACHE_DIR.
  cache_dir = Path.join([System.user_home!(), ".fnord", "models"])
  File.mkdir_p!(cache_dir)
  System.put_env("BUMBLEBEE_CACHE_DIR", cache_dir)

  Mix.install([
    {:bumblebee, "~> 0.6"},
    {:exla, "0.9.2"},
    {:jason, "~> 1.4"},
  ])

  Nx.global_default_backend(EXLA.Backend)

  defmodule Embed do
    @model "sentence-transformers/all-MiniLM-L12-v2"

    def load_serving do
      model_name = @model

      {:ok, model} = Bumblebee.load_model({:hf, model_name})
      {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, model_name})

      Bumblebee.Text.TextEmbedding.text_embedding(
        model,
        tokenizer,
        compile: [batch_size: 1, sequence_length: 256],
        defn_options: [compiler: EXLA],
        output_pool: :mean_pooling,
        output_attribute: :hidden_state
      )
    end

    def embed(serving, text) do
      %{embedding: tensor} = Nx.Serving.run(serving, text)
      Nx.to_flat_list(tensor)
    end
  end

  # Parse arguments to determine mode
  {opts, args} =
    case System.argv() do
      ["-n", n | rest] ->
        {[pool: String.to_integer(n)], rest}

      ["-n"] ->
        {[pool: 4], []}

      other ->
        {[], other}
    end

  # Load model (shared across both modes)
  serving = Embed.load_serving()

  case {opts[:pool], args} do
    # Pool mode: supervised JSONL streaming with stdin-close detection
    {concurrency, []} when is_integer(concurrency) ->
      {:ok, sup} = Task.Supervisor.start_link()

      # When the parent dies or Ctrl-C fires, stdin closes. IO.stream
      # ends, Stream.run returns, and the BEAM exits. In-flight tasks
      # under the supervisor get :shutdown signals automatically.
      #
      # Explicit SIGTERM/SIGINT handling: the BEAM's default signal
      # handlers shut down the VM cleanly, which stops the supervisor
      # and its children. No custom signal handling needed.

      # Decoupled producer-worker design.
      #
      # Why not Task.Supervisor.async_stream_nolink(sup, input_stream, fun)?
      # That pattern requires the input stream to signal :eof to flush results
      # back to the consumer. When embed.exs is spawned under an Erlang port,
      # stdin stays open indefinitely (the parent keeps the write end alive),
      # so the stream blocks on IO.binread waiting for the next line and
      # completed task results never get yielded. The pipeline stalls after
      # the first line.
      #
      # Solution: run a reader process that pushes lines as messages, and a
      # main receive loop that spawns workers and writes results as they come.
      # In-flight worker count is capped at `concurrency` to match the old
      # max_concurrency behavior.
      #
      # Why not IO.stream(:stdio, :line)? Under Erlang port spawn, :stdio
      # routes through a group leader that hangs on get_line from a piped
      # stdin. IO.binread bypasses the group leader.

      parent = self()

      spawn_link(fn ->
        read_loop = fn loop ->
          case IO.binread(:stdio, :line) do
            :eof ->
              send(parent, :reader_eof)

            {:error, _reason} ->
              send(parent, :reader_eof)

            line when is_binary(line) ->
              trimmed = String.trim(line)
              if trimmed != "", do: send(parent, {:reader_line, trimmed})
              loop.(loop)
          end
        end

        read_loop.(read_loop)
      end)

      # Safe writer: if stdout is closed by the parent (typical at shutdown),
      # treat the write failure as a clean exit signal. The default OTP
      # writer would log "Writer crashed (:epipe)" to stderr, which users see
      # as spurious indexing noise.
      write_line = fn line ->
        try do
          IO.puts(line)
          :ok
        rescue
          _ -> :closed
        catch
          :exit, _ -> :closed
        end
      end

      process_line = fn line ->
        try do
          case Jason.decode(line) do
            {:ok, %{"id" => id, "text" => text} = input} when is_binary(text) and text != "" ->
              try do
                embedding = Embed.embed(serving, text)

                input
                |> Map.delete("text")
                |> Map.put("embedding", embedding)
                |> Jason.encode!()
              rescue
                e ->
                  IO.puts(
                    :standard_error,
                    "embed: error computing embedding for id=#{inspect(id)}: " <>
                      Exception.format(:error, e, __STACKTRACE__)
                  )

                  Jason.encode!(%{id: id, error: "embed failure: #{Exception.message(e)}"})
              catch
                kind, reason ->
                  IO.puts(
                    :standard_error,
                    "embed: #{kind} computing embedding for id=#{inspect(id)}: #{inspect(reason)}"
                  )

                  Jason.encode!(%{id: id, error: "embed #{kind}: #{inspect(reason)}"})
              end

            {:ok, %{"id" => id}} ->
              Jason.encode!(%{id: id, error: "missing or empty text field"})

            {:error, _} ->
              Jason.encode!(%{error: "invalid JSON: #{String.slice(line, 0, 80)}"})
          end
        rescue
          e ->
            IO.puts(
              :standard_error,
              "embed: process_line failed: " <>
                Exception.format(:error, e, __STACKTRACE__)
            )

            Jason.encode!(%{error: "process_line failure: #{Exception.message(e)}"})
        end
      end

      # Receive loop: pull lines from the reader, cap in-flight worker count
      # at `concurrency`, write results to stdout as tasks complete. Exits
      # when the reader signals EOF and all pending workers have finished.
      #
      # If write_line returns :closed, stdout is gone (parent exited); we
      # halt immediately. The reader co-dies via spawn_link.
      # Each Task.Supervisor.async_nolink spawns a task that automatically
      # sends its return value back as {ref, result}, plus a {:DOWN, ref, ...}
      # on completion. We rely on the automatic message - do NOT also
      # send/2 manually, or receive will match the outer {task_ref, {my_ref,
      # result}} tuple and pass a tuple where a string is expected.
      loop = fn loop, in_flight, reader_done? ->
        cond do
          reader_done? and in_flight == 0 ->
            :ok

          in_flight >= concurrency ->
            receive do
              {ref, json_line} when is_reference(ref) and is_binary(json_line) ->
                Process.demonitor(ref, [:flush])

                case write_line.(json_line) do
                  :ok -> loop.(loop, in_flight - 1, reader_done?)
                  :closed -> :ok
                end

              {:DOWN, _ref, :process, _pid, _reason} ->
                loop.(loop, in_flight - 1, reader_done?)
            end

          true ->
            receive do
              {:reader_line, line} ->
                Task.Supervisor.async_nolink(sup, fn -> process_line.(line) end)
                loop.(loop, in_flight + 1, reader_done?)

              :reader_eof ->
                loop.(loop, in_flight, true)

              {ref, json_line} when is_reference(ref) and is_binary(json_line) ->
                Process.demonitor(ref, [:flush])

                case write_line.(json_line) do
                  :ok -> loop.(loop, in_flight - 1, reader_done?)
                  :closed -> :ok
                end

              {:DOWN, _ref, :process, _pid, _reason} ->
                loop.(loop, in_flight - 1, reader_done?)
            end
        end
      end

      loop.(loop, 0, false)

    # Single-input mode: embed one text, output bare JSON array
    {nil, ["-"]} ->
      text = IO.read(:stdio, :eof) |> String.trim()

      if text == "" do
        IO.puts(:standard_error, "error: empty input")
        System.halt(1)
      end

      Embed.embed(serving, text) |> Jason.encode!() |> IO.puts()

    {nil, [path]} ->
      case File.read(path) do
        {:ok, content} ->
          text = String.trim(content)

          if text == "" do
            IO.puts(:standard_error, "error: empty input")
            System.halt(1)
          end

          Embed.embed(serving, text) |> Jason.encode!() |> IO.puts()

        {:error, reason} ->
          IO.puts(:standard_error, "error: #{path}: #{:file.format_error(reason)}")
          System.halt(1)
      end

    {nil, []} ->
      IO.puts(:standard_error, "Usage: embed <file>  |  embed -  |  ... | embed -n <workers>")
      System.halt(1)

    _ ->
      IO.puts(:standard_error, "Usage: embed <file>  |  embed -  |  ... | embed -n <workers>")
      System.halt(1)
  end
  """

  @embed_wrapper ~S"""
  #!/usr/bin/env bash
  #
  # Wrapper for embed.exs. Handles three concerns the raw elixir launcher
  # can't address on its own:
  #
  # 1. Clean environment via `env -i`. The `elixir` launcher is a #!/bin/sh
  #    script; on macOS /bin/sh is bash 3.2 in POSIX mode, which chokes on
  #    any exported bash 5 functions (BASH_FUNC_*) inherited from the user's
  #    shell. Stripping to a minimal env avoids silent hangs and cryptic
  #    startup errors.
  #
  # 2. CXX workaround for Apple clang 17+. EXLA's NIF build treats
  #    -Wmissing-template-arg-list-after-template-kw as a hard error on
  #    first compile. Suppressing -Werror for that specific flag fixes it.
  #
  # 3. Stderr filter for C++ init noise emitted by XLA/TFRT before absl's
  #    logging is initialized. These lines can't be silenced via Elixir's
  #    :logger config. Real errors still pass through.
  #
  set -euo pipefail

  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

  CXX_FLAG="${CXX:-c++} -Wno-error=missing-template-arg-list-after-template-kw"

  env_args=(
    PATH="$PATH"
    HOME="$HOME"
    CXX="$CXX_FLAG"
    TERM="${TERM:-dumb}"
  )

  exec env -i "${env_args[@]}" elixir "${SCRIPT_DIR}/embed.exs" "$@" \
    2> >(grep -v -E '^WARNING: All log messages before absl::InitializeLog|^I[0-9]{4} [0-9:.]+ +[0-9]+ cpu_client\.cc' >&2)
  """

  @doc """
  Returns the path to the embed.exs script under ~/.fnord/.
  """
  @spec script_path() :: String.t()
  def script_path do
    Path.join(Settings.fnord_home(), @script_filename)
  end

  @doc """
  Returns the path to the embed.sh wrapper script under ~/.fnord/.
  """
  @spec wrapper_path() :: String.t()
  def wrapper_path do
    Path.join(Settings.fnord_home(), @wrapper_filename)
  end

  @doc """
  Ensures the embed.exs script and its shell wrapper exist on disk.
  Writes them if missing or if the on-disk content differs from the
  compiled-in version (i.e. after an upgrade).
  """
  @spec ensure_scripts!() :: :ok
  def ensure_scripts!() do
    ensure_file!(script_path(), @embed_script)
    ensure_file!(wrapper_path(), @embed_wrapper)
    File.chmod!(wrapper_path(), 0o755)
    :ok
  end

  # First write vs. subsequent rewrite is useful context for anyone watching
  # a fresh install or debugging an unexpected reinstall after an upgrade.
  defp ensure_file!(path, content) do
    content = String.trim_leading(content, "\n")

    case File.read(path) do
      {:ok, ^content} ->
        :ok

      {:ok, _other} ->
        File.write!(path, content)
        UI.info("[embeddings] Updated", path)

      {:error, :enoent} ->
        File.write!(path, content)
        UI.info("[embeddings] Installed", path)

      {:error, reason} ->
        File.write!(path, content)
        UI.info("[embeddings] Reinstalled after read error", "#{path} (#{inspect(reason)})")
    end
  end
end
