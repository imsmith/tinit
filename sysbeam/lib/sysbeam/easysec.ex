defmodule Sysbeam.Easysec.Policy do
  @moduledoc """
  What each worker may do, declared in /etc/easysec/policy.tcl:

      worker 0 -caps {net_admin sys_boot} -pids_max 128 -console /dev/ttyS0

  `caps` is an allow-list: sbexec drops every other capability from the
  bounding set before exec, so nothing in the worker can get them back.
  `pids_max` caps the worker's cgroup; `net deny` attaches an eBPF program to
  the cgroup that drops everything it sends; `context` is the SELinux domain
  sbexec execs the worker into. tclsh evaluates the file through
  priv/easysec/load.tcl, so it may compute but only the result crosses into
  easysec. The policy in memory is the authority: easysec enforces it on the
  cgroups and never adopts drift from them.
  """

  @path "/etc/easysec/policy.tcl"

  def path, do: @path

  @doc "`{:ok, %{index => %{caps, pids_max, console?}}}` or `{:error, reason}`."
  def load(path \\ @path) do
    loader = Application.app_dir(:sysbeam, "priv/easysec/load.tcl")

    case System.cmd("tclsh", [loader, path], stderr_to_stdout: true) do
      {out, 0} -> {:ok, parse(out)}
      {err, _} -> {:error, String.trim(err)}
    end
  end

  @doc "sbexec arguments that apply `policy` inside `cgroup` and then start `args` (role, index)."
  def exec(%{caps: keep} = policy, cgroup, args) do
    ["-c", cgroup, "-d"] ++
      Enum.flat_map(keep, &["-k", &1]) ++
      if(policy[:context], do: ["-x", "u:r:#{policy.context}"], else: []) ++
      if(policy[:console], do: ["-t", policy.console], else: []) ++
      args
  end

  @doc """
  What enforcing `new` over `old` takes, per worker, in index order:
  `:pids_max` and `:net` apply live, `:restart` (caps or console changed)
  kills and respawns the worker, `:stop` and `:start` for workers gone and new.
  """
  @live [:pids_max, :net]

  def diff(old, new) do
    for index <- Enum.sort(Enum.uniq(Map.keys(old) ++ Map.keys(new))),
        change <- changes(old[index], new[index]),
        do: {index, change}
  end

  defp changes(nil, _), do: [:start]
  defp changes(_, nil), do: [:stop]
  defp changes(a, b) when a == b, do: []
  defp changes(a, b), do: if(Map.drop(a, @live) == Map.drop(b, @live), do: for(k <- @live, a[k] != b[k], do: k), else: [:restart])

  defp parse(out) do
    for "worker " <> rest <- String.split(out, "\n", trim: true), into: %{} do
      [index | kv] = String.split(rest, " ")
      %{"caps" => caps, "pids_max" => pids_max, "net" => net} = opts = Map.new(Enum.chunk_every(kv, 2), fn [k, v] -> {k, v} end)
      policy = %{caps: String.split(caps, ",", trim: true), pids_max: String.to_integer(pids_max), net: String.to_existing_atom(net)}
      policy = if opts["context"], do: Map.put(policy, :context, opts["context"]), else: policy
      {index, if(opts["console"], do: Map.put(policy, :console, opts["console"]), else: policy)}
    end
  end
end

defmodule Sysbeam.Easysec.Cgroup do
  @moduledoc """
  One cgroup v2 leaf per worker under /sys/fs/cgroup/easysec, pids controller
  on. ltd mounted cgroup2; the BEAMs themselves stay in the root cgroup.
  """
  @root "/sys/fs/cgroup"

  def dir(index), do: Path.join([@root, "easysec", "worker-#{index}"])
  def pids_max_path(index), do: Path.join(dir(index), "pids.max")

  def setup!(name, %{pids_max: max}) do
    dir = Path.join([@root, "easysec", name])
    File.mkdir_p!(dir)
    File.write!(Path.join(@root, "cgroup.subtree_control"), "+pids")
    File.write!(Path.join([@root, "easysec", "cgroup.subtree_control"]), "+pids")
    File.write!(Path.join(dir, "pids.max"), Integer.to_string(max))
    dir
  end
end

defmodule Sysbeam.Easysec.Selinux do
  @moduledoc """
  Loads the compiled policy (/etc/easysec/policy.bin, from policy.cil at
  build time) and switches to enforcing, before any worker starts. A kernel
  without SELinux (no /sys/fs/selinux) is logged and skipped.
  """
  @fs "/sys/fs/selinux"
  @policy "/etc/easysec/policy.bin"

  def load do
    cond do
      not File.exists?(Path.join(@fs, "load")) -> Sysbeam.log("easysec", "selinux: no #{@fs}; policy not loaded")
      true ->
        File.write!(Path.join(@fs, "load"), File.read!(@policy))
        File.write!(Path.join(@fs, "enforce"), "1")
        Sysbeam.log("easysec", "selinux: policy loaded, enforcing")
    end
  end

  @doc "`\"1\"` when enforcing, `\"0\"` when permissive, nil without SELinux."
  def enforcing do
    case File.read(Path.join(@fs, "enforce")) do
      {:ok, v} -> String.trim(v)
      _ -> nil
    end
  end

  def enforce!, do: File.write!(Path.join(@fs, "enforce"), "1")
