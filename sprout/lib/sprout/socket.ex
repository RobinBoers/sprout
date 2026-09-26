defmodule Sprout.Socket do
  @moduledoc """
  Manages interactions with outside-world via a Unix socket.
  """
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    sock = Sprout.socket_path()
    File.rm_rf!(sock)

    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :line,
        active: false,
        reuseaddr: true,
        ifaddr: {:local, String.to_charlist(sock)}
      ])

    {:ok, listen, {:continue, :accept}}
  end

  @impl true
  def handle_continue(:accept, listen) do
    {:ok, conn} = :gen_tcp.accept(listen)
    handle_connection(conn)
    {:noreply, listen, {:continue, :accept}}
  end

  defp handle_connection(conn) do
    case :gen_tcp.recv(conn, 0) do
      {:ok, line} ->
        :gen_tcp.send(conn, handle_event(String.trim(line)) <> "\n")

      {:error, _reason} ->
        :ok
    end

    :gen_tcp.close(conn)
  end

  defp handle_event("join") do
    case Sprout.Client.join() do
      {:ok, sid} -> "sid #{sid}"
      _ -> "error"
    end
  end

  defp handle_event("attach " <> sid) do
    case Sprout.Client.attach(sid) do
      :ok -> "ok"
      _ -> "error"
    end
  end

  defp handle_event("leave") do
    case Sprout.Client.leave() do
      {:ok, sids, usage} ->
        "bye #{usage.duration} #{usage.total_tokens} #{usage.input_tokens} #{usage.output_tokens} #{usage.cost} #{Enum.join(sids, ",")}"

      {:error, :not_attached} ->
        "not attached to any session (run /join or /attach first)"
    end
  end

  defp handle_event("blind") do
    Sprout.PTY.blind()
    "ok"
  end

  defp handle_event("unblind") do
    Sprout.PTY.unblind()
    "ok"
  end

  defp handle_event("chat " <> message) do
    Sprout.TTY.lock()

    case Sprout.Client.chat(message) do
      :ok ->
        "ok"

      {:error, :not_attached} ->
        Sprout.TTY.unlock()
        "not attached to any session (run /join or /attach first)"
    end
  end

  defp handle_event(_other) do
    "unknown command"
  end
end