defmodule Sproutd.Agent.Nu do
  @moduledoc """
  Pluggable agent implementation based on `ReqLLM`. Name inspired by 'pi'.
  """
  use Sproutd.Agent

  require Logger

  import ReqLLM.Context

  @max_steps 100
  @max_retries 3

  def model do
    "openai_codex:#{System.get_env("SPROUT_MODEL", "gpt-5.6-sol")}"
  end

  def system_prompt do
    "You are sprout, an agent in the user's terminal. You read along, and when asked, you can run commands, directly in the user's terminal. You share this terminal together. You can see the user's commands + output, the user can see yours. Prefer using dedicated tools (find tool, read tool, list tool, search tool) over shell commands when possible. Try to keep the commands you do use understandable for the user, and be mindful not to flood the terminal with output."
  end

  @impl true
  def init(sid) do
    {:ok, %{
      sid: sid,
      context: ReqLLM.Context.new([system(system_prompt())]),
      usage: Sprout.empty_usage(),
      pending: %{},
      steps: 0,
      task: nil
    }}
  end

  @impl true
  def handle_user_message(state, message) do
    context = ReqLLM.Context.append(state.context, user(message))
    generate_response(%{state | context: context, steps: 0})
  end

  @impl true
  def handle_tool_result(state, id, {:error, :rejected}) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        state

      {:edit, _pending} ->
        Logger.info("edit rejected by user, ending turn", sid: state.sid)
        Sproutd.Agent.emit(state.sid, {:agent_error, "Rejected."})

        if state.task do
          Task.shutdown(state.task, :brutal_kill)
        end

        # Mark all pending tools (including this one) cancelled
        context =
          Enum.reduce(state.pending, state.context, fn {id, tool}, context ->
            ReqLLM.Context.append(
              context,
              tool_result(id, Atom.to_string(tool), format_tool_result({:error, "turn ended by user"}))
            )
          end)

        %{state | task: nil, pending: %{}, context: context}
    end
  end

  @impl true
  def handle_tool_result(state, id, result) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        state

      {tool, pending} ->
        context =
          ReqLLM.Context.append(
            state.context,
            tool_result(id, Atom.to_string(tool), format_tool_result(result))
          )

        state = %{state | context: context, pending: pending}

        if map_size(pending) == 0 do
          generate_response(state)
        else
          state
        end
    end
  end

  defp format_tool_result({:ok, :accepted}), do: "accepted"
  defp format_tool_result({:ok, :edited, _content}), do: "edited"
  defp format_tool_result({:ok, content}), do: content
  defp format_tool_result(:ok), do: "ok"
  defp format_tool_result({:error, reason}), do: "error: #{inspect(reason)}"
  defp format_tool_result(%{output: _, exit_code: _} = result), do: format_shell_output(result)

  defp format_shell_output(%{output: output, exit_code: code}), do: "exit #{code}\n#{output}"

  @impl true
  def handle_shell_output(state, cmd, result) do
    context = ReqLLM.Context.append(state.context, user("$ #{cmd}\n#{format_shell_output(result)}"))

    %{state | context: context}
  end

  defp generate_response(state) do
    if state.steps >= @max_steps do
      Logger.warning("loop detection: stopped after #{@max_steps} steps", sid: state.sid)

      Sproutd.Agent.emit(
        state.sid,
        {:agent_error, "stopped after #{@max_steps} steps without answer (loop detection)"}
      )

      state
    else
      state = %{state | steps: state.steps + 1}
      Logger.info("requesting completion (step #{state.steps}/#{@max_steps})", sid: state.sid)

      %{state | task: Task.async(fn -> generate_with_retry(state) end)}
    end
  end

  @impl true
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | task: nil}

    case result do
      {:ok, response} ->
        {:noreply, state
         |> accumulate_usage(response)
         |> handle_response(response)}

      {:error, reason} ->
        Logger.error("generation failed: #{inspect(reason)}", sid: state.sid)
        Sproutd.Agent.emit(state.sid, {:agent_error, inspect(reason)})

        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.error("generation task crashed: #{inspect(reason)}", sid: state.sid)
    Sproutd.Agent.emit(state.sid, {:agent_error, "Internal error: #{inspect(reason)}"})

    {:noreply, %{state | task: nil}}
  end

  @impl true
  def handle_user_interruption(state) do
    Logger.error("generation interrupted by user", sid: state.sid)
    Sproutd.Agent.emit(state.sid, {:agent_error, "Interrupted."})

    if state.task do
      Task.shutdown(state.task, :brutal_kill)
    end

    # Cancelling the turn also cancels all pending tool calls.
    context =
      Enum.reduce(state.pending, state.context, fn {id, tool}, context ->
        ReqLLM.Context.append(
          context,
          tool_result(id, Atom.to_string(tool), format_tool_result({:error, "interrupted by user"}))
        )
      end)

    %{state | task: nil, pending: %{}, context: context}
  end

  defp generate_with_retry(state, attempt \\ 1) do
    case run_stream(state) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason, false} when attempt < @max_retries ->
        Logger.warning(
          "generation attempt #{attempt}/#{@max_retries} failed, retrying: #{inspect(reason)}",
          sid: state.sid
        )

        Sproutd.Agent.emit(state.sid, {:agent_retry, attempt, @max_retries})
        Process.sleep(500 * attempt)
        generate_with_retry(state, attempt + 1)

      {:error, reason, true} ->
        {:error, reason}
    end
  end

  defp run_stream(state) do
    Sproutd.Agent.emit(state.sid, {:agent_progress, :connecting})

    case ReqLLM.stream_text(model(), state.context, tools: tools()) do
      {:ok, stream_response} -> consume_stream(state.sid, stream_response)
      {:error, reason} -> {:error, reason, false}
    end
  end

  defp consume_stream(sid, stream_response) do
    stream_response
    |> ReqLLM.StreamResponse.events()
    |> Enum.reduce_while(%{phase: :connecting, text: [], tool_calls: []}, &handle_stream_event(sid, &1, &2))
    |> case do
      {:finish, acc} ->
        {:ok,
         %{
           text: acc.text |> Enum.reverse() |> IO.iodata_to_binary(),
           tool_calls: Enum.reverse(acc.tool_calls),
           usage: ReqLLM.StreamResponse.usage(stream_response)
         }}

      {:error, reason, partial?} ->
        {:error, reason, partial?}
    end
  end

  defp handle_stream_event(sid, %ReqLLM.StreamEvent{type: :start}, acc) do
    # :start means connection was established. Some providers do not
    # stream reasoning/thinking indicators after this, so assume thinking
    # has started, at least until an indicator arrives.

    {:cont, maybe_emit_phase(sid, acc, :thinking)}
  end

  defp handle_stream_event(sid, %ReqLLM.StreamEvent{type: :reasoning_delta}, acc) do
    {:cont, maybe_emit_phase(sid, acc, :thinking)}
  end

  defp handle_stream_event(sid, %ReqLLM.StreamEvent{type: :text_delta, data: text}, acc) do
    acc = maybe_emit_phase(sid, acc, :generating)
    Sproutd.Agent.emit(sid, {:agent_delta, text})
    {:cont, %{acc | text: [text | acc.text]}}
  end

  defp handle_stream_event(_sid, %ReqLLM.StreamEvent{type: :tool_call, data: call}, acc) do
    {:cont, %{acc | tool_calls: [call | acc.tool_calls]}}
  end

  defp handle_stream_event(_sid, %ReqLLM.StreamEvent{type: :finish}, acc) do
    {:halt, {:finish, acc}}
  end

  defp handle_stream_event(_sid, %ReqLLM.StreamEvent{type: :cancelled}, acc) do
    {:halt, {:error, :cancelled, acc.phase != :connecting}}
  end

  defp handle_stream_event(_sid, %ReqLLM.StreamEvent{type: :error, data: reason}, acc) do
    {:halt, {:error, reason, acc.phase != :connecting}}
  end

  defp handle_stream_event(_sid, %ReqLLM.StreamEvent{}, acc), do: {:cont, acc}

  defp maybe_emit_phase(_sid, %{phase: phase} = acc, phase), do: acc

  defp maybe_emit_phase(sid, acc, phase) do
    Sproutd.Agent.emit(sid, {:agent_progress, phase})
    %{acc | phase: phase}
  end

  defp handle_response(state, %{text: text, tool_calls: []} = _result) do
    context = ReqLLM.Context.append(state.context, assistant(text))
    Sproutd.Agent.emit(state.sid, {:agent_message, text})
    %{state | context: context}
  end

  defp handle_response(state, %{text: text, tool_calls: calls}) do
    tool_calls = Enum.map(calls, &{&1.name, &1.arguments, id: &1.id})
    context = ReqLLM.Context.append(state.context, assistant(text, tool_calls: tool_calls))
    state = %{state | context: context}

    {known, unknown} =
      calls
      |> Enum.map(&{&1, resolve_tool(&1.name)})
      |> Enum.split_with(fn {_call, tool} -> tool end)

    state =
      Enum.reduce(unknown, state, fn {call, nil}, state ->
        Logger.warning("agent requested unknown tool #{inspect(call.name)}", sid: state.sid)
        message = "unknown tool #{inspect(call.name)}"
        context = ReqLLM.Context.append(state.context, tool_result(call.id, call.name, message))
        %{state | context: context}
      end)

    pending = Map.new(known, fn {call, tool} -> {call.id, tool} end)
    state = %{state | pending: Map.merge(state.pending, pending)}

    Enum.each(known, fn {call, tool} ->
      args = call.arguments || %{}
      Logger.info("dispatching #{tool} tool call #{call.id}: #{inspect(args)}", sid: state.sid)
      Sproutd.Agent.emit(state.sid, {:tool_call, call.id, tool, args})
    end)

    if map_size(state.pending) == 0 do
      generate_response(state)
    else
      state
    end
  end

  defp accumulate_usage(state, usage) do
    delta = %{
      input_tokens: usage[:input_tokens] || 0,
      output_tokens: usage[:output_tokens] || 0,
      total_tokens: usage[:total_tokens] || 0,
      # Cost is reported in dollars, be we use cents, so round
      # once here instead of accumulating the float error over turns.
      cost: round((usage[:total_cost] || 0.0) * 100)
    }

    Map.update!(state, :usage, &Map.merge(&1, delta, fn _key, a, b -> a + b end))
  end

  @impl true
  def usage_report(state, init) do
    Map.put(state.usage, :duration, System.convert_time_unit(System.monotonic_time() - init, :native, :second))
  end

  defp resolve_tool(name) do
    Enum.find(Sprout.Bridge.available_tools(), &(Atom.to_string(&1) == name))
  end

  defp tools do
    [
      ReqLLM.tool(
        name: "bash",
        description: "Run a shell command in the user's terminal",
        parameter_schema: [
          cmd: [type: :string, required: true, doc: "The command to run"]
        ],
        callback: {__MODULE__, :unused_callback, []}
      ),
      ReqLLM.tool(
        name: "read",
        description: "Read a file, optionally a specific line range",
        parameter_schema: [
          path: [type: :string, required: true, doc: "File path"],
          start: [type: :integer, required: false, doc: "Start line (1-indexed)"],
          end: [type: :integer, required: false, doc: "End line (inclusive)"]
        ],
        callback: {__MODULE__, :unused_callback, []}
      ),
      ReqLLM.tool(
        name: "edit",
        description: "Write full new content to a file",
        parameter_schema: [
          path: [type: :string, required: true, doc: "File path"],
          content: [type: :string, required: true, doc: "New file content"]
        ],
        callback: {__MODULE__, :unused_callback, []}
      ),
      ReqLLM.tool(
        name: "list",
        description: "List directory contents",
        parameter_schema: [
          path: [type: :string, required: false, doc: "Directory to list (default: cwd)"]
        ],
        callback: {__MODULE__, :unused_callback, []}
      ),
      ReqLLM.tool(
        name: "find",
        description: "Find files by glob pattern",
        parameter_schema: [
          pattern: [type: :string, required: true, doc: "Glob pattern (e.g. \"**/*.ex\")"],
          path: [type: :string, required: false, doc: "Directory to search from (default: cwd)"]
        ],
        callback: {__MODULE__, :unused_callback, []}
      ),
      ReqLLM.tool(
        name: "search",
        description: "Search file contents for a regular expression",
        parameter_schema: [
          pattern: [type: :string, required: true, doc: "Regular expression to search for"],
          path: [type: :string, required: false, doc: "Directory to search from (default: cwd)"],
          glob: [type: :string, required: false, doc: "Glob pattern to filter files (default: \"**/*\")"]
        ],
        callback: {__MODULE__, :unused_callback, []}
      )
    ]
  end

  @doc false
  def unused_callback(_args) do
    raise "unreachable: Sproutd.Agent.ReqLLM dispatches tools manually"
  end
end
