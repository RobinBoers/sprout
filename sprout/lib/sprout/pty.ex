defmodule Sprout.PTY do
  @moduledoc """
  Manages interactions with the process-facing teletype.
  """
  use Parent.GenServer

  @type start_opt :: {:shell, String.t()}

  @spec start_link([start_opt()]) :: GenServer.on_start()
  def start_link(opts) do
    Parent.GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec write(iodata()) :: :ok
  def write(data) do
    GenServer.cast(__MODULE__, {:write, data})
  end

  @spec blind() :: :ok
  def blind, do: GenServer.cast(__MODULE__, {:blind, true})

  @spec unblind() :: :ok
  def unblind, do: GenServer.cast(__MODULE__, {:blind, false})

  @impl true
  def init(opts) do
    bin = Keyword.get(opts, :shell, System.get_env("SHELL", "/bin/bash"))

    shell = Sprout.Shell.initialize(bin)

    Sprout.Env.put("SPROUT_BLIND", "0")
    Sprout.Env.put("SPROUT_INTERACTIVE", "0")
    Sprout.Env.put("SPROUT_SOCK", Sprout.socket_path())

    rows = Sprout.Term.winsize_rows()
    cols = Sprout.Term.winsize_cols()

    {:ok, exec_pid, os_pid} =
      :exec.run([bin, "-i"] ++ shell.argv, [
        :pty,
        :pty_echo,
        :monitor,
        :stdin,
        :stdout,
        :stderr,
        winsz: {rows, cols},
        env: shell.env
      ])

    {:ok, pipe_pid} =
      Parent.start_child({Sprout.Pipe, Sprout.pipe_path()})

    {:ok, relay_pid} =
      Parent.start_child({Sprout.Relay, Sprout.relay_path()})

    {:ok, %{
      exec_pid: exec_pid,
      os_pid: os_pid,
      pipe_pid: pipe_pid,
      relay_pid: relay_pid,
      blind: false
    }}
  end

  @impl true
  def handle_cast({:write, data}, %{os_pid: os_pid} = state) do
    :exec.send(os_pid, data)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:blind, blind}, state) do
    Sprout.Env.put("SPROUT_BLIND", if(blind, do: "1", else: "0"))

    {:noreply, %{state | blind: blind}}
  end

  @impl true
  def handle_info({:stdout, os_pid, data}, %{os_pid: os_pid} = state) do
    Sprout.TTY.write(data)
    unless state.blind, do: Sprout.PubSub.broadcast({:stdout, data})

    {:noreply, state}
  end

  @impl true
  def handle_info({:stderr, os_pid, data}, %{os_pid: os_pid} = state) do
    Sprout.TTY.write(data)
    unless state.blind, do: Sprout.PubSub.broadcast({:stderr, data})

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, os_pid, :process, _pid, reason}, %{os_pid: os_pid} = state) do
    Sprout.Client.stop(reason)

    {:noreply, state}
  end

  @impl true
  def handle_info({:EXIT, _port_or_pid, _reason}, state) do
    # The only EXIT we care about is already handled cleanly by
    # the DOWN-clause above, so any EXIT messages may be safely ignored.

    {:noreply, state}
  end
end