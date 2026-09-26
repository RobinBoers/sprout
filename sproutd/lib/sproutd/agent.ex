defmodule Sproutd.Agent do
  @moduledoc false

  @type state :: term()
  @type event ::
          {:agent_message, String.t()}
          | {:agent_error, String.t()}
          | {:agent_retry, pos_integer(), pos_integer()}
          | {:tool_call, String.t(), atom(), map()}

  # TODO(robin): this is just a more-specific signature for GenServer,
  # but results in a compile-warning rn. how am i gonna fix this.
  # @callback init(Sprout.sid()) :: {:ok, state()}

  @callback handle_user_message(state(), String.t()) :: state()
  @callback handle_tool_result(state(), String.t(), term()) :: state()
  @callback handle_shell_output(state(), String.t(), term()) :: state()
  @callback handle_user_interruption(state()) :: state()

  @callback usage_report(state(), integer()) :: Sprout.usage()

  @spec emit(Sprout.sid(), event()) :: :ok
  def emit(sid, event) do
    if pid = GenServer.whereis(Sproutd.Session.via(sid)) do
      send(pid, {:agent_event, event})
    end

    :ok
  end

  defmacro __using__(_opts) do
    quote do
      use GenServer
      @behaviour Sproutd.Agent

      @spec start_link(Sprout.sid()) :: GenServer.on_start()
      def start_link(sid) do
        GenServer.start_link(__MODULE__, sid, name: Sproutd.Agent.via(sid))
      end

      @impl GenServer
      def handle_cast({:user_message, message}, state) do
        {:noreply, handle_user_message(state, message)}
      end

      @impl GenServer
      def handle_cast({:tool_result, id, result}, state) do
        {:noreply, handle_tool_result(state, id, result)}
      end

      @impl GenServer
      def handle_cast({:shell_output, cmd, result}, state) do
        {:noreply, handle_shell_output(state, cmd, result)}
      end

      @impl GenServer
      def handle_cast(:interrupt, state) do
        {:noreply, handle_user_interruption(state)}
      end

      @impl GenServer
      def handle_call({:usage_report, init}, _from, state) do
        {:reply, usage_report(state, init), state}
      end
    end
  end

  @spec via(Sprout.sid()) :: GenServer.name()
  def via(sid), do: {:via, Registry, {Sproutd.Registry, "agent:#{sid}"}}
end