defmodule Sprout.Pipe do
  @moduledoc false
  use GenServer

  @spec start_link(Path.t()) :: GenServer.on_start()
  def start_link(fifo) do
    GenServer.start_link(__MODULE__, fifo)
  end

  @impl true
  def init(fifo) do
    port =
      Port.open({:spawn_executable, System.find_executable("cat")}, [
        :binary,
        :exit_status,
        args: [fifo]
      ])

    {:ok, %{port: port, buffer: "", suppress: false}}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {lines, rest} = split_lines(state.buffer <> data)

    state = Enum.reduce(lines, state, &handle_line/2)

    {:noreply, %{state | buffer: rest}}
  end

  @impl true
  def handle_info({port, {:exit_status, _}}, %{port: port} = state) do
    {:noreply, state}
  end

  defp split_lines(data) do
    case String.split(data, "\n") do
      [incomplete] -> {[], incomplete}
      parts -> {Enum.slice(parts, 0..-2//1), List.last(parts)}
    end
  end

  defp handle_line("START " <> cmd, state) do
    if Regex.match?(~r/sprout-/, cmd) do
      %{state | suppress: true}
    else
      Sprout.PubSub.broadcast({:cmd_start, cmd})
      state
    end
  end

  defp handle_line("END " <> code, state) do
    unless state.suppress do
      Sprout.PubSub.broadcast({:cmd_end, String.to_integer(String.trim(code))})
    end

    %{state | suppress: false}
  end

  defp handle_line("TURN", state) do
    Sprout.PubSub.broadcast(:turn_started)

    state
  end

  defp handle_line(_line, state), do: state
end