defmodule Ask do
  defstruct [
    :ai,
    :opts,
    :agent,
    :buffer
  ]

  def new(opts) do
    set_log_level(opts)

    ai = AI.new()
    agent = AI.Agent.Answers.new(ai, opts)

    %Ask{ai: ai, opts: opts, agent: agent, buffer: ""}
  end

  def run(ask) do
    with {:ok, output} <- AI.Agent.Answers.perform(ask.agent) do
      IO.puts(output)
    end
  end

  defp set_log_level(opts) do
    log_level =
      case opts.log_level do
        "none" ->
          :none

        "debug" ->
          :debug

        "info" ->
          :info

        "warn" ->
          :warn

        "error" ->
          :error

        _ ->
          IO.puts(:stderr, "Invalid log level: #{opts.log_level}")
          System.halt(1)
      end

    Logger.configure(
      level: log_level,
      format: "$time $metadata[$level] $message\n"
    )
  end
end
