# easysec policy loader: evaluates a policy.tcl and prints one line per worker:
#   worker INDEX caps net_admin,sys_boot pids_max 128 net allow context admin_t console /dev/ttyS0 syscalls_deny 176 devices c:1:3,c:4:64
# Syscall names come from syscalls_x86_64.txt beside this file (generated from asm/unistd_64.h).
# The policy is real Tcl, so it may compute; only the result crosses the wire.
# Usage: tclsh load.tcl /etc/easysec/policy.tcl
set syscalls [dict create]
set f [open [file join [file dirname [info script]] syscalls_x86_64.txt]]
foreach line [split [string trim [read $f]] \n] { lassign $line name nr; dict set syscalls $name $nr }
close $f

proc worker {index args} {
    global syscalls
    set caps {}; set pids_max {}; set net allow; set context {}; set console {}; set deny {}; set devices {}; set devices_set 0
    foreach {opt val} $args {
        switch -- $opt {
            -caps     { set caps $val }
            -pids_max { set pids_max $val }
            -net      { set net $val }
            -context  { set context $val }
            -syscalls_deny { set deny $val }
            -devices  { set devices $val; set devices_set 1 }
            -console  { set console $val }
            default   { error "worker $index: unknown option $opt" }
        }
    }
    if {[llength $args] % 2} { error "worker $index: option without a value" }
    if {$pids_max eq ""} { error "worker $index: -pids_max is required" }
    if {![string is integer -strict $pids_max] || $pids_max < 1} { error "worker $index: -pids_max must be a positive integer, got '$pids_max'" }
    if {$net ni {allow deny}} { error "worker $index: -net must be allow or deny, got '$net'" }
    set line "worker $index caps [join $caps ,] pids_max $pids_max net $net"
    if {$context ne ""} { append line " context $context" }
    if {[llength $deny]} {
        foreach s $deny { if {![dict exists $syscalls $s]} { error "worker $index: unknown syscall $s" } }
        append line " syscalls_deny [join [lmap s $deny {dict get $syscalls $s}] ,]"
    }
    if {$devices_set} {
        foreach d $devices { if {![regexp {^[cb]:\d+:\d+$} $d]} { error "worker $index: -devices entries look like c:MAJOR:MINOR, got '$d'" } }
        append line " devices [expr {[llength $devices] ? [join $devices ,] : "none"}]"
    }
    if {$console ne ""} { append line " console $console" }
    puts $line
}
source [lindex $argv 0]
