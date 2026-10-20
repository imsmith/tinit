defmodule Sysbeam.Netlink do
  @moduledoc """
  rtnetlink messages as binaries: nlmsghdr, ifinfomsg and rtattr, native
  byte order, 4-byte alignment, constants from linux/netlink.h, rtnetlink.h
  and if_link.h. One socket per request; the reply is collected until the
  ack, the error, or the end of a dump.
  """
  import Bitwise
  alias Sysbeam.Sys

  @route 0
  @nlmsg_error 2
  @nlmsg_done 3
  @f_request 0x01
  @f_ack 0x04
  @f_dump 0x300
  @f_excl 0x200
  @f_create 0x400

  def f_ack, do: @f_ack
  def f_dump, do: @f_dump
  def f_create_excl, do: @f_create ||| @f_excl

  @doc "Send `type` with `payload`, return `{:ok, [payload]}` of the reply or `{:error, errno}`."
  def request(type, flags, payload) do
    {:ok, fd} = Sys.netlink_open(@route)

    try do
      with :ok <- Sys.netlink_send(fd, message(type, flags ||| @f_request, payload)), do: collect(fd, [])
    after
      Sys.netlink_close(fd)
    end
  end

  defp collect(fd, acc) do
    with {:ok, data} <- Sys.netlink_recv(fd) do
      case finish(parse(data), acc) do
        {:more, acc} -> collect(fd, acc)
        {:done, acc} -> {:ok, Enum.reverse(acc)}
        error -> error
      end
    end
  end

  defp finish([], acc), do: {:more, acc}
  defp finish([{@nlmsg_done, _, _} | _], acc), do: {:done, acc}
  defp finish([{@nlmsg_error, _, <<0::32-signed-native, _::binary>>} | _], acc), do: {:done, acc}
  defp finish([{@nlmsg_error, _, <<e::32-signed-native, _::binary>>} | _], _), do: {:error, -e}
  defp finish([{_, _, payload} | rest], acc), do: finish(rest, [payload | acc])

  def message(type, flags, payload) do
    <<16 + byte_size(payload)::32-native, type::16-native, flags::16-native, 1::32-native, 0::32-native, payload::binary>>
  end

  @doc "`[{type, flags, payload}]` from one or more concatenated messages."
  def parse(<<len::32-native, type::16-native, flags::16-native, _::32, _::32, rest::binary>>) when len >= 16 do
    body = min(len - 16, byte_size(rest))
    skip = min(align(len) - 16, byte_size(rest))
    <<payload::binary-size(body), _::binary>> = rest
    <<_::binary-size(skip), tail::binary>> = rest
    [{type, flags, payload} | parse(tail)]
  end

  def parse(_), do: []

  def ifinfomsg(index, flags, change), do: <<0, 0, 0::16, index::32-signed-native, flags::32-native, change::32-native>>

  def attr(type, value) do
    len = 4 + byte_size(value)
    <<len::16-native, type::16-native, value::binary, 0::size((align(len) - len) * 8)>>
  end

  def string(s), do: s <> <<0>>

  @doc "`%{type => value}` from a run of attributes."
  def attrs(<<len::16-native, type::16-native, rest::binary>>) when len >= 4 do
    body = min(len - 4, byte_size(rest))
    skip = min(align(len) - 4, byte_size(rest))
    <<value::binary-size(body), _::binary>> = rest
    <<_::binary-size(skip), tail::binary>> = rest
    Map.put(attrs(tail), type, value)
  end

  def attrs(_), do: %{}

  def cstring(nil), do: nil
  def cstring(bin), do: bin |> String.split(<<0>>) |> hd()

  defp align(n), do: (n + 3) &&& ~~~3
end

defmodule Sysbeam.Netlink.Link do
  @moduledoc "Network links through rtnetlink: list, add a bridge, delete, set a port's master."
  alias Sysbeam.Netlink, as: NL

  @rtm_newlink 16
  @rtm_dellink 17
  @rtm_getlink 18
  @ifla_ifname 3
  @ifla_master 10
  @ifla_linkinfo 18
  @ifla_info_kind 1
  @iff_up 1

  @doc "`[%{index, name, kind, master, up}]`; kind and master are nil when absent."
  def list do
    with {:ok, links} <- NL.request(@rtm_getlink, NL.f_dump(), NL.ifinfomsg(0, 0, 0)), do: {:ok, Enum.map(links, &link/1)}
  end

  defp link(<<_::32, index::32-signed-native, flags::32-native, _::32, rest::binary>>) do
    a = NL.attrs(rest)
    info = NL.attrs(a[@ifla_linkinfo] || "")
    master = with <<m::32-native>> <- a[@ifla_master], do: m

    %{index: index, name: NL.cstring(a[@ifla_ifname]), kind: NL.cstring(info[@ifla_info_kind]), master: master, up: Bitwise.band(flags, @iff_up) == @iff_up}
  end

  def add(name, kind) do
    payload = NL.ifinfomsg(0, @iff_up, @iff_up) <> NL.attr(@ifla_ifname, NL.string(name)) <> NL.attr(@ifla_linkinfo, NL.attr(@ifla_info_kind, NL.string(kind)))
    ack(NL.request(@rtm_newlink, NL.f_ack() + NL.f_create_excl(), payload))
  end

  def delete(name), do: ack(NL.request(@rtm_dellink, NL.f_ack(), NL.ifinfomsg(0, 0, 0) <> NL.attr(@ifla_ifname, NL.string(name))))

  @doc "Enslave `name` to the link at `master_index` (0 releases it) and bring it up."
  def set_master(name, master_index) do
    payload = NL.ifinfomsg(0, @iff_up, @iff_up) <> NL.attr(@ifla_ifname, NL.string(name)) <> NL.attr(@ifla_master, <<master_index::32-native>>)
    ack(NL.request(@rtm_newlink, NL.f_ack(), payload))
  end

  defp ack({:ok, _}), do: :ok
  defp ack(error), do: error
end
