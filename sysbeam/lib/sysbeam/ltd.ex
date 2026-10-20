defmodule Sysbeam.Ltd.Mounts do
  @moduledoc "ltd's first job: the virtual filesystems. Synchronous, so later children can rely on /proc."
  alias Sysbeam.Sys

  # {source, target, fstype}. devtmpfs goes over the static /dev nodes the cpio shipped.
  @mounts [
    {"proc", "/proc", "proc"},
    {"sys", "/sys", "sysfs"},
    {"selinuxfs", "/sys/fs/selinux", "selinuxfs"},
    {"cgroup2", "/sys/fs/cgroup", "cgroup2"},
    {"dev", "/dev", "devtmpfs"},
    {"tmp", "/tmp", "tmpfs"},
    {"run", "/run", "tmpfs"},
    {"/dev/vda1", "/boot", "vfat"}
  ]

  def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}}

  def start_link do
    for {source, target, type} <- @mounts do
      case Sys.mount(source, target, type, 0, "") do
        :ok -> Sysbeam.log("ltd", "mounted #{target}")
        {:error, reason} -> Sysbeam.log("ltd", "mount #{target} skipped: #{reason}")
      end
    end

    :ignore
  end
end

defmodule Sysbeam.Ltd.Loopback do
  @moduledoc "ltd's second job: lo up. Nothing else on the box would do it."
  def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}}

  def start_link do
    with {:error, e} <- Sysbeam.Netlink.Link.up("lo"), do: Sysbeam.log("ltd", "lo not up (errno #{e})")
    :ignore
  end
end

