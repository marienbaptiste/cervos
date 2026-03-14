-- Cervos — Initial SQLite Schema
-- Phase 0: Foundation tables

-- Conversation history
CREATE TABLE IF NOT EXISTS conversations (
    id TEXT PRIMARY KEY,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    title TEXT
);

CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL REFERENCES conversations(id),
    role TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'system')),
    content TEXT NOT NULL,
    model_id TEXT,
    model_tier INTEGER CHECK (model_tier IN (0, 1, 2)),
    latency_ms INTEGER,
    cost_usd REAL DEFAULT 0.0,
    tools_invoked TEXT, -- JSON array
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_messages_conversation ON messages(conversation_id);

-- User preferences
CREATE TABLE IF NOT EXISTS preferences (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Device configuration
CREATE TABLE IF NOT EXISTS devices (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    type TEXT NOT NULL CHECK (type IN ('glasses', 'ring', 'earbuds', 'dongle')),
    ble_address TEXT,
    paired_at TEXT,
    last_seen_at TEXT,
    config TEXT -- JSON
);

-- Permission grants
CREATE TABLE IF NOT EXISTS permissions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    tool TEXT NOT NULL,
    tier TEXT NOT NULL CHECK (tier IN ('always', 'confirm', 'unlock')),
    granted INTEGER NOT NULL DEFAULT 0,
    granted_at TEXT,
    expires_at TEXT
);

-- UI template scores
CREATE TABLE IF NOT EXISTS ui_templates (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    template TEXT NOT NULL, -- JSON template definition
    version INTEGER NOT NULL DEFAULT 1,
    quality_score REAL NOT NULL DEFAULT 0.5,
    use_count INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Notification rules
CREATE TABLE IF NOT EXISTS notification_rules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    app_package TEXT NOT NULL,
    priority TEXT NOT NULL CHECK (priority IN ('high', 'normal', 'low', 'muted')),
    push_to_glasses INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
