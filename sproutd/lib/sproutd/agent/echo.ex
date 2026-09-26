defmodule Sproutd.Agent.Echo do
  @moduledoc false
  use Sproutd.Agent

  @impl true
  def init(sid), do: {:ok, sid}

  @impl true
  def handle_user_message(sid, message) do
    Sproutd.Agent.emit(sid, {:agent_message, "you said: #{message}"})
    sid
  end

  @impl true
  def handle_tool_result(sid, _id, _result), do: sid

  @impl true
  def handle_shell_output(sid, _cmd, _result), do: sid

  @impl true
  def handle_user_interruption(sid), do: sid

  @impl true
  def usage_report(_sid, init) do
    Map.put(Sprout.empty_usage(), :duration, System.convert_time_unit(System.monotonic_time() - init, :native, :second))
  end
end