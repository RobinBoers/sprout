defmodule Sprout.Bridge do
  @moduledoc """
  Bridge that the agent running on the daemon-node can use to interact with the shell environment.
  """
  use GenServer

  @available_tools ~w(bash edit read list find search)a
  def available_tools, do: @available_tools

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Sprout.PubSub.subscribe()

    {:ok, %{mode: :idle, spinner: nil, pending_phase: nil}}
  end

  @impl true
  def handle_info(:turn_started, %{mode: :idle} = state) do
    state = %{state | mode: :waiting}

    if phase = state.pending_phase do
      {:noreply, ensure_spinner(%{state | pending_phase: nil}, phase)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:agent_progress, phase}, %{mode: :waiting} = state) do
    {:noreply, ensure_spinner(state, phase)}
  end

  def handle_info({:agent_progress, phase}, %{mode: :idle} = state) do
    {:noreply, %{state | pending_phase: phase}}
  end

  def handle_info({:agent_progress, _phase}, state) do
    {:noreply, state}
  end

  @spinner_interval 1000
  @spinner_frames ~w(∙∙∙ ●∙∙ ∙●∙ ∙∙● ∙∙∙)

  def handle_info({:spinner_tick, ref, frame}, %{spinner: %{ref: ref} = spinner} = state) do
    render_spinner(spinner.phase, frame, spinner.started_at)
    Process.send_after(self(), {:spinner_tick, ref, frame + 1}, @spinner_interval)

    {:noreply, %{state | spinner: %{spinner | frame: frame}}}
  end

  def handle_info({:spinner_tick, _, _}, state) do
    {:noreply, state}
  end

  def handle_info({:tool_call, id, :bash, %{"cmd" => cmd}}, state) do
    state = close_output(state)

    Sprout.TTY.write("#{agent_marker()} $ #{cmd}\nApprove? [Y/n] ")

    with {:ok, response} <- Sprout.TTY.read() do
      if affirmative?(response) do
        Sprout.Relay.dispatch(cmd)
      else
        Sprout.TTY.write("#{error_marker()} Approval denied.\n")
        Sprout.PubSub.broadcast({:tool_result, id, {:error, "user declined to run this command"}})
      end
    end

    {:noreply, state}
  end

  def handle_info({:tool_call, id, :edit, %{"path" => path, "content" => content}}, state) do
    state = close_output(state)

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
    state = close_output(state)

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

  def handle_info({:tool_call, id, :list, args}, state) do
    state = close_output(state)
    path = Map.get(args, "path", ".")

    case File.ls(path) do
      {:ok, entries} ->
        listing =
          entries
          |> Enum.sort()
          |> Enum.map(&annotate_entry(path, &1))
          |> Enum.join("\n")

        Sprout.TTY.write("#{agent_marker()} List #{path}\n")
        Sprout.PubSub.broadcast({:tool_result, id, {:ok, listing}})

      {:error, reason} ->
        Sprout.TTY.write("#{error_marker()} Error listing #{path}\n")
        Sprout.PubSub.broadcast({:tool_result, id, {:error, reason}})
    end

    {:noreply, state}
  end

  def handle_info({:tool_call, id, :find, %{"pattern" => pattern} = args}, state) do
    state = close_output(state)
    path = Map.get(args, "path", ".")

    matches =
      path
      |> Path.join(pattern)
      |> Path.wildcard(match_dot: true)
      |> Enum.sort()

    Sprout.TTY.write("#{agent_marker()} Find #{pattern}#{path_suffix(path)}\n")
    Sprout.PubSub.broadcast({:tool_result, id, {:ok, Enum.join(matches, "\n")}})

    {:noreply, state}
  end

  def handle_info({:tool_call, id, :search, %{"pattern" => pattern} = args}, state) do
    state = close_output(state)
    path = Map.get(args, "path", ".")
    glob = Map.get(args, "glob", "**/*")

    case Regex.compile(pattern) do
      {:ok, regex} ->
        matches =
          path
          |> Path.join(glob)
          |> Path.wildcard(match_dot: true)
          |> Enum.filter(&File.regular?/1)
          |> Enum.flat_map(&grep_file(&1, regex))

        Sprout.TTY.write("#{agent_marker()} Search #{pattern}#{path_suffix(path)}\n")
        Sprout.PubSub.broadcast({:tool_result, id, {:ok, Enum.join(matches, "\n")}})

      {:error, {reason, _pos}} ->
        Sprout.TTY.write("#{error_marker()} Malformed pattern #{inspect(pattern)}\n")
        Sprout.PubSub.broadcast({:tool_result, id, {:error, reason}})
    end

    {:noreply, state}
  end

  def handle_info({:agent_delta, text}, %{mode: :waiting} = state) do
    state = stop_spinner(state)

    Sprout.TTY.write("#{agent_username("sprout")} #{text}")

    {:noreply, %{state | mode: :streaming}}
  end

  def handle_info({:agent_delta, text}, %{mode: :streaming} = state) do
    Sprout.TTY.write(text)

    {:noreply, state}
  end

  def handle_info({:agent_message, text}, %{mode: mode} = state) do
    state = close_output(state)

    if mode != :streaming do
      Sprout.TTY.write("#{agent_username("sprout")} #{text}\n")
    end

    Sprout.Env.put("SPROUT_TURN", "0")
    Sprout.Relay.done()
    Sprout.TTY.unlock()

    {:noreply, %{state | mode: :idle, pending_phase: nil}}
  end

  def handle_info({:agent_error, error}, state) do
    state = close_output(state)

    Sprout.TTY.write("#{error_marker()} #{error}\n")

    Sprout.Env.put("SPROUT_TURN", "0")
    Sprout.Relay.done()
    Sprout.TTY.unlock()

    {:noreply, %{state | mode: :idle, pending_phase: nil}}
  end

  def handle_info({:agent_retry, attempt, max}, state) do
    state = close_output(state)

    Sprout.TTY.write("#{error_marker()} retrying (#{attempt}/#{max})...\n")

    {:noreply, state}
  end

  def handle_info({:stdout, _data}, state), do: {:noreply, state}
  def handle_info({:stderr, _data}, state), do: {:noreply, state}
  def handle_info({:cmd_start, _cmd}, state), do: {:noreply, state}
  def handle_info({:cmd_end, _code}, state), do: {:noreply, state}

  def handle_info({:user_message, _message}, state), do: {:noreply, state}
  def handle_info({:interrupt, _cid}, state), do: {:noreply, state}
  def handle_info({:leave, _cid}, state), do: {:noreply, state}
  def handle_info({:tool_result, _id, _result}, state), do: {:noreply, state}

  # Spinner and typewriter

  defp ensure_spinner(%{spinner: nil} = state, phase) do
    spinner = %{
      ref: make_ref(),
      phase: phase,
      started_at: System.monotonic_time(),
      frame: 0
    }

    # Render immediately to prevent racing fast replies.
    render_spinner(spinner.phase, spinner.frame, spinner.started_at)
    Process.send_after(self(), {:spinner_tick, spinner.ref, 1}, @spinner_interval)

    %{state | spinner: spinner}
  end

  defp ensure_spinner(%{spinner: %{phase: phase}} = state, phase) do
    state
  end

  defp ensure_spinner(%{spinner: spinner} = state, phase) do
    spinner = %{spinner | phase: phase}

    # Render immediately to prevent racing fast replies.
    render_spinner(spinner.phase, spinner.frame, spinner.started_at)

    %{state | spinner: spinner}
  end

  defp render_spinner(phase, frame, started_at) do
    Sprout.TTY.write(spinner_animation(phase, frame, started_at), redraw: true)
  end

  defp stop_spinner(%{spinner: nil} = state) do
    state
  end

  defp stop_spinner(state) do
    Sprout.TTY.clear()
    %{state | spinner: nil}
  end

  defp close_output(state) do
    # Clears the active spinner, and if we start streaming, end the line with
    # a newline, so the spinner or typewriter always starts on a fresh line.

    state = stop_spinner(state)

    if state.mode == :streaming do
      Sprout.TTY.write("\n")
    end

    %{state | mode: :waiting}
  end

  # File helpers

  defp opportunistically_read_file!(path) do
    if File.exists?(path) do
      File.read!(path)
    else
      ""
    end
  end

  defp annotate_entry(path, entry) do
    if File.dir?(Path.join(path, entry)), do: entry <> "/", else: entry
  end

  defp grep_file(path, regex) do
    path
    |> File.stream!()
    |> Stream.with_index(1)
    |> Stream.filter(fn {line, _n} -> Regex.match?(regex, line) end)
    |> Enum.map(fn {line, n} -> "#{path}:#{n}: #{String.trim_trailing(line)}" end)
  rescue
    File.Error -> []
  end

  # String helpers

  defp affirmative?(response) do
    response
    |> String.trim()
    |> String.downcase()
    |> then(&(&1 in ["", "y", "yes"]))
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

  defp path_suffix("."), do: ""
  defp path_suffix(path), do: " #{IO.ANSI.light_black()}in #{path}#{IO.ANSI.reset()}"

  defp spinner_animation(phase, frame, started_at) do
    elapsed_ms = System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)
    glyph = Enum.at(@spinner_frames, rem(frame, length(@spinner_frames)))
    seconds = :erlang.float_to_binary(elapsed_ms / 1000, decimals: 1)

    "\r#{IO.ANSI.clear_line()}#{IO.ANSI.light_black()}#{glyph} #{phase_label(phase)}… #{seconds}s#{IO.ANSI.reset()}"
  end

  defp phase_label(:connecting), do: "Connecting"
  defp phase_label(:thinking), do: "Thinking"
  defp phase_label(:generating), do: "Generating"
end