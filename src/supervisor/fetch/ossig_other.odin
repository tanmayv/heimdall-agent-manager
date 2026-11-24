#+build linux, freebsd, openbsd, netbsd
package fetch

// Linux (and other POSIX): there is no OS code signature to check; the
// release manifest is the only trust anchor.

@(private)
os_signature_state :: proc(path, rel: string) -> (state: Signature_State, identity: string, detail: string) {
	return .Not_Applicable, "", ""
}

@(private)
clear_quarantine :: proc(staging: string, files: []Extracted_File) -> Error {
	return nil
}
