#!/usr/bin/env python3
"""Regression checks for coordinator-chat optimistic message reconciliation.

The UI must keep an immediate sending bubble, then reconcile exactly the
optimistic copy acknowledged by the server without collapsing same-body sends.
Acknowledged optimistic rows may remain briefly for read-your-write smoothing,
but they must no longer be marked sending and must carry the server message id.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHAIN_VIEW = ROOT / "src" / "ui" / "store" / "chainViewSlice.ts"
APP = ROOT / "src" / "ui" / "components" / "App.tsx"


def require(src: str, needle: str, path: Path) -> None:
    if needle not in src:
        raise AssertionError(f"missing {needle!r} in {path}")


def forbid(src: str, needle: str, path: Path) -> None:
    if needle in src:
        raise AssertionError(f"forbidden {needle!r} in {path}")


def main() -> None:
    store = CHAIN_VIEW.read_text(encoding="utf-8")
    app = APP.read_text(encoding="utf-8")

    # One per-send local id is threaded into both the optimistic entry and the
    # async server request. This keeps two identical bodies distinct.
    require(app, "const localId = `local_${Date.now()}_", APP)
    require(app, "optimisticCoordinatorMessage({ chainId: selectedChain.chainId, body, localId })", APP)
    require(app, "sendCoordinatorMessage({ chainId: selectedChain.chainId, body, localId })", APP)
    require(store, "payload: { chainId: string; body: string; localId: string }", CHAIN_VIEW)
    require(store, "id: action.payload?.localId", CHAIN_VIEW)

    # Fulfilled send reconciles only the acknowledged optimistic entry by local
    # id and annotates it with the server id / delivered state.
    require(store, "const { chainId, localId, result } = action.payload;", CHAIN_VIEW)
    require(store, "if (m.id !== localId && m.localId !== localId) return m;", CHAIN_VIEW)
    require(store, "messageId: messageId || m.id,", CHAIN_VIEW)
    require(store, "sending: false,", CHAIN_VIEW)
    require(store, "deliveredUnixMs: Number(m.deliveredUnixMs || Date.now()),", CHAIN_VIEW)

    # Rejected sends preserve the optimistic row for visible failure state.
    require(store, ".addCase(sendCoordinatorMessage.rejected, (state: any, action) => {", CHAIN_VIEW)
    require(store, "deliveryFailedUnixMs: Date.now(),", CHAIN_VIEW)
    require(store, "deliveryError: errorMessage,", CHAIN_VIEW)

    # Refreshed server chat can remove entries by server id if a mapped id exists,
    # but must not drop same-body messages by body equality.
    require(store, "serverIds", CHAIN_VIEW)
    require(store, "if (m.messageId && serverIds.has(m.messageId)) return false;", CHAIN_VIEW)
    forbid(store, "serverUserBodies", CHAIN_VIEW)
    forbid(store, "serverUserBodies.has(m.body)", CHAIN_VIEW)
    forbid(store, "m.body === body", CHAIN_VIEW)

    # Render persisted chat plus optimistic rows through the shared normalizer so
    # pending, delivered, and failed local rows all share the same status UI.
    require(app, "const messages = useMemo(() => normalizeCoordinatorMessages([...chat, ...optimistic]), [chat, optimistic]);", APP)

    print("PASS: coordinator optimistic chat reconciliation contract")


if __name__ == "__main__":
    main()
