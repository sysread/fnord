Mix.install([
  {:owl, "~> 0.12"}
])

defmodule Thing do
  alias Owl

  @messages [
    {:user, "Hello, world!"},
    {:computer, "Hello, user!"},
    {:user, "How are you?"},
    {:computer, "I am well, thank you."}
  ]

  def main() do
    for {from, content} <- @messages do
      id = new_id()

      color =
        case from do
          :user -> :green
          :computer -> :cyan
        end

      title =
        case from do
          :user -> " User "
          :computer -> " Computer "
        end
        |> Owl.Data.tag([color, :bright])

      box =
        Owl.Box.new(content,
          title: title,
          border_style: :solid_rounded,
          border_tag: color,
          padding: 1,
          min_height: 1,
          min_width: 140,
          max_width: 140,
          horizontal_align: :left,
          vertical_align: :top
        )

      Owl.LiveScreen.add_block(id, state: box)
    end

    Owl.LiveScreen.await_render()
  end

  defp new_id() do
    :crypto.strong_rand_bytes(8) |> Base.encode16()
  end
end

Thing.main()
