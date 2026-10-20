defmodule Sysbeam.Bpf do
  @moduledoc """
  eBPF, enough to police a cgroup's network: a program is raw instruction
  bytes, loaded and attached through bpf(2) in Sysbeam.Sys. Constants from
  linux/bpf.h. No compiler on the image: programs are assembled by hand here.
  """
  alias Sysbeam.Sys

  @prog_type_cgroup_skb 8
  @cgroup_inet_egress 1

  # r0 = 0 (drop), exit: every packet the cgroup sends is refused with EPERM.
  @drop <<0xB7, 0, 0, 0, 0, 0, 0, 0, 0x95, 0, 0, 0, 0, 0, 0, 0>>

  def egress, do: @cgroup_inet_egress
  def drop, do: @drop

  @doc "Load `insns` as a cgroup_skb program and attach it to the cgroup directory; replaces what was there."
  def attach(cgroup, attach_type, insns) do
    with {:ok, fd} <- Sys.bpf_prog_load(@prog_type_cgroup_skb, insns, attach_type) do
      try do
        Sys.bpf_prog_attach(fd, cgroup, attach_type)
      after
        Sys.close(fd)
      end
    end
  end

  def detach(cgroup, attach_type), do: Sys.bpf_prog_detach(cgroup, attach_type)

  @doc "How many programs are attached at `attach_type`."
  def attached(cgroup, attach_type), do: Sys.bpf_prog_query(cgroup, attach_type)
end
