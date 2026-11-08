package main

import "core:sync"

// vcs_runner_test_mutex serializes tests that swap the package-global
// vcs_process_runner (and the test-only globals their fakes read, such as
// owner_head_probe_path). Tests run on parallel threads, so a test must hold
// this lock from before installing its fake until after restoring
// bridge_process_run_capture; otherwise one test's restore clobbers another's
// fake mid-run.
vcs_runner_test_mutex: sync.Mutex

vcs_runner_test_lock :: proc() { sync.mutex_lock(&vcs_runner_test_mutex) }
vcs_runner_test_unlock :: proc() { sync.mutex_unlock(&vcs_runner_test_mutex) }
