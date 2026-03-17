set path_to_hdl "./obj/verilog"
set path_to_packaged "./obj/packaged_kernel"
set path_to_tmp_project "./obj/tmp_kernel_pack"

create_project -force kernel_pack $path_to_tmp_project
add_files -norecurse [glob $path_to_hdl/*.v]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
set_property top kernel [current_fileset]

ipx::package_project -root_dir $path_to_packaged -vendor greenstar1151 -library RTLKernel -taxonomy /KernelIP -import_files -set_current false
ipx::unload_core $path_to_packaged/component.xml
ipx::edit_ip_in_project -upgrade true -name tmp_edit_project -directory $path_to_packaged $path_to_packaged/component.xml

set core [ipx::current_core]
set_property core_revision 1 $core
set_property sdx_kernel true $core
set_property sdx_kernel_type rtl $core
ipx::create_xgui_files $core
ipx::associate_bus_interfaces -busif s_axi_control -clock ap_clk $core
set_property xpm_libraries {XPM_CDC XPM_MEMORY XPM_FIFO} $core
set_property supported_families { } $core
set_property auto_family_support_level level_2 $core
ipx::update_checksums $core
ipx::save_core $core
close_project -delete
