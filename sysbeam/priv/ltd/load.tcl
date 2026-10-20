# ltd config loader: evaluates a system.tcl and prints one "key value" line per
# setting. The config is real Tcl, so it may compute; only the result crosses
# the wire. Usage: tclsh load.tcl /etc/ltd/system.tcl
proc hostname {name} { puts "hostname $name" }
proc sysctl {key value} { puts "sysctl $key $value" }
proc module {name} { puts "module $name" }
proc bridge {name args} { puts "bridge $name $args" }
proc address {link cidr} { puts "address $link $cidr" }
proc options {who defaults args} {
    array set o $defaults
    foreach {k v} $args { if {![info exists o($k)]} { error "$who: unknown option $k" }; set o($k) $v }
    return [array get o]
}
proc wireguard {name args} {
    array set o [options wireguard {-port 0 -key -} {*}$args]
    puts "wireguard $name port $o(-port) key $o(-key)"
}
proc peer {dev pub args} {
    array set o [options peer {-allowed {} -endpoint - -keepalive 0} {*}$args]
    puts "peer $dev $pub allowed [join $o(-allowed) ,] endpoint $o(-endpoint) keepalive $o(-keepalive)"
}
proc boot {key value} { puts "boot $key $value" }
source [lindex $argv 0]
