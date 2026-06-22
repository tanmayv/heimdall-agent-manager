# Message Persistence Migration Plan

## Objective
Replace in-memory chat message storage with SQLite database persistence. Eliminate array size limits, fix read status loss on restart, and improve reliability.

## Architecture Changes

### 1. Database Schema
```sql
CREATE TABLE messages (
  message_id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  agent_instance_id TEXT NOT NULL,
  direction TEXT NOT NULL,
  body TEXT NOT NULL,
  delivered_unix_ms INTEGER DEFAULT 0,
  delivery_failed_unix_ms INTEGER DEFAULT 0,
  delivery_error TEXT,
  created_unix_ms INTEGER NOT NULL
);

CREATE TABLE conversation_read_status (
  user_id TEXT NOT NULL,
  agent_instance_id TEXT NOT NULL,
  last_read_unix_ms INTEGER DEFAULT 0,
  PRIMARY KEY (user_id, agent_instance_id)
);

CREATE INDEX idx_user_agent ON messages(user_id, agent_instance_id);
CREATE INDEX idx_created ON messages(created_unix_ms);
```

**Optimization**: Use single `last_read_unix_ms` per conversation instead of per-message read status. Messages created after last_read_unix_ms are unread.

### 2. New Module: MessageDbService
**File:** `src/daemon/message_db_service.odin`

Responsibilities:
- SQLite database initialization and connection
- CRUD operations for messages
- Query operations (fetch by user/agent, unread filter, etc.)
- Transaction handling
- Error handling and logging

### 3. Modified Modules
- **chat_store.odin**: Remove in-memory arrays, delegate to MessageDbService
- **user_rpc.odin**: Use MessageDbService for chat_fetch_json queries
- **agent_rpc.odin**: No changes needed (calls same interfaces)
- **chat_service.odin**: Replace with DB persistence
- **chat_events.odin**: Keep WS event handling, remove persistence

### 4. Removed Code
- `chat_events` array (CHAT_MAX_EVENTS)
- `chat_messages` array (CHAT_MAX_MESSAGES)
- Event JSON serialization for persistence
- Event replay logic

## Implementation Steps

### Phase 1: Create MessageDbService
1. Design and implement SQLite wrapper
2. Add database initialization
3. Implement core CRUD operations
4. Add query helpers (fetch, filter, count)

### Phase 2: Replace chat_store
1. Update chat_store_init to use database
2. Replace chat_store_append_event with DB writes
3. Update chat_store_apply_event to work with DB
4. Implement chat_fetch_json with DB queries

### Phase 3: Update interfaces
1. Ensure all callers work with new backend
2. Fix any API inconsistencies
3. Test message lifecycle

### Phase 4: Testing
1. Test message creation and retrieval
2. Test read status persistence across restart
3. Test large message volumes
4. Test concurrent access

## Key Benefits
✓ Unlimited message storage (no 20K limit)
✓ Read status persists across daemon restart
✓ Reliable persistence (ACID guarantees)
✓ Efficient querying
✓ No more silent array-full failures
✓ Cleaner code separation (storage vs events)

## Risk Mitigation
- Database file in data_dir for proper cleanup
- Transaction isolation for consistency
- Error handling with logging
- Gradual rollout (can revert if needed)

## Timeline
- Phase 1: 30 mins (MessageDbService scaffold + basic ops)
- Phase 2: 30 mins (chat_store integration)
- Phase 3: 15 mins (interface updates)
- Phase 4: 15 mins (testing)
