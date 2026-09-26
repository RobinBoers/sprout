defmodule Sprout.Client do
  @moduledoc false
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec join() :: {:ok, Sprout.sid()} | {:error, term()}
  def join do
    GenServer.call(__MODULE__, :join)
  end

  @spec attach(Sprout.sid()) :: :ok | {:error, term()}
  def attach(sid) do
    GenServer.call(__MODULE__, {:attach, sid})
  end

  @spec leave() :: {:ok, map()} | {:error, :not_attached}
  def leave do
    GenServer.call(__MODULE__, :leave)
  end

  @spec chat(String.t()) :: :ok | {:error, :not_attached}
  def chat(message) do
    GenServer.call(__MODULE__, {:chat, message})
  end

  @spec interrupt(Sprout.cid()) :: :ok
  def interrupt(cid) do
    GenServer.cast(__MODULE__, {:interrupt, cid})
  end

  @spec stop(term()) :: :ok
  def stop(reason) do
    GenServer.cast(__MODULE__, {:stop, reason})
  end

  @impl true
  def init(_opts) do
    {:ok, sync(%{sids: MapSet.new()})}
  end

  @impl true
  def handle_call(:join, _from, state) do
    case Sprout.Daemon.create(ProcessTree.get(:cid)) do
      {:ok, sid} ->
        {:reply, {:ok, sid}, sync(%{state | sids: MapSet.put(state.sids, sid)})}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:attach, sid}, _from, state) do
    case Sprout.Daemon.attach(sid, ProcessTree.get(:cid)) do
      :ok ->
        {:reply, :ok, sync(%{state | sids: MapSet.put(state.sids, sid)})}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:leave, _from, state) do
    if MapSet.size(state.sids) == 0 do
      {:reply, {:error, :not_attached}, state}
    else
      usage =
        for sid <- state.sids, reduce: Sprout.empty_usage() do
          acc ->
            case Sprout.Daemon.leave(sid, ProcessTree.get(:cid)) do
              {:ok, usage} -> sum_usage(acc, usage)
              {:error, _} -> acc
            end
        end

      {:reply, {:ok, usage}, sync(%{state | sids: MapSet.new()})}
    end
  end

  @impl true
  def handle_call({:chat, message}, _from, state) do
    if MapSet.size(state.sids) == 0 do
      {:reply, {:error, :not_attached}, state}
    else
      Sprout.Env.put("SPROUT_TURN", "1")
      Sprout.PubSub.broadcast({:user_message, message})
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_cast({:interrupt, cid}, state) do
    unless MapSet.size(state.sids) == 0 do
      Sprout.PubSub.broadcast({:interrupt, cid})
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:stop, _reason}, state) do
    Sprout.PubSub.broadcast({:leave, ProcessTree.get(:cid)})

    # TODO(robin): print a 'byeee!!' message here too

    File.rm_rf!(Sprout.client_dir())
    System.stop(0)

    {:noreply, state}
  end

  defp sync(state) do
    Sprout.Env.put("SPROUT_SID", Enum.join(state.sids, ","))

    state
  end

  defp sum_usage(acc, usage) do
    %{
      input_tokens: acc.input_tokens + usage.input_tokens,
      output_tokens: acc.output_tokens + usage.output_tokens,
      total_tokens: acc.total_tokens + usage.total_tokens,
      cost: acc.cost + usage.cost,
      duration: max(acc.duration, usage.duration)
    }
  end
end