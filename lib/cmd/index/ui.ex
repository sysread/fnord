defmodule Cmd.Index.UI do
  def quiet?() do
    Application.get_env(:fnord, :quiet)
  end

  def spin(processing, func) do
    if quiet?() do
      UI.info(processing)
      {_msg, result} = func.()
      result
    else
      Spinner.run(func, processing)
    end
  end

  def progress_bar_start(name, label, total) do
    if !quiet?() do
      Owl.ProgressBar.start(
        id: name,
        label: label,
        total: total,
        timer: true,
        absolute_values: true
      )
    end
  end

  def progress_bar_update(name) do
    if !quiet?() do
      Owl.ProgressBar.inc(id: name)
      Owl.LiveScreen.await_render()
    end
  end

  def start_in_progress_jobs_monitor(queue) do
    if quiet?() do
      Task.async(fn -> :ok end)
    else
      Owl.LiveScreen.add_block(:in_progress, state: "")

      Task.async(fn ->
        in_progress_jobs(queue)
        Owl.LiveScreen.update(:in_progress, "Indexing complete")
        Owl.LiveScreen.await_render()
      end)
    end
  end

  defp in_progress_jobs(queue) do
    unless Queue.is_idle(queue) do
      jobs =
        queue
        |> Queue.in_progress_jobs()
        |> Enum.map(&"- #{&1.rel_path}")
        |> Enum.join("\n")

      box =
        Owl.Box.new(jobs,
          title: "[ In Progress ]",
          border_style: :solid_rounded,
          horizontal_aling: :left,
          padding_x: 1
        )

      Owl.LiveScreen.update(:in_progress, box)

      Process.sleep(250)
      in_progress_jobs(queue)
    end
  end
end
