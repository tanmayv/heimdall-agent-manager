package main

import "core:testing"

@(test)
test_chain_archive_destructive_verb :: proc(t: ^testing.T) {
	testing.expect(t, is_destructive_chain_verb("archive"), "archive must be destructive verb requiring explicit chain")
	testing.expect(t, is_destructive_chain_verb("unarchive"), "unarchive must be destructive verb requiring explicit chain")
	testing.expect(t, is_destructive_chain_verb("complete"), "complete must be destructive verb")
	testing.expect(t, is_destructive_chain_verb("publish"), "publish must be destructive verb")
	testing.expect(t, is_destructive_chain_verb("reopen"), "reopen must be destructive verb")
	testing.expect(t, !is_destructive_chain_verb("show"), "show is not destructive")
	testing.expect(t, !is_destructive_chain_verb("list"), "list is not destructive")
}
