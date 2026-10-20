defmodule Sysbeam.Netlink do
  @moduledoc """
  netlink messages as binaries: nlmsghdr, ifinfomsg, ifaddrmsg, genlmsghdr
  and rtattr, native byte order, 4-byte alignment, constants from
  linux/netlink.h, rtnetlink.h, if_link.h, if_addr.h and genetlink.h. One
  socket per request; the reply is collected until the ack, the error, or
  the end of a dump.
  """
  import Bitwise
  alias Sysbeam.Sys

  @route 0
  @generic 16
  @nested 0x8000
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

  @doc "Send `type` with `payload` on NETLINK_ROUTE, return `{:ok, [payload]}` of the reply or `{:error, errno}`."
  def request(type, flags, payload), do: request(@route, type, flags, payload)

  def request(proto, type, flags, payload) do
    {:ok, fd} = Sys.netlink_open(proto)

    try do
      with :ok <- Sys.netlink_send(fd, message(type, flags ||| @f_request, payload)), do: collect(fd, [])
    after
      Sys.close(fd)
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
  def ifaddrmsg(family, prefixlen, index), do: <<family, prefixlen, 0, 0, index::32-native>>
  @doc "genlmsghdr: command, version, reserved."
  def genlmsghdr(cmd, version), do: <<cmd, version, 0::16>>

  @doc "Resolve a generic netlink family name to its id through the controller."
  def genl_family(name) do
    with {:ok, [reply | _]} <- request(@generic, 0x10, @f_ack, genlmsghdr(3, 1) <> attr(2, string(name))),
         <<_::32, rest::binary>> <- reply,
         <<id::16-native>> <- attrs(rest)[1],
         do: {:ok, id}
  end

  def generic, do: @generic

  def attr(type, value) do
    len = 4 + byte_size(value)
    <<len::16-native, type::16-native, value::binary, 0::size((align(len) - len) * 8)>>
  end

  def nest(type, attrs), do: attr(Bitwise.bor(type, @nested), IO.iodata_to_binary(attrs))

  def string(s), do: s <> <<0>>

  @doc "`%{type => value}` from a run of attributes."
  def attrs(bin), do: Map.new(attr_list(bin))

  @doc "`[{type, value}]` in wire order; the NESTED flag is dropped from the type."
  def attr_list(<<len::16-native, type::16-native, rest::binary>>) when len >= 4 do
    body = min(len - 4, byte_size(rest))
    skip = min(align(len) - 4, byte_size(rest))
    <<value::binary-size(body), _::binary>> = rest
    <<_::binary-size(skip), tail::binary>> = rest
    [{Bitwise.band(type, 0x7FFF), value} | attr_list(tail)]
  end

  def attr_list(_), do: []

  @doc "A nested list of nested items (all type 0, in order): `[attrs]`."
  def items(nil), do: []
  def items(bin), do: for({_, item} <- attr_list(bin), do: attrs(item))

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
  @rtm_newaddr 20
  @rtm_deladdr 21
  @rtm_getaddr 22
  @ifa_address 1
  @ifa_local 2
  @af_inet 2

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

  @doc "IPv4 addresses as `%{index => [\"a.b.c.d/n\"]}`."
  def addresses do
    with {:ok, addrs} <- NL.request(@rtm_getaddr, NL.f_dump(), NL.ifaddrmsg(@af_inet, 0, 0)) do
      {:ok,
       for <<@af_inet, prefix, _, _, index::32-native, rest::binary>> <- addrs, a = NL.attrs(rest), ip = a[@ifa_local] || a[@ifa_address], reduce: %{} do
         acc -> Map.update(acc, index, ["#{ip(ip)}/#{prefix}"], &Enum.sort(["#{ip(ip)}/#{prefix}" | &1]))
       end}
    end
  end

  def add_address(index, cidr), do: address(@rtm_newaddr, NL.f_ack() + NL.f_create_excl(), index, cidr)
  def del_address(index, cidr), do: address(@rtm_deladdr, NL.f_ack(), index, cidr)

  defp address(type, flags, index, cidr) do
    {ip, prefix} = parse_cidr(cidr)
    ack(NL.request(type, flags, NL.ifaddrmsg(@af_inet, prefix, index) <> NL.attr(@ifa_local, ip) <> NL.attr(@ifa_address, ip)))
  end

  @doc "`{<<a, b, c, d>>, prefix}` from `\"a.b.c.d/prefix\"`."
  def parse_cidr(cidr) do
    [ip, prefix] = String.split(cidr, "/")
    {:ok, {a, b, c, d}} = :inet.parse_ipv4_address(String.to_charlist(ip))
    {<<a, b, c, d>>, String.to_integer(prefix)}
  end

  def ip(<<a, b, c, d>>), do: "#{a}.#{b}.#{c}.#{d}"

  defp ack({:ok, _}), do: :ok
  defp ack(error), do: error
