defmodule Sysbeam.Sys do
  @moduledoc """
  mount(2), umount(2), reboot(2), kill(2), finit_module(2), delete_module(2), a raw netlink socket, bpf(2) as a NIF (c_src/sysbeam_sys.c), cross-compiled
  by post-build.sh into this release's priv/. Target only: on the host the
  .so is absent, the module fails to load, and nothing calls it.
  """
  @on_load :load

  def load do
    :sysbeam |> Application.app_dir("priv/sysbeam_sys") |> String.to_charlist() |> :erlang.load_nif(0)
  end

  # <sys/mount.h>
  def ms_rdonly, do: 1
  def ms_nosuid, do: 2
  def ms_nodev, do: 4
  def ms_noexec, do: 8

  @doc "mount(source, target, fstype, flags, data). `:ok | {:error, :eperm | :enoent | :ebusy | ...}`."
  def mount(_source, _target, _fstype, _flags, _data), do: :erlang.nif_error(:not_loaded)

  @doc "umount(target)."
  def umount(_target), do: :erlang.nif_error(:not_loaded)

  @doc "reboot(:poweroff | :restart | :halt). Does not return on success; needs CAP_SYS_BOOT."
  def reboot(_how), do: :erlang.nif_error(:not_loaded)

  @sigterm 15
  @doc "kill(pid, signal). pid must be > 0: no process groups, no broadcast."
  def kill(_pid, _signal), do: :erlang.nif_error(:not_loaded)
  def sigterm, do: @sigterm

  @doc "finit_module on the .ko at `path`. `{:error, :eexist}` when already loaded."
  def init_module(_path), do: :erlang.nif_error(:not_loaded)

  @doc "delete_module(name, O_NONBLOCK). `{:error, :ebusy}` while something uses it."
  def delete_module(_name), do: :erlang.nif_error(:not_loaded)

  @doc "A raw netlink socket for `protocol` (0 is NETLINK_ROUTE), bound, 2 s receive timeout. `{:ok, fd}`."
  def netlink_open(_protocol), do: :erlang.nif_error(:not_loaded)
  def netlink_send(_fd, _message), do: :erlang.nif_error(:not_loaded)
  @doc "One datagram. `{:ok, binary} | {:error, :eagain}` on timeout."
  def netlink_recv(_fd), do: :erlang.nif_error(:not_loaded)

  @doc "close(2) on any fd this module handed out."
  def close(_fd), do: :erlang.nif_error(:not_loaded)

  @doc "BPF_PROG_LOAD of raw instructions. `{:ok, fd} | {:error, errno, verifier_log}`."
  def bpf_prog_load(_prog_type, _insns, _expected_attach_type), do: :erlang.nif_error(:not_loaded)
  @doc "BPF_PROG_ATTACH of `fd` to the cgroup directory at `path`."
  def bpf_prog_attach(_fd, _cgroup_path, _attach_type), do: :erlang.nif_error(:not_loaded)
  def bpf_prog_detach(_cgroup_path, _attach_type), do: :erlang.nif_error(:not_loaded)
  @doc "BPF_PROG_QUERY: `{:ok, count}` of programs attached at `attach_type`."
  def bpf_prog_query(_cgroup_path, _attach_type), do: :erlang.nif_error(:not_loaded)
end
