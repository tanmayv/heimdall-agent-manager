#!/usr/bin/env python3
"""Regression checks for coordinator-chat optimistic message reconciliation.

The UI must keep an immediate sending bubble, then remove/reconcile exactly the
optimistic copy acknowledged by the server. Reconciliation must not use message
body equality because users can send identical coordinator messages twice.
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

    # Fulfilled send removes only the acknowledged optimistic entry by local id.
    require(store, "const { chainId, localId, result } = action.payload;", CHAIN_VIEW)
    require(store, "pending.filter((m: any) => m.id !== localId)", CHAIN_VIEW)

    # Refreshed server chat can remove entries by server id if a mapped id exists,
    # but must not drop same-body messages by body equality.
    require(store, "serverIds", CHAIN_VIEW)
    require(store, "if (m.messageId && serverIds.has(m.messageId)) return false;", CHAIN_VIEW)
    forbid(store, "serverUserBodies", CHAIN_VIEW)
    forbid(store, "serverUserBodies.has(m.body)", CHAIN_VIEW)
    forbid(store, "m.body === body", CHAIN_VIEW)

    # Render only pending optimistic bubbles; acknowledged optimistics are never
    # rendered beside persisted chat.
    require(app, "filter((msg: any) => msg.sending)", APP)
    require(app, "const messages = [...chat, ...optimistic];", APP)

    print("PASS: coordinator optimistic chat reconciliation contract")


if __name__ == "__main__":
    main()
