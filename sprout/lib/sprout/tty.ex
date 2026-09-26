defmodule Sprout.TTY do
  @moduledoc """
  Manages interactions with the user-facing teletype.
  """
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec write(iodata(), [{:redraw, boolean()}]) :: :ok
  def write(data, opts \\ []) do
    GenServer.cast(__MODULE__, {:write, data, Keyword.get(opts, :redraw, false)})
  end

  @spec clear() :: :ok
  def clear do
    GenServer.cast(__MODULE__, :clear)
  end

  @spec read() :: {:ok, String.t()} | {:error, :cancelled}
  def read do
    GenServer.call(__MODULE__, :read, :infinity)
  end

  @spec lock() :: :ok
  def lock, do: GenServer.cast(__MODULE__, :lock)

  @spec unlock() :: :ok
  def unlock, do: GenServer.cast(__MODULE__, :unlock)

  @impl true
  def init(_opts) do
    Sprout.Term.enable_raw()

    {:ok, %{port: Port.open({:fd, 0, 1}, [:binary, :eof]), mode: :forward}}
  end

  @impl true
  def handle_cast({:write, data, redraw}, %{port: port} = state) do
    prefix = if redraw, do: "\r#{IO.ANSI.clear_line()}", else: ""
    Port.command(port, normalize_newlines(prefix <> IO.iodata_to_binary(data)))

    {:noreply, state}
  end

  @impl true
  def handle_cast(:clear, %{port: port} = state) do
    Port.command(port, "\r#{IO.ANSI.clear_line()}")

    {:noreply, state}
  end

  @impl true
  def handle_cast(:lock, state), do: {:noreply, %{state | mode: :locked}}

  @impl true
  def handle_cast(:unlock, state), do: {:noreply, %{state | mode: :forward}}

  # The terminal runs in raw mode, so a bare \n doesn't return to column zero
  # like it would in a normal terminal. This function normalizes newlines in
  # a raw bitstring, since PTY passthrough isn't guaranteed to be valid UTF-8.
  defp normalize_newlines(data) do
    data
    |> IO.iodata_to_binary()
    |> :binary.replace("\r\n", "\n", [:global])
    |> :binary.replace("\n", "\r\n", [:global])
  end

  @impl true
  def handle_call(:read, from, state) do
    {:noreply, %{state | mode: {:capture, from, "", state.mode}}}
  end

  @impl true
  def handle_info({port, {:data, <<3>>}}, %{port: port, mode: {:capture, from, _acc, before}} = state) do
    Port.command(port, "^C\r\n")
    Sprout.Client.interrupt(ProcessTree.get(:cid))
    GenServer.reply(from, {:error, :cancelled})

    {:noreply, %{state | mode: before}}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port, mode: {:capture, from, acc, before}} = state) do
    Port.command(port, data)

    case String.split(data, ["\r", "\n"], parts: 2) do
      [chunk] ->
        {:noreply, %{state | mode: {:capture, from, acc <> chunk, before}}}

      [chunk, rest] ->
        GenServer.reply(from, {:ok, acc <> chunk})
        send(self(), {port, {:data, rest}})
        {:noreply, %{state | mode: before}}
    end
  end

  @impl true
  def handle_info({port, {:data, <<3>>}}, %{port: port, mode: :locked} = state) do
    Sprout.PTY.write(<<3>>)
    Sprout.Client.interrupt(ProcessTree.get(:cid))

    {:noreply, %{state | mode: :forward}}
  end

  @impl true
  def handle_info({port, {:data, _data}}, %{port: port, mode: :locked} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port, mode: :forward} = state) do
    Sprout.PTY.write(data)

    {:noreply, state}
  end

  @impl true
  def handle_info({port, :eof}, %{port: port} = state) do
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, _state) do
    Sprout.Term.disable_raw()

    :ok
  end
end