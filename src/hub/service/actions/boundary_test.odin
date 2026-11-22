package actions

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_actions_imports :: proc(t:^testing.T) {actions_track(t,actions_import_cases)}
actions_import_cases :: proc(t:^testing.T) {
	root:=strings.trim_right(#directory,"/")
	services:=filepath.dir(root)
	testing.expect(t,actions_scan_imports(t,root,true)>0)
	testing.expect(t,actions_scan_imports(t,strings.concatenate({services,"/taskv2"},context.temp_allocator),false)>0)
	testing.expect(t,actions_scan_imports(t,strings.concatenate({services,"/taskchain"},context.temp_allocator),false)>0)
}
actions_scan_imports :: proc(t:^testing.T, dir:string, own_package:bool) -> int {
	entries,err:=os.read_all_directory_by_path(dir,context.temp_allocator)
	if !testing.expect(t,err==nil,dir) do return 0
	count:=0
	for entry in entries {
		if entry.type==.Directory {count+=actions_scan_imports(t,entry.fullpath,own_package);continue}
		if !strings.has_suffix(entry.name,".odin") || strings.has_suffix(entry.name,"_test.odin") do continue
		data,read_err:=os.read_entire_file(entry.fullpath,context.temp_allocator)
		if !testing.expect(t,read_err==nil,entry.fullpath) do continue
		count+=1
		for line in strings.split_lines(string(data),context.temp_allocator) {
			code:=strings.trim_space(line)
			if !strings.has_prefix(code,"import ") do continue
			if own_package {
				forbidden_packages:=[]string{"taskv2","taskchain","eventinbox","bots","agent","content"}
				for forbidden in forbidden_packages {
					pattern:=strings.concatenate({"\"odin_test:hub/service/",forbidden,"\""},context.temp_allocator)
					testing.expect(t,!strings.contains(code,pattern),entry.fullpath)
				}
			} else {
				testing.expect(t,!strings.contains(code,"\"odin_test:hub/service/actions\""),entry.fullpath)
			}
		}
	}
	return count
}