end

defmodule Sysbeam.Netlink.Wireguard do
  @moduledoc """
  A wireguard device over generic netlink (linux/wireguard.h): get the
  listen port and peers, set the private key, port and the full peer list.
  Keys are 32 raw bytes here; base64 is the file format.
  """
  alias Sysbeam.Netlink, as: NL
  alias Sysbeam.Netlink.Link

  @get 0
  @set 1
  @version 1
  @a_ifname 2
  @a_private_key 3
  @a_flags 5
  @a_listen_port 6
  @a_peers 8
  @f_replace_peers 1
  @p_public_key 1
  @p_endpoint 4
  @p_keepalive 5
  @p_allowedips 9
  @ip_family 1
  @ip_addr 2
  @ip_cidr 3
  @af_inet 2

  @doc "`{:ok, %{port, peers: %{pubkey_b64 => %{allowed, endpoint, keepalive}}}}`."
  def get(name) do
    with {:ok, id} <- NL.genl_family("wireguard"),
         {:ok, replies} <- NL.request(NL.generic(), id, NL.f_dump(), NL.genlmsghdr(@get, @version) <> NL.attr(@a_ifname, NL.string(name))) do
      devs = for <<_::32, rest::binary>> <- replies, do: NL.attrs(rest)
      port = Enum.find_value(devs, 0, &with(<<p::16-native>> <- &1[@a_listen_port], do: p))
      peers = for dev <- devs, peer <- NL.items(dev[@a_peers]), into: %{}, do: peer(peer)
      {:ok, %{port: port, peers: peers}}
    end
  end

  defp peer(a) do
    allowed = for ip <- NL.items(a[@p_allowedips]), ip[@ip_family] == <<@af_inet::16-native>>, <<cidr>> = ip[@ip_cidr], do: "#{Link.ip(ip[@ip_addr])}/#{cidr}"
    endpoint = case a[@p_endpoint] do
      <<@af_inet::16-native, port::16-big, ip::binary-size(4), _::binary>> -> "#{Link.ip(ip)}:#{port}"
      _ -> nil
    end
    keepalive = case a[@p_keepalive] do
      <<k::16-native>> when k > 0 -> k
      _ -> nil
    end
    {Base.encode64(a[@p_public_key]), %{allowed: Enum.sort(allowed), endpoint: endpoint, keepalive: keepalive}}
  end

  @doc "Set the private key (base64), port and the exact peer set `%{pubkey_b64 => %{allowed, endpoint, keepalive}}`."
  def set(name, key_b64, port, peers) do
    peers = for {pub, p} <- peers, do: NL.nest(0, [NL.attr(@p_public_key, Base.decode64!(pub)), NL.nest(@p_allowedips, Enum.map(p.allowed, &allowed/1))] ++ endpoint(p[:endpoint]) ++ keepalive(p[:keepalive]))
    payload =
      NL.genlmsghdr(@set, @version) <>
        NL.attr(@a_ifname, NL.string(name)) <> NL.attr(@a_flags, <<@f_replace_peers::32-native>>) <>
        NL.attr(@a_private_key, Base.decode64!(key_b64)) <> NL.attr(@a_listen_port, <<port::16-native>>) <> NL.nest(@a_peers, peers)

    with {:ok, id} <- NL.genl_family("wireguard"), {:ok, _} <- NL.request(NL.generic(), id, NL.f_ack(), payload), do: :ok
  end

  defp allowed(cidr) do
    {ip, prefix} = Link.parse_cidr(cidr)
    NL.nest(0, [NL.attr(@ip_family, <<@af_inet::16-native>>), NL.attr(@ip_addr, ip), NL.attr(@ip_cidr, <<prefix>>)])
  end

  defp endpoint(nil), do: []
  defp endpoint(hostport) do
    [host, port] = String.split(hostport, ":")
    {ip, _} = Link.parse_cidr(host <> "/0")
    [NL.attr(@p_endpoint, <<@af_inet::16-native, String.to_integer(port)::16-big, ip::binary, 0::64>>)]
  end

  defp keepalive(nil), do: []
  defp keepalive(k), do: [NL.attr(@p_keepalive, <<k::16-native>>)]
end