end

defmodule Sysbeam.Easysec.Enforcer do
  @moduledoc """
  Keeps the running workers equal to the policy. Every tick: a changed policy
  file is loaded and its diff applied (pids.max and net live, caps or console
  by killing and respawning the worker, new and gone workers started and
  stopped); then each worker's cgroup is checked against policy (pids.max,
  the egress program) and any deviation is logged as a violation and
  rewritten; so is SELinux enforcing mode. A file that fails to load
  is refused and the previous policy stays in force.
  """
  use GenServer
  alias Sysbeam.Bpf
  alias Sysbeam.Easysec.{Cgroup, Policy, Selinux}

  @tick_ms 2_000

  def start_link(policy), do: GenServer.start_link(__MODULE__, policy, name: __MODULE__)

  @impl true
  def init(policy) do
    Process.send_after(self(), :tick, @tick_ms)
    {:ok, %{policy: policy, mtime: mtime()}}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @tick_ms)
    state = if mtime() != state.mtime, do: reload(state), else: state
    enforce(state.policy)
    {:noreply, state}
  end

  defp reload(%{policy: old} = state) do
    case Policy.load() do
      {:ok, ^old} ->
        %{state | mtime: mtime()}

      {:ok, new} ->
        changes = Policy.diff(old, new)
        Enum.each(changes, &apply_change(&1, new))
        Sysbeam.log("easysec", "policy file changed, applied: #{Enum.map_join(changes, ", ", fn {i, c} -> "worker #{i} #{c}" end)}")
        %{state | policy: new, mtime: mtime()}

      {:error, reason} ->
        Sysbeam.log("easysec", "policy file changed but refused (#{reason}); keeping previous policy")
        %{state | mtime: mtime()}
    end
  end

  defp apply_change({index, :pids_max}, new), do: File.write!(Cgroup.pids_max_path(index), Integer.to_string(new[index].pids_max))
  defp apply_change({index, :net}, new), do: net(index, new[index])
  defp apply_change({index, :stop}, _), do: stop_worker(index)
  defp apply_change({index, :start}, new), do: start_worker(index, new[index])
  defp apply_change({index, :restart}, new), do: (stop_worker(index); start_worker(index, new[index]))

  defp stop_worker(index) do
    Supervisor.terminate_child(Sysbeam.Supervisor, {:worker, index})
    Supervisor.delete_child(Sysbeam.Supervisor, {:worker, index})
  end

  defp start_worker(index, policy) do
    {:ok, _} = Supervisor.start_child(Sysbeam.Supervisor, worker_spec(index, policy))
  end

  def worker_spec(index, policy) do
    cgroup = Cgroup.setup!("worker-#{index}", policy)
    net(index, policy)
    Sysbeam.log("easysec", "worker #{index} policy: caps #{inspect(policy.caps)}, pids.max #{policy.pids_max}, net #{policy[:net] || :allow}, context #{policy[:context] || "kernel_t"}")

    Supervisor.child_spec(
      {Sysbeam.Tier, role: "worker", index: index, args: Policy.exec(policy, cgroup, ["worker", index])},
      id: {:worker, index}
    )
  end

  defp enforce(policy) do
    for {index, %{pids_max: max}} <- policy, path = Cgroup.pids_max_path(index), (running = String.trim(File.read!(path))) != Integer.to_string(max) do
      Sysbeam.log("easysec", "violation: worker #{index} pids.max #{running} -> #{max}")
      File.write!(path, Integer.to_string(max))
    end

    if Selinux.enforcing() == "0" do
      Sysbeam.log("easysec", "violation: selinux permissive -> enforcing")
      Selinux.enforce!()
    end

    for {index, worker} <- policy, {:ok, n} = Bpf.attached(Cgroup.dir(index), Bpf.egress()), n != wanted(worker) do
      Sysbeam.log("easysec", "violation: worker #{index} net programs #{n} -> #{wanted(worker)}")
      net(index, worker)
    end
  end

  defp wanted(%{net: :deny}), do: 1
  defp wanted(_), do: 0

  defp net(index, %{net: :deny}), do: :ok = Bpf.attach(Cgroup.dir(index), Bpf.egress(), Bpf.drop())
  defp net(index, _), do: Bpf.detach(Cgroup.dir(index), Bpf.egress())

  defp mtime do
    case File.stat(Policy.path(), time: :posix) do
      {:ok, %{mtime: t}} -> t
      _ -> nil
    end
  end
end
