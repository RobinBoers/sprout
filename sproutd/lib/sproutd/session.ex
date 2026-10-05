defmodule Sproutd.Session do
  @moduledoc false
  use Parent.GenServer, restart: :transient

  require Logger

  def agent do
    case System.get_env("SPROUT_AGENT", "nu") do
      "nu" -> Sproutd.Agent.Nu
      "echo" -> Sproutd.Agent.Echo
      other -> raise "unknown agent '#{other}'"
    end
  end

  @spec start_link({Sprout.sid(), Sprout.cid()}) :: GenServer.on_start()
  def start_link({sid, cid}) do
    Parent.GenServer.start_link(__MODULE__, {sid, cid}, name: via(sid))
  end

  @impl true
  def init({sid, cid}) do
    {:ok, _pid} = Parent.start_child({agent(), sid}, [
        id: {__MODULE__, sid},
        restart: :temporary,
        ephemeral?: true
      ])

    state = %{
      init: System.monotonic_time(),
      sid: sid,
      cids: MapSet.new(),
      queue: [],
      current: nil,
      buffer: []
    }

    {:ok, handle_join(state, cid)}
  end

  defp handle_join(state, cid) do
    Sprout.PubSub.subscribe(cid)
    Logger.info("client #{cid} joined session #{state.sid}", cid: cid)

    %{state | cids: MapSet.put(state.cids, cid)}
  end

  defp handle_leave(state, cid) do
    Sprout.PubSub.unsubscribe(cid)
    Logger.info("client #{cid} left session #{state.sid}", cid: cid)

    %{state | cids: MapSet.delete(state.cids, cid)}
  end

  @impl true
  def handle_cast({:attach, cid}, state) do
    {:noreply, handle_join(state, cid)}
  end

  @impl true
  def handle_call({:leave, cid}, _from, state) do
    stats = GenServer.call(Sproutd.Agent.via(state.sid), {:usage_report, state.init})

    if MapSet.size(state.cids) == 1 do
      {:stop, :normal, stats, handle_leave(state, cid)}
    else
      {:reply, stats, handle_leave(state, cid)}
    end
  end

  @impl true
  def handle_info({:leave, cid}, state) do
    if MapSet.size(state.cids) == 1 do
      {:stop, :normal, handle_leave(state, cid)}
    else
      {:noreply, handle_leave(state, cid)}
    end
  end

  @impl true
  def handle_info({:user_message, message}, state) do
    Logger.info("user message: #{inspect(message)}", sid: state.sid)
    GenServer.cast(Sproutd.Agent.via(state.sid), {:user_message, message})

    {:noreply, state}
  end

  @impl true
  def handle_info({:tool_result, id, result}, state) do
    Logger.info("tool result #{id}: #{inspect(result)}", sid: state.sid)
    GenServer.cast(Sproutd.Agent.via(state.sid), {:tool_result, id, result})

    {:noreply, %{state | queue: List.delete(state.queue, id)}}
  end

  @impl true
  def handle_info({:agent_event, {:tool_call, id, :bash, args} = event}, state) do
    Logger.info("agent dispatching bash tool call #{id}: #{inspect(args)}", sid: state.sid)
    Enum.each(state.cids, &Sprout.PubSub.broadcast(event, &1))

    {:noreply, %{state | queue: state.queue ++ [id]}}
  end

  @impl true
  def handle_info({:agent_event, event}, state) do
    Enum.each(state.cids, &Sprout.PubSub.broadcast(event, &1))

    {:noreply, state}
  end

  @impl true
  def handle_info({:cmd_start, cmd}, state) do
    case state.queue do
      [id | rest] -> {:noreply, %{state | current: {:tool, id}, queue: rest, buffer: []}}
      [] -> {:noreply, %{state | current: {:shell, cmd}, buffer: []}}
    end
  end

  @impl true
  def handle_info({:stdout, data}, state), do: {:noreply, append(state, data)}
  def handle_info({:stderr, data}, state), do: {:noreply, append(state, data)}

  @impl true
  def handle_info({:cmd_end, code}, state) do
    output = IO.iodata_to_binary(state.buffer)

    case state.current do
      {:tool, id} ->
        Logger.info("tool call #{id} finished: exit #{code}", sid: state.sid)
        GenServer.cast(Sproutd.Agent.via(state.sid), {:tool_result, id, %{output: output, exit_code: code}})

      {:shell, cmd} ->
        Logger.info("shell command finished: #{inspect(cmd)} exit #{code}", sid: state.sid)
        GenServer.cast(Sproutd.Agent.via(state.sid), {:shell_output, cmd, %{output: output, exit_code: code}})

      nil ->
        :ok
    end

    {:noreply, %{state | current: nil, buffer: []}}
  end

  @impl true
  def handle_info({:agent_message, message}, state) do
    Logger.info("agent message: #{inspect(message)}", sid: state.sid)

    {:noreply, state}
  end

  @impl true
  def handle_info({:agent_error, error}, state) do
    Logger.error("agent error: #{inspect(error)}", sid: state.sid)

    {:noreply, state}
  end

  @impl true
  def handle_info({:agent_retry, attempt, max}, state) do
    Logger.warning("agent retrying (#{attempt}/#{max})", sid: state.sid)

    {:noreply, state}
  end

  @impl true
  def handle_info(:turn_started, state), do: {:noreply, state}
  def handle_info({:agent_progress, _phase}, state), do: {:noreply, state}
  def handle_info({:agent_delta, _text}, state), do: {:noreply, state}
  def handle_info({:tool_call, _id, _tool, _args}, state), do: {:noreply, state}

  @impl true
  def handle_info({:interrupt, _cid}, state) do
    Logger.warning("turn interrupted by user", sid: state.sid)
    GenServer.cast(Sproutd.Agent.via(state.sid), :interrupt)

    {:noreply, %{state | queue: [], current: nil, buffer: []}}
  end

  @impl true
  def handle_stopped_children(info, state) do
    %{reason: reason} = info |> Map.values() |> List.first()
    Logger.error("agent crashed: #{inspect(reason)}", sid: state.sid)

    Enum.each(state.cids, &Sprout.PubSub.broadcast({:agent_error, "Agent crashed (session ending)"}, &1))

    {:stop, :shutdown, state}
  end

  defp append(%{current: nil} = state, _data), do: state
  defp append(state, data), do: %{state | buffer: [state.buffer, data]}

  @spec via(Sprout.sid()) :: GenServer.name()
  def via(sid), do: {:via, Registry, {Sproutd.Registry, "session:#{sid}"}}
end