package agent

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// Scope the exceptions to procedures: adding a second start elsewhere in one
// of these files must still fail the scan.
start_boundary_allowed :: proc(path, procedure:string)->bool {
	if strings.has_suffix(path,"/agent/start_begin.odin") do return true
	if strings.has_suffix(path,"/agent/agent_service.odin") {
		return procedure=="prepare_instance" || procedure=="create_provider_test_instance" || procedure=="reserve_runtime_launch"
	}
	if strings.has_suffix(path,"/agent/instance_reconfiguration.odin") && procedure=="reconfiguration_launch_destination" do return true // Stop/move recovery.
	return false
}
start_boundary_scan :: proc(t:^testing.T, path:string)->int {
	fd,err:=os.open(path)
	if !testing.expect(t,err==nil) do return 0
	defer os.close(fd)
	it:=os.read_directory_iterator_create(fd)
	defer os.read_directory_iterator_destroy(&it)
	count:=0
	for entry in os.read_directory_iterator(&it) {
		file,_:=filepath.join([]string{path,entry.name},context.temp_allocator)
		if os.is_dir(file) { count+=start_boundary_scan(t,file);continue }
		if !strings.has_suffix(file,".odin") || strings.has_suffix(file,"_test.odin") do continue
		data,re:=os.read_entire_file(file,context.temp_allocator)
		if !testing.expect(t,re==nil) do continue
		count+=1
		procedure:=""
		for raw in strings.split_lines(string(data),context.temp_allocator) {
			line:=strings.trim_space(raw)
			if strings.has_prefix(line,"//") do continue
			if at:=strings.index(line," :: proc");at>=0 do procedure=strings.trim_space(line[:at])
			compact,_:=strings.replace_all(line," ","",context.temp_allocator)
			launching:=strings.contains(compact,"runtime_status=\"launching\"") && !strings.contains(compact,"runtime_status==")
			bump:=strings.contains(compact,".run_count+=1") || strings.contains(compact,".run_count=1") || strings.contains(compact,"run_count=1,") || strings.contains(compact,"run_count=1}")
			if !launching && !bump do continue
			testing.expectf(t,start_boundary_allowed(file,procedure),"generation writer outside allow-list: %s:%s: %s",file,procedure,line)
		}
	}
	return count
}
@(test)
test_start_has_one_implementation :: proc(t:^testing.T) {
	track:mem.Tracking_Allocator
	mem.tracking_allocator_init(&track,context.allocator);defer mem.tracking_allocator_destroy(&track)
	context.allocator=mem.tracking_allocator(&track)
	root:=filepath.dir(filepath.dir(#directory))
	testing.expect(t,start_boundary_scan(t,root)>100)
	testing.expect_value(t,len(track.allocation_map),0)
}
