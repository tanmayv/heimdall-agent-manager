// e2ekey prints the minisign public key of the e2e suite's fixed test key
// (src/supervisor/testkit E2E_SEED); its output is src/supervisor/testdata/e2e-test-key.pub.
package e2ekey

import "core:fmt"
import "../../testkit"

main :: proc() {
	k := testkit.e2e_key()
	fmt.print(k.pub_txt)
}
