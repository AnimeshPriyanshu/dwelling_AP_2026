CREATE EXTENSION IF NOT EXISTS pg_trgm;   -- fuzzy / ILIKE search indexes

CREATE TABLE users (
    user_id         BIGSERIAL PRIMARY KEY,
    username        VARCHAR(50)  NOT NULL,          -- candidate key (see unique index)
    email           VARCHAR(255) NOT NULL,          -- candidate key (see unique index)
    password_hash   VARCHAR(255) NOT NULL,
    active_status   BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE TABLE user_profiles (
    user_id         BIGINT PRIMARY KEY
                    REFERENCES users(user_id) ON DELETE CASCADE,
    display_name    VARCHAR(100),
    about           TEXT,
    avatar_url      VARCHAR(500),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE contacts (
    user_id         BIGINT NOT NULL
                    REFERENCES users(user_id) ON DELETE CASCADE,
    contact_id      BIGINT NOT NULL
                    REFERENCES users(user_id) ON DELETE CASCADE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, contact_id),
    CONSTRAINT chk_contacts_not_self CHECK (user_id <> contact_id)
);

CREATE TABLE blocked_contacts (
    user_id             BIGINT NOT NULL
                        REFERENCES users(user_id) ON DELETE CASCADE,
    blocked_contact_id  BIGINT NOT NULL
                        REFERENCES users(user_id) ON DELETE CASCADE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, blocked_contact_id),
    CONSTRAINT chk_blocked_not_self CHECK (user_id <> blocked_contact_id)
);

CREATE TABLE conversations (
    conversation_id BIGSERIAL PRIMARY KEY,
    type            VARCHAR(20)  NOT NULL DEFAULT 'direct'
                    CHECK (type IN ('direct', 'group')),
    title           VARCHAR(150),
    created_by      BIGINT NOT NULL
                    REFERENCES users(user_id) ON DELETE RESTRICT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE conversation_members (
    conversation_id BIGINT NOT NULL
                    REFERENCES conversations(conversation_id) ON DELETE CASCADE,
    user_id         BIGINT NOT NULL
                    REFERENCES users(user_id) ON DELETE CASCADE,
    role            VARCHAR(20) NOT NULL DEFAULT 'member'
                    CHECK (role IN ('owner', 'admin', 'member')),
    joined_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (conversation_id, user_id)
);

CREATE TABLE messages (
    message_id          BIGSERIAL PRIMARY KEY,
    conversation_id     BIGINT NOT NULL
                        REFERENCES conversations(conversation_id) ON DELETE CASCADE,
    sender_id           BIGINT NOT NULL
                        REFERENCES users(user_id) ON DELETE RESTRICT,
    reply_to_message_id BIGINT
                        REFERENCES messages(message_id) ON DELETE SET NULL,
    content             TEXT NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    edited_at           TIMESTAMPTZ,
    deleted_at          TIMESTAMPTZ
);

CREATE TABLE message_receipts (
    message_id      BIGINT NOT NULL
                    REFERENCES messages(message_id) ON DELETE CASCADE,
    recipient_id    BIGINT NOT NULL
                    REFERENCES users(user_id) ON DELETE CASCADE,
    status          VARCHAR(20) NOT NULL DEFAULT 'sent'
                    CHECK (status IN ('sent', 'delivered', 'read')),
    delivered_at    TIMESTAMPTZ,
    read_at         TIMESTAMPTZ,
    PRIMARY KEY (message_id, recipient_id)
);

-- INDEXES

-- users
-- Case-insensitive uniqueness + fast login lookup by username / email
CREATE UNIQUE INDEX uq_users_username_lower ON users (LOWER(username));
CREATE UNIQUE INDEX uq_users_email_lower    ON users (LOWER(email));

-- Prefix / substring user search ("find user" box)
CREATE INDEX idx_users_username_trgm ON users USING GIN (username gin_trgm_ops);

-- Active-user listings without scanning deactivated accounts
CREATE INDEX idx_users_active_created ON users (created_at DESC)
    WHERE active_status = TRUE;

-- user_profiles   (PK on user_id covers profile-by-user lookups)
CREATE INDEX idx_user_profiles_display_name_trgm
    ON user_profiles USING GIN (display_name gin_trgm_ops);

-- contacts   (PK (user_id, contact_id) covers "my contacts")
-- Reverse lookup: "who has me as a contact"
CREATE INDEX idx_contacts_contact_id ON contacts (contact_id, user_id);

-- blocked_contacts   (PK (user_id, blocked_contact_id) covers "my blocks"
--                     and the "did A block B" check)
-- Reverse lookup: "who has blocked me"
CREATE INDEX idx_blocked_contacts_blocked_id ON blocked_contacts (blocked_contact_id, user_id);

-- conversations
CREATE INDEX idx_conversations_created_by ON conversations (created_by);

-- Recently active conversations
CREATE INDEX idx_conversations_updated_at ON conversations (updated_at DESC);

-- Group search by title (direct chats have no title)
CREATE INDEX idx_conversations_title_trgm ON conversations
    USING GIN (title gin_trgm_ops)
    WHERE type = 'group';

-- conversation_members   (PK (conversation_id, user_id) covers
--                         "members of a conversation")
-- "Conversations a user belongs to"
CREATE INDEX idx_conv_members_user ON conversation_members (user_id, conversation_id);

-- Permission checks: owners/admins of a conversation (small partial index)
CREATE INDEX idx_conv_members_admins ON conversation_members (conversation_id, user_id)
    WHERE role IN ('owner', 'admin');

-- messages
-- Main chat view: keyset pagination of a conversation's live messages
--   WHERE conversation_id = ? AND (created_at, message_id) < (?, ?)
--   ORDER BY created_at DESC, message_id DESC
CREATE INDEX idx_messages_conv_timeline ON messages (conversation_id, created_at DESC, message_id DESC)
    WHERE deleted_at IS NULL;

-- Same timeline including soft-deleted rows (admin / audit / "message deleted" placeholders)
CREATE INDEX idx_messages_conv_all ON messages (conversation_id, created_at DESC);

-- "Messages sent by a user" (profile history, moderation)
CREATE INDEX idx_messages_sender_created ON messages (sender_id, created_at DESC);

-- Thread / reply lookup (only rows that actually are replies)
CREATE INDEX idx_messages_reply_to ON messages (reply_to_message_id)
    WHERE reply_to_message_id IS NOT NULL;

-- Full-text search inside message content
CREATE INDEX idx_messages_content_fts ON messages
    USING GIN (TO_TSVECTOR('english', content))
    WHERE deleted_at IS NULL;

-- message_receipts   (PK (message_id, recipient_id) covers
--                     "receipts for a message")

-- Unread / undelivered work queue per recipient (tiny partial index:
-- rows drop out of it as soon as they are marked read)
CREATE INDEX idx_receipts_recipient_unread ON message_receipts (recipient_id, message_id)
    WHERE status <> 'read';

-- Receipts of a recipient by status (read-history, delivery stats)
CREATE INDEX idx_receipts_recipient_status ON message_receipts (recipient_id, status);
    