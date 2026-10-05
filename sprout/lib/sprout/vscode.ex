defmodule Sprout.VSCode do
  @moduledoc false

  @spec socket_path() :: Path.t()
  def socket_path do
    # TODO(robin): this should be /var/run or something, according to POSIX, right?
    "/tmp/sprout.sock"
  end

  @spec available?() :: boolean()
  def available? do
    case connect() do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  @type outcome ::
          {:ok, :accepted}
          | {:ok, :edited, String.t()}
          | {:error, :rejected}
          | {:error, atom() | String.t()}

  @spec request_edit(Path.t(), String.t(), String.t()) :: outcome()
  def request_edit(path, old_content, new_content) do
    request = "EDIT|#{escape(path)}|#{escape(old_content)}|#{escape(new_content)}"

    with {:ok, socket} <- connect() do
      try do
        with {:ok, response} <- call(socket, request) do
          parse_response(response)
        end
      after
        :gen_tcp.close(socket)
      end
    end
  end

  @timeout 30_000

  defp connect do
    sock_path = String.to_charlist(socket_path())

    case :gen_tcp.connect({:local, sock_path}, 0, [:binary, packet: :line, active: false], @timeout) do
      {:ok, socket} -> {:ok, socket}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp call(socket, request) do
    with :ok <- :gen_tcp.send(socket, request <> "\n") do
      case :gen_tcp.recv(socket, 0, @timeout) do
        {:ok, data} -> {:ok, String.trim(data)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp parse_response("ACCEPTED"), do: {:ok, :accepted}
  defp parse_response("REJECTED"), do: {:error, :rejected}

  defp parse_response("EDITED|" <> escaped_content) do
    {:ok, :edited, unescape(escaped_content)}
  end

  defp parse_response(response), do: {:error, "unexpected response: #{response}"}

  defp escape(string) do
    string
    |> String.replace("|", "\\|")
    |> String.replace("\n", "\\n")
  end

  defp unescape(string) do
    string
    |> String.replace("\\n", "\n")
    |> String.replace("\\|", "|")
  end
end