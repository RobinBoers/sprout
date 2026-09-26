defmodule Sprout.Relay do
  @moduledoc false
  use GenServer

  @spec start_link(Path.t()) :: GenServer.on_start()
  def start_link(fifo) do
    GenServer.start_link(__MODULE__, fifo, name: __MODULE__)
  end

  @spec dispatch(iodata()) :: :ok
  def dispatch(cmd) do
    GenServer.cast(__MODULE__, {:write, "RUN #{cmd}\n"})
  end

  @spec done() :: :ok
  def done do
    GenServer.cast(__MODULE__, {:write, "DONE\n"})
  end

  @impl true
  def init(fifo) do
    port = Port.open({:spawn, "cat > #{fifo}"}, [:binary, :exit_status])

    {:ok, port}
  end

  @impl true
  def handle_cast({:write, data}, port) do
    Port.command(port, data)

    {:noreply, port}
  end

  @impl true
  def handle_info({port, {:exit_status, _}}, port) do
    {:noreply, port}
  end
end