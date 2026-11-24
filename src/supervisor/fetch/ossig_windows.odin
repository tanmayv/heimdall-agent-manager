#+build windows
package fetch

// Authenticode check through WinVerifyTrust (wintrust.dll), following
// Microsoft's "Example C Program: Verifying the Signature of a PE File".
// Revocation is not checked and no URL is fetched (WTD_REVOKE_NONE,
// WTD_CACHE_ONLY_URL_RETRIEVAL): the update must work offline, and the
// release manifest, not Authenticode, is the trust anchor.

import "core:strings"
import win "core:sys/windows"

foreign import wintrust "system:wintrust.lib"
foreign import crypt32 "system:crypt32.lib"

@(private)
WINTRUST_FILE_INFO :: struct {
	cbStruct:       u32,
	pcwszFilePath:  win.LPCWSTR,
	hFile:          win.HANDLE,
	pgKnownSubject: ^win.GUID,
}

@(private)
WINTRUST_DATA :: struct {
	cbStruct:            u32,
	pPolicyCallbackData: rawptr,
	pSIPClientData:      rawptr,
	dwUIChoice:          u32,
	fdwRevocationChecks: u32,
	dwUnionChoice:       u32,
	pFile:               ^WINTRUST_FILE_INFO,
	dwStateAction:       u32,
	hWVTStateData:       win.HANDLE,
	pwszURLReference:    win.LPCWSTR,
	dwProvFlags:         u32,
	dwUIContext:         u32,
	pSignatureSettings:  rawptr,
}

@(private)
CRYPT_PROVIDER_CERT :: struct {
	cbStruct: u32,
	pCert:    rawptr, // PCCERT_CONTEXT
	// remaining members unused
}

@(private)
CRYPT_PROVIDER_SGNR :: struct {
	cbStruct:     u32,
	sftVerifyAsOf: win.FILETIME,
	csCertChain:  u32,
	pasCertChain: ^CRYPT_PROVIDER_CERT,
	// remaining members unused
}

@(private)
WINTRUST_ACTION_GENERIC_VERIFY_V2 := win.GUID{0x00aac56b, 0xcd44, 0x11d0, {0x8c, 0xc2, 0x00, 0xc0, 0x4f, 0xc2, 0x95, 0xee}}

@(private) WTD_UI_NONE :: 2
@(private) WTD_REVOKE_NONE :: 0
@(private) WTD_CHOICE_FILE :: 1
@(private) WTD_STATEACTION_VERIFY :: 1
@(private) WTD_STATEACTION_CLOSE :: 2
@(private) WTD_REVOCATION_CHECK_NONE :: 0x10
@(private) WTD_CACHE_ONLY_URL_RETRIEVAL :: 0x1000
@(private) CERT_NAME_SIMPLE_DISPLAY_TYPE :: 4

@(private) TRUST_E_NOSIGNATURE :: u32(0x800B0100)
@(private) TRUST_E_SUBJECT_FORM_UNKNOWN :: u32(0x800B0003)
@(private) TRUST_E_PROVIDER_UNKNOWN :: u32(0x800B0001)

@(default_calling_convention = "system")
foreign wintrust {
	WinVerifyTrust :: proc(hwnd: win.HWND, pgActionID: ^win.GUID, pWVTData: rawptr) -> i32 ---
	WTHelperProvDataFromStateData :: proc(hStateData: win.HANDLE) -> rawptr ---
	WTHelperGetProvSignerFromChain :: proc(pProvData: rawptr, idxSigner: u32, fCounterSigner: win.BOOL, idxCounterSigner: u32) -> ^CRYPT_PROVIDER_SGNR ---
}

@(default_calling_convention = "system")
foreign crypt32 {
	CertGetNameStringW :: proc(pCertContext: rawptr, dwType: u32, dwFlags: u32, pvTypePara: rawptr, pszNameString: win.LPWSTR, cchNameString: u32) -> u32 ---
}

@(private)
is_pe_name :: proc(rel: string) -> bool {
	lower := strings.to_lower(rel, context.temp_allocator)
	return strings.has_suffix(lower, ".exe") || strings.has_suffix(lower, ".dll")
}

@(private)
os_signature_state :: proc(path, rel: string) -> (state: Signature_State, identity: string, detail: string) {
	if !is_pe_name(rel) do return .Not_Applicable, "", ""
	return winverifytrust_state(path)
}

// winverifytrust_state is exported to the tests through os_signature_state.
@(private)
winverifytrust_state :: proc(path: string) -> (state: Signature_State, identity: string, detail: string) {
	wpath := win.utf8_to_wstring(path, context.temp_allocator)
	file_info := WINTRUST_FILE_INFO {
		cbStruct      = size_of(WINTRUST_FILE_INFO),
		pcwszFilePath = wpath,
	}
	data := WINTRUST_DATA {
		cbStruct            = size_of(WINTRUST_DATA),
		dwUIChoice          = WTD_UI_NONE,
		fdwRevocationChecks = WTD_REVOKE_NONE,
		dwUnionChoice       = WTD_CHOICE_FILE,
		pFile               = &file_info,
		dwStateAction       = WTD_STATEACTION_VERIFY,
		dwProvFlags         = WTD_REVOCATION_CHECK_NONE | WTD_CACHE_ONLY_URL_RETRIEVAL,
	}
	status := u32(WinVerifyTrust(nil, &WINTRUST_ACTION_GENERIC_VERIFY_V2, &data))
	last := u32(win.GetLastError())
	defer {
		data.dwStateAction = WTD_STATEACTION_CLOSE
		WinVerifyTrust(nil, &WINTRUST_ACTION_GENERIC_VERIFY_V2, &data)
	}
	switch status {
	case 0:
		return .Valid, signer_name(data.hWVTStateData), ""
	case TRUST_E_NOSIGNATURE:
		// Not signed, or a signature that is present but malformed.
		if last == TRUST_E_NOSIGNATURE || last == TRUST_E_SUBJECT_FORM_UNKNOWN || last == TRUST_E_PROVIDER_UNKNOWN {
			return .Unsigned, "", "no Authenticode signature"
		}
		return .Invalid, "", strings.clone(win_hex(last), context.temp_allocator)
	case:
		return .Invalid, "", strings.clone(win_hex(status), context.temp_allocator)
	}
}

@(private)
win_hex :: proc(v: u32) -> string {
	HEX := "0123456789ABCDEF"
	b := make([]byte, 10, context.temp_allocator)
	b[0], b[1] = '0', 'x'
	for i in 0 ..< 8 do b[2 + i] = HEX[(v >> uint(28 - 4 * i)) & 15]
	return string(b)
}

@(private)
signer_name :: proc(state: win.HANDLE) -> string {
	prov := WTHelperProvDataFromStateData(state)
	if prov == nil do return ""
	sgnr := WTHelperGetProvSignerFromChain(prov, 0, false, 0)
	if sgnr == nil || sgnr.csCertChain == 0 || sgnr.pasCertChain == nil do return ""
	cert := sgnr.pasCertChain.pCert
	if cert == nil do return ""
	buf: [256]u16
	n := CertGetNameStringW(cert, CERT_NAME_SIMPLE_DISPLAY_TYPE, 0, nil, &buf[0], len(buf))
	if n <= 1 do return ""
	name, _ := win.wstring_to_utf8(win.wstring(&buf[0]), int(n - 1), context.temp_allocator)
	return name
}

@(private)
clear_quarantine :: proc(staging: string, files: []Extracted_File) -> Error {
	return nil
}
