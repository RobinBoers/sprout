defmodule Sproutd.Agent.Nu do
  @moduledoc """
  Pluggable agent implementation based on `ReqLLM`. Name inspired by 'pi'.
  """
  use Sproutd.Agent

  require Logger

  import ReqLLM.Context

  @max_steps 20
  @max_retries 3

  def model do
    "openai_codex:#{System.get_env("SPROUT_MODEL", "gpt-5.6-sol")}"
  end

  def system_prompt do
    "You are sprout, an agent in the user's terminal."
  end

  @usage_keys ~w(input_tokens output_tokens total_tokens cost)a

  @impl true
  def init(sid) do
    {:ok, %{
      sid: sid,
      context: ReqLLM.Context.new([system(system_prompt())]),
      usage: Map.new(@usage_keys, &{&1, 0}),
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
    Sproutd.Agent.emit(state.sid, {:agent_error, "internal error: #{inspect(reason)}"})

    {:noreply, %{state | task: nil}}
  end

  @impl true
  def handle_user_interruption(state) do
    Sproutd.Agent.emit(state.sid, {:agent_error, "cancelled by user"})

    if state.task do
      Task.shutdown(state.task, :brutal_kill)
    end

    %{state | task: nil}
  end

  defp generate_with_retry(state, attempt \\ 1) do
    case ReqLLM.generate_text(model(), state.context, tools: tools()) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} when attempt < @max_retries ->
        Logger.warning(
          "generation attempt #{attempt}/#{@max_retries} failed, retrying: #{inspect(reason)}",
          sid: state.sid
        )

        Sproutd.Agent.emit(state.sid, {:agent_retry, attempt, @max_retries})
        Process.sleep(500 * attempt)
        generate_with_retry(state, attempt + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_response(state, response) do
    case ReqLLM.Response.tool_calls(response) do
      [] ->
        text = ReqLLM.Response.text(response)
        context = ReqLLM.Context.append(state.context, assistant(text))
        Sproutd.Agent.emit(state.sid, {:agent_message, text})
        %{state | context: context}

      calls ->
        context = ReqLLM.Context.append(state.context, response.message)
        state = %{state | context: context}

        {known, unknown} =
          calls
          |> Enum.map(&{&1, resolve_tool(ReqLLM.ToolCall.name(&1))})
          |> Enum.split_with(fn {_call, tool} -> tool end)

        state =
          Enum.reduce(unknown, state, fn {call, nil}, state ->
            name = ReqLLM.ToolCall.name(call)
            Logger.warning("agent requested unknown tool #{inspect(name)}", sid: state.sid)
            message = "unknown tool #{inspect(name)}"
            context = ReqLLM.Context.append(state.context, tool_result(call.id, name, message))
            %{state | context: context}
          end)

        pending = Map.new(known, fn {call, tool} -> {call.id, tool} end)
        state = %{state | pending: Map.merge(state.pending, pending)}

        Enum.each(known, fn {call, tool} ->
          args = ReqLLM.ToolCall.args_map(call) || %{}
          Logger.info("dispatching #{tool} tool call #{call.id}: #{inspect(args)}", sid: state.sid)
          Sproutd.Agent.emit(state.sid, {:tool_call, call.id, tool, args})
        end)

        if map_size(state.pending) == 0 do
          generate_response(state)
        else
          state
        end
    end
  end

  defp accumulate_usage(state, response) do
    usage = ReqLLM.Response.usage(response) || %{}

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
      )
    ]
  end

  @doc false
  def unused_callback(_args) do
    raise "unreachable: Sproutd.Agent.ReqLLM dispatches tools manually"
  end
end
