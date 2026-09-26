defmodule Sprout.Env do
  @moduledoc false

  @spec put(String.t(), String.t()) :: :ok
  def put(key, value) do
    path = Sprout.env_path()

    content =
      path
      |> read()
      |> parse()
      |> Map.put(key, value)
      |> serialize()

    File.write!(path, content)
  end

  defp read(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, _reason} -> ""
    end
  end

  defp parse(content) do
    content
    |> String.split("\n", trim: true)
    |> Map.new(fn "export " <> kv ->
      [key, value] = String.split(kv, "=", parts: 2)
      {key, value}
    end)
  end

  defp serialize(vars) do
    Enum.map_join(vars, "", fn {k, v} -> "export #{k}=#{v}\n" end)
  end
end