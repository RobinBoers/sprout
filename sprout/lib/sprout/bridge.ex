defmodule Sprout.Bridge do
  @moduledoc """
  Bridge that the agent running on the daemon-node can use to interact with the shell environment.
  """
  use GenServer

  @available_tools [:bash, :edit, :read]
  def available_tools, do: @available_tools

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Sprout.PubSub.subscribe()

    {:ok, %{}}
  end

  @impl true
  def handle_info({:tool_call, id, :bash, %{"cmd" => cmd}}, state) do
    Sprout.TTY.write("#{agent_marker()} $ #{cmd}\nApprove? [Y/n] ")

    if Sprout.TTY.read() |> affirmative?() do
      Sprout.Relay.dispatch(cmd)
    else
      Sprout.TTY.write("#{error_marker()} Approval denied.\n")
      Sprout.PubSub.broadcast({:tool_result, id, {:error, "user declined to run this command"}})
    end

    {:noreply, state}
  end

  def handle_info({:tool_call, id, :edit, %{"path" => path, "content" => content}}, state) do
    # TODO(robin): this File.read! in here can still crash unexpectedly. add error handling.
    old_content = opportunistically_read_file!(path)
    {added, removed} = line_diff(old_content, content)

    case File.write(path, content) do
      :ok ->
        Sprout.TTY.write("#{agent_marker()} Wrote #{Path.basename(path)} #{diff_suffix(added, removed)}\n")
        Sprout.PubSub.broadcast({:tool_result, id, :ok})

      {:error, reason} ->
        Sprout.TTY.write("#{error_marker()} Error writing #{Path.basename(path)} +#{added} -#{removed}\n")
        Sprout.PubSub.broadcast({:tool_result, id, {:error, reason}})
    end

    {:noreply, state}
  end

  def handle_info({:tool_call, id, :read, %{"path" => path} = args}, state) do
    case File.read(path) do
      {:ok, content} ->
        Sprout.TTY.write("#{agent_marker()} Read #{Path.basename(path)}#{range_suffix(args)}\n")
        Sprout.PubSub.broadcast({:tool_result, id, {:ok, slice(content, args)}})

      {:error, reason} ->
        Sprout.TTY.write("#{error_marker()} Error reading #{Path.basename(path)}#{range_suffix(args)}\n")
        Sprout.PubSub.broadcast({:tool_result, id, {:error, reason}})
    end

    {:noreply, state}
  end

  def handle_info({:agent_message, text}, state) do
    Sprout.TTY.write("#{agent_username("sprout")} #{text}\n")
    Sprout.Env.put("SPROUT_TURN", "0")
    Sprout.Relay.done()
    Sprout.TTY.unlock()

    {:noreply, state}
  end

  def handle_info({:agent_error, error}, state) do
    Sprout.TTY.write("#{error_marker()} #{error}\n")
    Sprout.Env.put("SPROUT_TURN", "0")
    Sprout.Relay.done()
    Sprout.TTY.unlock()

    {:noreply, state}
  end

  def handle_info({:agent_retry, attempt, max}, state) do
    Sprout.TTY.write("#{error_marker()} retrying (#{attempt}/#{max})...\n")

    {:noreply, state}
  end

  def handle_info({:stdout, _data}, state), do: {:noreply, state}
  def handle_info({:stderr, _data}, state), do: {:noreply, state}
  def handle_info({:cmd_start, _cmd}, state), do: {:noreply, state}
  def handle_info({:cmd_end, _code}, state), do: {:noreply, state}

  def handle_info({:interrupt, _cid}, state), do: {:noreply, state}
  def handle_info({:leave, _cid}, state), do: {:noreply, state}
  def handle_info({:user_message, _message}, state), do: {:noreply, state}
  def handle_info({:tool_result, _id, _result}, state), do: {:noreply, state}

  defp affirmative?(response) do
    response
    |> String.trim()
    |> String.downcase()
    |> then(&(&1 in ["", "y", "yes"]))
  end

  defp opportunistically_read_file!(path) do
    if File.exists?(path) do
      File.read!(path)
    else
      ""
    end
  end

  defp slice(content, %{"start" => start, "end" => stop}) do
    content
    |> String.split("\n")
    |> Enum.slice((start - 1)..(stop - 1))
    |> Enum.join("\n")
  end

  defp slice(content, _args), do: content

  defp line_diff(old_content, new_content) do
    old_lines = String.split(old_content, "\n")
    new_lines = String.split(new_content, "\n")

    List.myers_difference(old_lines, new_lines)
    |> Enum.reduce({0, 0}, fn
      {:ins, lines}, {added, removed} -> {added + length(lines), removed}
      {:del, lines}, {added, removed} -> {added, removed + length(lines)}
      {:eq, _lines}, acc -> acc
    end)
  end

  # Formatting helpers
  # TODO(robin): move these into a separate module, later

  defp agent_marker do
    "#{IO.ANSI.light_black()}••#{IO.ANSI.reset()}"
  end

  defp error_marker do
    "#{IO.ANSI.red()}!!#{IO.ANSI.reset()}"
  end

  defp agent_username(name) do
    "#{IO.ANSI.white()}<#{IO.ANSI.green()}#{name}#{IO.ANSI.white()}>#{IO.ANSI.reset()}"
  end

  defp diff_suffix(added, removed) do
    "#{IO.ANSI.red()}+#{added}#{IO.ANSI.reset()} #{IO.ANSI.green()}-#{removed}#{IO.ANSI.reset()}"
  end

  defp range_suffix(%{"start" => start, "end" => stop}) do
    "#{IO.ANSI.light_black()}:#{start}-#{stop}#{IO.ANSI.reset()}"
  end

  defp range_suffix(_args), do: ""
end