defmodule Sysbeam.Ltd.Config do
  @moduledoc """
  The on-disk config: a Tcl script calling `hostname`, `sysctl`, `module`, `bridge`,
  `wireguard`, `peer`, `address` and `boot`. tclsh
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

  def render(%{hostname: hostname, sysctl: sysctl, modules: modules, bridges: bridges, wireguard: wireguard, addresses: addresses, boot: boot}) do
    @header <>
      "hostname #{hostname}\n" <>
      Enum.map_join(Enum.sort(sysctl), fn {k, v} -> "sysctl #{k} #{v}\n" end) <>
      Enum.map_join(modules, fn m -> "module #{m}\n" end) <>
      Enum.map_join(Enum.sort(bridges), fn {b, ports} -> "bridge #{Enum.join([b | ports], " ")}\n" end) <>
      Enum.map_join(Enum.sort(wireguard), fn {w, dev} ->
        "wireguard #{w} -port #{dev.port} -key #{dev.key}\n" <>
          Enum.map_join(Enum.sort(dev.peers), fn {pub, p} ->
            "peer #{w} #{pub} -allowed {#{Enum.join(p.allowed, " ")}}" <>
              if(p.endpoint, do: " -endpoint #{p.endpoint}", else: "") <> if(p.keepalive, do: " -keepalive #{p.keepalive}", else: "") <> "\n"
          end)
      end) <>
      Enum.map_join(Enum.sort(addresses), fn {l, cidrs} -> Enum.map_join(cidrs, &"address #{l} #{&1}\n") end) <>
      Enum.map_join(Enum.sort(boot), fn {k, v} -> "boot #{k} {#{v}}\n" end)
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
    |> Enum.reduce(%{hostname: nil, sysctl: %{}, modules: [], bridges: %{}, wireguard: %{}, addresses: %{}, boot: %{}}, fn
      "hostname " <> name, acc -> %{acc | hostname: name}
      "sysctl " <> kv, acc ->
        [k, v] = String.split(kv, " ", parts: 2)
        put_in(acc, [:sysctl, k], v)
      "module " <> name, acc -> %{acc | modules: Enum.sort([name | acc.modules])}
      "bridge " <> names, acc ->
        [b | ports] = String.split(names, " ", trim: true)
        put_in(acc, [:bridges, b], Enum.sort(ports))
      "wireguard " <> rest, acc ->
        [w, "port", port, "key", key] = String.split(rest, " ")
        put_in(acc, [:wireguard, w], %{port: String.to_integer(port), key: key, peers: %{}})
      "peer " <> rest, acc ->
        [w, pub, "allowed", allowed, "endpoint", endpoint, "keepalive", keepalive] = String.split(rest, " ")
        peer = %{allowed: Enum.sort(String.split(allowed, ",", trim: true)), endpoint: if(endpoint != "-", do: endpoint), keepalive: if(keepalive != "0", do: String.to_integer(keepalive))}
        put_in(acc, [:wireguard, w, :peers, pub], peer)
      "address " <> rest, acc ->
        [l, cidr] = String.split(rest, " ")
        update_in(acc, [:addresses, l], &Enum.sort([cidr | &1 || []]))
      "boot " <> kv, acc ->
        [k, v] = String.split(kv, " ", parts: 2)
        put_in(acc, [:boot, k], v)
      _, acc -> acc
    end)
  end
end

defmodule Sysbeam.Ltd.Modules do
  @moduledoc """
  Kernel modules. modules.dep (depmod ran at build) gives each module's
  dependencies; finit_module loads them in order and delete_module unloads
  them, the module first. /proc/modules says what is loaded; a loaded module
  nothing else uses is one ltd declares, its dependencies come and go with it.
  """
  alias Sysbeam.Sys

  def dir, do: "/lib/modules/" <> String.trim(File.read!("/proc/sys/kernel/osrelease"))

  @doc "Paths under the modules dir to load for `name`, dependencies first; nil if unknown."
  def load_order(depfile, name) do
    Enum.find_value(String.split(depfile, "\n", trim: true), fn line ->
      with [path, deps] <- String.split(line, ":", parts: 2),
           true <- modname(path) == name,
           do: Enum.reverse(String.split(deps, " ", trim: true)) ++ [path]
    end)
  end

  def known?(name), do: load_order(depfile(), name) != nil

  def load(name) do
    case load_order(depfile(), name) do
      nil -> {:error, :unknown_module}
      paths -> Enum.find_value(paths, :ok, &failed(Sys.init_module(Path.join(dir(), &1))))
    end
  end

  def unload(name) do
    for path <- Enum.reverse(load_order(depfile(), name) || []), do: Sys.delete_module(modname(path))
    if name in loaded(), do: {:error, :ebusy}, else: :ok
  end

  @doc "Loaded modules nothing else uses, from /proc/modules."
  def loaded do
    for line <- String.split(File.read!("/proc/modules"), "\n", trim: true),
        [name, _size, "0", "-" | _] <- [String.split(line, " ")],
        do: name
  end

  defp failed(:ok), do: nil
  defp failed({:error, :eexist}), do: nil
  defp failed(error), do: error
  defp depfile, do: File.read!(Path.join(dir(), "modules.dep"))
  # the kernel's name for a module: file name without .ko, dashes as underscores
  defp modname(path), do: path |> Path.basename(".ko") |> String.replace("-", "_")
end

defmodule Sysbeam.Ltd.Bridges do
  @moduledoc """
  Bridges and their ports through rtnetlink, as `%{bridge => [port]}`. A
  bridge is a link of kind bridge; its ports are the links whose master it
  is. Applying creates and deletes bridges and moves ports; everything is
  brought up on the way.
  """
  alias Sysbeam.Netlink.Link

  def read do
    {:ok, links} = Link.list()
    for %{kind: "bridge", index: i, name: b} <- links, into: %{} do
      {b, Enum.sort(for %{master: ^i, name: p} <- links, do: p)}
    end
  end

  def apply(desired) do
    current = read()
    for b <- Map.keys(current) -- Map.keys(desired), do: Link.delete(b)
    for b <- Map.keys(desired) -- Map.keys(current), {:error, e} <- [Link.add(b, "bridge")], do: Sysbeam.log("ltd", "bridge #{b} not added (errno #{e})")
    {:ok, links} = Link.list()
    index = Map.new(links, &{&1.name, &1.index})

    for {b, ports} <- desired, i = index[b] do
      for p <- ports -- (current[b] || []), do: Link.set_master(p, i)
      for p <- (current[b] || []) -- ports, do: Link.set_master(p, 0)
    end

    :ok
  end

  @doc "A link name that does not exist, or nil."
  def missing(names) do
    {:ok, links} = Link.list()
    Enum.find(names, &(&1 not in Enum.map(links, fn l -> l.name end)))
  end
end

defmodule Sysbeam.Ltd.Wireguard do
  @moduledoc """
  wireguard devices as `%{name => %{port, key, peers}}`: the link exists with
  kind wireguard; port and peers come from the device over generic netlink.
  The private key lives in its own file, named by `key`; the kernel never
  gives it back, so the path is kept from the declared view.
  """
  alias Sysbeam.Netlink.{Link, Wireguard}

  def read(declared) do
    {:ok, links} = Link.list()

    for %{kind: "wireguard", name: w} <- links, {:ok, dev} <- [Wireguard.get(w)], into: %{} do
      {w, %{port: dev.port, key: get_in(declared, [w, :key]), peers: dev.peers}}
    end
  end

  def apply(desired) do
    {:ok, links} = Link.list()
    current = for %{kind: "wireguard", name: w} <- links, do: w
    for w <- current -- Map.keys(desired), do: Link.delete(w)
    for w <- Map.keys(desired) -- current, {:error, e} <- [Link.add(w, "wireguard")], do: Sysbeam.log("ltd", "wireguard #{w} not added (errno #{e})")

    for {w, dev} <- desired, {:error, e} <- [Wireguard.set(w, String.trim(File.read!(dev.key)), dev.port, dev.peers)],
        do: Sysbeam.log("ltd", "wireguard #{w} not configured (errno #{e})")

    :ok
  end
end

defmodule Sysbeam.Ltd.Addresses do
  @moduledoc "IPv4 addresses per link, `%{link => [cidr]}`, every link but lo."
  alias Sysbeam.Netlink.Link

  def read do
    {:ok, links} = Link.list()
    {:ok, addrs} = Link.addresses()
    for %{index: i, name: n} <- links, n != "lo", cidrs = addrs[i], into: %{}, do: {n, cidrs}
  end

  def apply(desired) do
    current = read()
    {:ok, links} = Link.list()
    index = Map.new(links, &{&1.name, &1.index})

    for l <- Enum.uniq(Map.keys(desired) ++ Map.keys(current)), i = index[l] do
      # delete first: removing a primary address takes its secondaries in the same subnet with it
      for c <- (current[l] || []) -- (desired[l] || []), do: Link.del_address(i, c)
      for c <- (desired[l] || []) -- (current[l] || []), do: Link.add_address(i, c)
    end

    :ok
  end
end

defmodule Sysbeam.Ltd.Grubenv do
  @moduledoc """
  GRUB's environment block: a 1024-byte file, a signature line, `name=value`
  lines, `#` padding. GRUB's `load_env` reads it at boot, so the kernel command
  line for the next boot is bootloader state ltd reads and writes here, with no
  GRUB tooling on the image.
  """
  @path "/boot/EFI/BOOT/grubenv"
  @size 1024
  @signature "# GRUB Environment Block\n"

  def path, do: @path

  def read(path \\ @path) do
    with {:ok, @signature <> body} <- File.read(path) do
      lines = for l <- String.split(body, "\n"), not String.starts_with?(l, "#"), [k, v] <- [String.split(l, "=", parts: 2)], do: {k, v}
      {:ok, Map.new(lines)}
    end
  end

  def write(path \\ @path, env) do
    body = @signature <> Enum.map_join(Enum.sort(env), fn {k, v} -> "#{k}=#{v}\n" end)
    if byte_size(body) > @size, do: {:error, :too_long}, else: File.write(path, body <> String.duplicate("#", @size - byte_size(body)))
  end
end

defmodule Sysbeam.Ltd.Kernel do
  @moduledoc """
  The running system: /proc/sys for hostname and sysctl, GRUB's environment
  block for what the next boot gets. An unreadable block (no disk, no /boot)
  reads as the view's own boot state, so a diskless boot never drifts.
  """
  alias Sysbeam.Ltd.{Addresses, Bridges, Grubenv, Modules, Wireguard}

  def read(%{sysctl: sysctl, wireguard: wireguard, boot: boot}) do
    %{
      hostname: get("kernel.hostname"),
      modules: Enum.sort(Modules.loaded()),
      bridges: Bridges.read(),
      wireguard: Wireguard.read(wireguard),
      addresses: Addresses.read(),
      sysctl: Map.new(sysctl, fn {k, _} -> {k, get(k)} end),
      boot: (case Grubenv.read() do {:ok, env} -> env; _ -> boot end)
    }
  end

  def apply(%{hostname: hostname, sysctl: sysctl, modules: modules, bridges: bridges, wireguard: wireguard, addresses: addresses, boot: boot}) do
    File.write!(proc("kernel.hostname"), hostname)
    for {k, v} <- sysctl, do: File.write!(proc(k), v)

    loaded = Modules.loaded()
    for m <- modules -- loaded, {:error, r} <- [Modules.load(m)], do: Sysbeam.log("ltd", "module #{m} not loaded (#{r})")
    for m <- loaded -- modules, {:error, r} <- [Modules.unload(m)], do: Sysbeam.log("ltd", "module #{m} not unloaded (#{r})")
    Bridges.apply(bridges)
    Wireguard.apply(wireguard)
    Addresses.apply(addresses)

    with {:error, reason} <- Grubenv.write(boot),
         do: Sysbeam.log("ltd", "bootloader state not written (#{reason})")

    :ok
  end

  # A config ltd refuses to apply or write: bad hostname, or a sysctl this kernel lacks.
  def validate(%{hostname: hostname, sysctl: sysctl, modules: modules, bridges: bridges, wireguard: wireguard, addresses: addresses, boot: boot}) do
    declared = Map.keys(bridges) ++ Map.keys(wireguard)

    cond do
      link = Bridges.missing(Map.keys(addresses) -- declared) ->
        {:error, "unknown link #{link}"}

      missing = Enum.find_value(wireguard, fn {w, dev} -> not File.exists?(dev.key) and "#{w} key file #{dev.key}" end) ->
        {:error, "missing #{missing}"}

      bad = Enum.find_value(wireguard, fn {w, dev} -> Enum.find_value(dev.peers, fn {pub, _} -> match?(:error, Base.decode64(pub)) and "#{w} peer #{pub}" end) end) ->
        {:error, "bad key for #{bad}"}

      port = Bridges.missing(List.flatten(Map.values(bridges))) ->
        {:error, "unknown link #{port}"}

      bad = Enum.find(Map.keys(bridges), &(not Regex.match?(~r/^[A-Za-z0-9_.-]{1,15}$/, &1))) ->
        {:error, "bad bridge name #{inspect(bad)}"}

      unknown = Enum.find(modules, &(not Modules.known?(&1))) ->
        {:error, "unknown module #{unknown}"}

      bad = Enum.find(boot, fn {k, v} -> k =~ ~r/[=\n]| / or v =~ "\n" end) ->
        {:error, "bad boot entry #{inspect(bad)}"}

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
          Kernel.read(%{sysctl: %{}, modules: [], bridges: %{}, wireguard: %{}, addresses: %{}, boot: %{}})
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
    {fa, fb} = {flatten(a), flatten(b)}
    Enum.map_join(Enum.reject(fa, fn {k, x} -> fb[k] == x end), ", ", fn {k, x} -> "#{k} #{x} -> #{fb[k]}" end)
  end

  defp flatten(v) do
    Map.merge(%{"hostname" => v.hostname}, v.sysctl)
    |> Map.merge(Map.new(v.boot, fn {k, x} -> {"boot #{k}", x} end))
    |> Map.merge(Map.new(v.modules, &{"module #{&1}", "loaded"}))
    |> Map.merge(Map.new(v.bridges, fn {b, ports} -> {"bridge #{b}", Enum.join(ports, ",")} end))
    |> Map.merge(Map.new(v.addresses, fn {l, cidrs} -> {"address #{l}", Enum.join(cidrs, ",")} end))
    |> Map.merge(Map.new(v.wireguard, fn {w, dev} -> {"wireguard #{w}", "port #{dev.port}"} end))
    |> Map.merge(Map.new(for {w, dev} <- v.wireguard, {pub, p} <- dev.peers, do: {"peer #{w} #{pub}", inspect(p)}))
|> Map.merge(Map.new(v.boot, fn {k, x} -> {"boot #{k}", x} end))
  end
end
