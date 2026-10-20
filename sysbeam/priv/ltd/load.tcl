# ltd config loader: evaluates a system.tcl and prints one "key value" line per
# setting. The config is real Tcl, so it may compute; only the result crosses
# the wire. Usage: tclsh load.tcl /etc/ltd/system.tcl
proc hostname {name} { puts "hostname $name" }
proc sysctl {key value} { puts "sysctl $key $value" }
proc module {name} { puts "module $name" }
proc bridge {name args} { puts "bridge $name $args" }
proc boot {key value} { puts "boot $key $value" }
source [lindex $argv 0]
