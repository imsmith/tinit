defmodule Sysbeam.Ltd.Mounts do
  @moduledoc "ltd's first job: the virtual filesystems. Synchronous, so later children can rely on /proc."

  @mounts [
    {"proc", "proc", "/proc"},
    {"sysfs", "sys", "/sys"},
    {"devtmpfs", "dev", "/dev"},
    {"tmpfs", "tmp", "/tmp"},
    {"tmpfs", "run", "/run"}
  ]

  def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}}

  def start_link do
    for {type, name, target} <- @mounts do
      case System.cmd("mount", ["-t", type, name, target], stderr_to_stdout: true) do
        {_, 0} -> Sysbeam.log("ltd", "mounted #{target}")
        {err, _} -> Sysbeam.log("ltd", "mount #{target} skipped: #{String.trim(err)}")
      end
    end

    :ignore
  end
end

defmodule Sysbeam.Ltd.Config do
  @moduledoc """
  The on-disk config: a Tcl script calling `hostname` and `sysctl`. tclsh
  evaluates it through priv/ltd/load.tcl, so the file may compute but only
  the resulting settings cross into ltd.

  `save/2` never writes a file it cannot load back to the identical state:
  render to a temp file, load it, compare, then rename over the original.
  """

  @path "/etc/ltd/system.tcl"
  @header "# ltd system config. ltd rewrites this file when the running system drifts.\n"

  def path, do: @path

  def load(path \\ @path) do
    loader = Application.app_dir(:sysbeam, "priv/ltd/load.tcl")

    case System.cmd("tclsh", [loader, path], stderr_to_stdout: true) do
      {out, 0} -> {:ok, parse(out)}
      {err, _} -> {:error, String.trim(err)}
    end
  end

  def render(%{hostname: hostname, sysctl: sysctl}) do
    @header <>
      "hostname #{hostname}\n" <>
      Enum.map_join(Enum.sort(sysctl), fn {k, v} -> "sysctl #{k} #{v}\n" end)
  end

  def save(state, path \\ @path) do
    tmp = path <> ".tmp"
    File.write!(tmp, render(state))

    case load(tmp) do
      {:ok, ^state} -> File.rename(tmp, path)
      other -> File.rm(tmp); {:error, {:roundtrip, other}}
    end
  end

  defp parse(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{hostname: nil, sysctl: %{}}, fn
      "hostname " <> name, acc -> %{acc | hostname: name}
      "sysctl " <> kv, acc ->
        [k, v] = String.split(kv, " ", parts: 2)
        put_in(acc, [:sysctl, k], v)
      _, acc -> acc
    end)
  end
end

defmodule Sysbeam.Ltd.Kernel do
  @moduledoc "The running system, through /proc/sys. Hostname is just kernel.hostname."

  def read(%{sysctl: sysctl}) do
    %{
      hostname: get("kernel.hostname"),
      sysctl: Map.new(sysctl, fn {k, _} -> {k, get(k)} end)
    }
  end

  def apply(%{hostname: hostname, sysctl: sysctl}) do
    File.write!(proc("kernel.hostname"), hostname)
    for {k, v} <- sysctl, do: File.write!(proc(k), v)
    :ok
  end

  # A config ltd refuses to apply or write: bad hostname, or a sysctl this kernel lacks.
  def validate(%{hostname: hostname, sysctl: sysctl}) do
    cond do
      not (is_binary(hostname) and Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9.-]{0,63}$/, hostname)) ->
        {:error, "bad hostname #{inspect(hostname)}"}

      missing = Enum.find(Map.keys(sysctl), &(not File.exists?(proc(&1)))) ->
        {:error, "unknown sysctl #{missing}"}

      true ->
        :ok
    end
  end

  defp get(key), do: key |> proc() |> File.read!() |> String.trim()
  defp proc(key), do: "/proc/sys/" <> String.replace(key, ".", "/")
end

defmodule Sysbeam.ConfigStore do
  @moduledoc """
  ltd's materialized view of system config, reconciled both ways.

  The view in memory is the truth. The config file and the kernel are two
  stores kept consistent with it: a changed file is loaded, validated and
  applied to the kernel; drift in the kernel is adopted into the view and
  written back to the file. If both changed in one tick the file wins, since
  it is the declared intent. A file that fails to load or validate is refused
  and the previous view stays in force.
  """
  use GenServer
  alias Sysbeam.Ltd.{Config, Kernel}

  @tick_ms 2_000

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)
  def view, do: GenServer.call(__MODULE__, :view)

  @impl true
  def init(_) do
    view =
      case load_file() do
        {:ok, view} ->
          Kernel.apply(view)
          Sysbeam.log("ltd", "config materialized: #{inspect(view)}")
          view

        {:error, reason} ->
          Sysbeam.log("ltd", "config refused (#{reason}); running with kernel state")
          Kernel.read(%{sysctl: %{}})
      end

    Sysbeam.log("ltd", "running -- config reconciliation loop active")
    Process.send_after(self(), :tick, @tick_ms)
    {:ok, %{view: view, mtime: mtime()}}
  end

  @impl true
  def handle_call(:view, _from, state), do: {:reply, state.view, state}

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, reconcile(state)}
  end

  defp reconcile(%{view: view, mtime: mtime} = state) do
    cond do
      mtime() != mtime ->
        case load_file() do
          {:ok, ^view} ->
            %{state | mtime: mtime()}

          {:ok, desired} ->
            Kernel.apply(desired)
            Sysbeam.log("ltd", "config file changed, applied: #{inspect(desired)}")
            %{state | view: desired, mtime: mtime()}

          {:error, reason} ->
            Sysbeam.log("ltd", "config file changed but refused (#{reason}); keeping #{inspect(view)}")
            %{state | mtime: mtime()}
        end

      (running = Kernel.read(view)) != view ->
        Sysbeam.log("ltd", "drift: #{diff(view, running)}; config file updated")

        case Config.save(running) do
          :ok -> %{state | view: running, mtime: mtime()}
          {:error, reason} ->
            Sysbeam.log("ltd", "drift not saved (#{inspect(reason)})")
            %{state | view: running}
        end

      true ->
        state
    end
  end

  defp load_file do
    with {:ok, view} <- Config.load(), :ok <- Kernel.validate(view), do: {:ok, view}
  end

  defp mtime do
    case File.stat(Config.path(), time: :posix) do
      {:ok, %{mtime: t}} -> t
      _ -> nil
    end
  end

  defp diff(a, b) do
    [hostname: {a.hostname, b.hostname}] ++ Enum.map(a.sysctl, fn {k, v} -> {k, {v, b.sysctl[k]}} end)
    |> Enum.reject(fn {_, {x, y}} -> x == y end)
    |> Enum.map_join(", ", fn {k, {x, y}} -> "#{k} #{x} -> #{y}" end)
  end
end
