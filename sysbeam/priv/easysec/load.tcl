# easysec policy loader: evaluates a policy.tcl and prints one line per worker:
#   worker INDEX caps net_admin,sys_boot pids_max 128 net allow console /dev/ttyS0
# The policy is real Tcl, so it may compute; only the result crosses the wire.
# Usage: tclsh load.tcl /etc/easysec/policy.tcl
proc worker {index args} {
    set caps {}; set pids_max {}; set net allow; set console {}
    foreach {opt val} $args {
        switch -- $opt {
            -caps     { set caps $val }
            -pids_max { set pids_max $val }
            -net      { set net $val }
            -console  { set console $val }
            default   { error "worker $index: unknown option $opt" }
        }
    }
    if {[llength $args] % 2} { error "worker $index: option without a value" }
    if {$pids_max eq ""} { error "worker $index: -pids_max is required" }
    if {![string is integer -strict $pids_max] || $pids_max < 1} { error "worker $index: -pids_max must be a positive integer, got '$pids_max'" }
    if {$net ni {allow deny}} { error "worker $index: -net must be allow or deny, got '$net'" }
    set line "worker $index caps [join $caps ,] pids_max $pids_max net $net"
    if {$console ne ""} { append line " console $console" }
    puts $line
}
source [lindex $argv 0]
