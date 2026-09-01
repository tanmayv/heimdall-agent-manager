#!/usr/bin/env python3
"""Static checks for the browser notifications (v1) feature.

Locks in the architecture invariants for native OS notifications:
- A PURE mapper (notificationMapper.ts) with no DOM/permission side effects that
  encodes the curated notify set + the excluded set.
- A thin side-effectful service (notificationService.ts) that gates on
  support/Electron/visibility+focus and is the ONLY place that touches
  window.Notification.
- Wiring off the single handleUserWsEvent funnel.
- A notifications Redux slice registered in the store with localStorage
  persistence and permission gating.
- A Settings > Notifications panel mounted in the shell.
"""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def require(cond: bool, msg: str) -> None:
    if not cond:
        print(f"FAILED: {msg}")
        sys.exit(1)


def main() -> None:
    mapper = read("src/ui/api/notificationMapper.ts")
    service = read("src/ui/services/notificationService.ts")
    slice_src = read("src/ui/store/notificationsSlice.ts")
    store = read("src/ui/store/store.ts")
    ws = read("src/ui/api/wsInvalidation.ts")
    panel = read("src/ui/components/settings/NotificationsPanel.tsx")
    shell = read("src/ui/components/shell/AppShell.tsx")

    # --- Pure mapper: no DOM/permission side effects -------------------------
    require("export function notificationForWsEvent(" in mapper,
            "mapper must export notificationForWsEvent")
    for forbidden in ["window.Notification", "requestPermission", "document.",
                      "new Notification", "localStorage"]:
        require(forbidden not in mapper,
                f"pure mapper must not reference {forbidden}")
    # Curated notify set present.
    for token in ["chat_event", "chat_approval", "merge_decision_pending",
                  "agent_to_user"]:
        require(token in mapper, f"mapper must handle curated event token {token}")
    # Excluded set explicitly present (never notify).
    for token in ["resource_changed", "agent_runtime_changed",
                  "agent_lifecycle_changed", "memory_event", "task_event"]:
        require(token in mapper, f"mapper must reference excluded token {token}")
    # Status-only receipts excluded.
    for token in ["read", "delivered", "delivery_failed"]:
        require(token in mapper, f"mapper must exclude status receipt {token}")
    require("category" in mapper and "tag" in mapper and "route" in mapper,
            "mapper plan must include category/tag/route")

    # --- Service: gating + single Notification owner -------------------------
    require("isTabBackgrounded" in service,
            "service must implement open-but-unfocused gate isTabBackgrounded")
    require("visibilityState" in service and "hasFocus" in service,
            "service gate must use visibilityState + hasFocus")
    require("isElectronRuntime" in service and "odinApi" in service,
            "service must guard Electron via odinApi")
    require("requestNotificationPermission" in service,
            "service must expose requestNotificationPermission")
    require("new window.Notification(" in service,
            "service must be the place that constructs window.Notification")
    # Click => focus existing window OR open a new window fallback + route.
    require("window.focus()" in service, "click handler must focus the window")
    require("window.open(" in service,
            "click handler must fall back to opening a new window")
    require("buildRouteHash" in service, "service must deep-link via buildRouteHash")
    require("renotify" in service, "service should set renotify for tag coalescing")
    # Permission must NOT be auto-requested at import/module load.
    require("requestPermission()" not in service.split("export async function requestNotificationPermission")[0],
            "service must not call requestPermission before its explicit function")

    # --- Wiring off the single funnel ---------------------------------------
    require("fireNotificationForWsEvent" in ws,
            "handleUserWsEvent must invoke fireNotificationForWsEvent")
    require("fireNotificationForWsEvent" in service,
            "service must export fireNotificationForWsEvent")

    # --- Slice + store registration -----------------------------------------
    require("createSlice" in slice_src and "notifications" in slice_src,
            "notifications slice must exist")
    require("localStorage" in slice_src,
            "slice must persist via localStorage")
    require("permission" in slice_src and "granted" in slice_src,
            "slice must gate on granted permission")
    require("notificationsReducer" in store and "notifications:" in store,
            "store must register the notifications reducer")

    # --- Settings panel mounted ---------------------------------------------
    require("NotificationsPanel" in panel or "settings-notifications-panel" in panel,
            "NotificationsPanel component must exist")
    require("role=\"switch\"" in panel, "panel must use accessible switch toggles")
    require("requestNotificationPermission" in panel,
            "panel toggle must request permission via explicit user gesture")
    require("import NotificationsPanel" in shell,
            "AppShell must import NotificationsPanel")
    require("/settings/notifications" in shell,
            "AppShell must route /settings/notifications")

    # --- H11: Send-test-notification button ---------------------------------
    require('data-debug-id="settings-notifications-test-btn"' in panel,
            "panel must render the Send-test-notification button (H11)")
    # It always gives visible in-app feedback via a toast.
    require("showToast" in panel and "from '../../store/toastSlice'" in panel,
            "test button must dispatch an in-app toast for visible feedback (H11)")
    # It exercises the real native path when supported+granted (service boundary).
    require("showNativeNotification" in panel,
            "test button must fire the real showNativeNotification path when granted (H11)")
    # The sample plan is the Heimdall test notification.
    require("Heimdall test notification" in panel,
            "test button must use the sample Heimdall test notification plan (H11)")
    # Non-throwing: guarded so a failure still yields a toast (try/catch present).
    require("try {" in panel and "onSendTest" in panel,
            "test handler must be guarded (non-throwing) and dispatch a toast in all cases (H11)")
    # Only the service module touches window.Notification (boundary preserved).
    require("window.Notification" not in panel,
            "panel must NOT touch window.Notification directly (service-module boundary)")

    print("test_ui_notifications_static: ok")


if __name__ == "__main__":
    main()
