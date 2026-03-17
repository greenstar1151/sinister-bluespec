if { $::argc != 4 } {
    puts "ERROR: Program \"$::argv0\" requires 4 arguments!"
    puts "Usage: $::argv0 <xoname> <krnl_name> <target> <device>"
    exit 1
}

set xoname    [lindex $::argv 0]
set krnl_name [lindex $::argv 1]
set target    [lindex $::argv 2]
set device    [lindex $::argv 3]

source -notrace ./package_kernel.tcl

if {[file exists $xoname]} {
    file delete -force $xoname
}

package_xo -xo_path $xoname -kernel_name $krnl_name -ip_directory ./obj/packaged_kernel -kernel_xml ./kernel.xml
