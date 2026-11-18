-- Params  : $1, $2, ... are positional parameters for prepared statements
-- Joins   : existence checks are written as JOINs (LEFT JOIN ... IS NULL for
--           "must not exist", INNER JOIN / UPDATE..FROM / DELETE..USING for
--           "must exist") instead of EXISTS / IN subqueries
-- Index   : "uses:" comments name the index from schema.sql that serves the query
-- =====================================================================

-- =====================================================================
-- 1. USERS & AUTH
-- =====================================================================

-- 1.1 Register user + empty profile in one statement
-- WRITE
-- $1 username, $2 email, $3 password_hash, $4 display_name
WITH new_user AS (
    INSERT INTO users (username, email, password_hash)
    VALUES ($1, $2, $3)
    RETURNING user_id
)
INSERT INTO user_profiles (user_id, display_name)
SELECT nu.user_id, $4
FROM new_user nu
RETURNING user_id;

-- 1.2 Login by email  (uses: uq_users_email_lower)
-- READ
-- $1 email
SELECT user_id, username, password_hash, active_status
FROM users
WHERE LOWER(email) = LOWER($1);

-- 1.3 Login by username  (uses: uq_users_username_lower)
-- READ
-- $1 username
SELECT user_id, username, password_hash, active_status
FROM users
WHERE LOWER(username) = LOWER($1);

-- 1.4 Check username / email availability
-- READ
-- $1 username, $2 email
SELECT u1.user_id IS NOT NULL AS username_taken,
       u2.user_id IS NOT NULL AS email_taken
FROM (SELECT 1) AS d
LEFT JOIN users u1 ON LOWER(u1.username) = LOWER($1)
LEFT JOIN users u2 ON LOWER(u2.email)    = LOWER($2);

-- 1.5 Get user by id (with profile)
-- READ
-- $1 user_id
SELECT u.user_id, u.username, u.email, u.active_status, u.created_at,
       p.display_name, p.about, p.avatar_url
FROM users u
LEFT JOIN user_profiles p ON p.user_id = u.user_id
WHERE u.user_id = $1;

-- 1.6 Public profile by username (no email / hash exposed)
-- READ
-- $1 username
SELECT u.user_id, u.username, p.display_name, p.about, p.avatar_url
FROM users u
LEFT JOIN user_profiles p ON p.user_id = u.user_id
WHERE LOWER(u.username) = LOWER($1) AND u.active_status = TRUE;

-- 1.7 Change password
-- WRITE
-- $1 user_id, $2 new_password_hash
UPDATE users SET password_hash = $2 WHERE user_id = $1;

-- 1.8 Change username / email (NULL keeps the current value)
-- WRITE
-- $1 user_id, $2 new_username, $3 new_email
UPDATE users
SET username = COALESCE($2, username),
    email    = COALESCE($3, email)
WHERE user_id = $1
RETURNING user_id, username, email;

-- 1.9 Deactivate account (soft delete; hard delete is blocked by
--     ON DELETE RESTRICT on messages / conversations)
-- WRITE
-- $1 user_id
UPDATE users SET active_status = FALSE WHERE user_id = $1;

-- 1.10 Reactivate account
-- WRITE
-- $1 user_id
UPDATE users SET active_status = TRUE WHERE user_id = $1;

-- 1.11 Search users by username / display name, hiding users who blocked me
--      (uses: idx_users_username_trgm, idx_user_profiles_display_name_trgm)
-- READ
-- $1 search text, $2 current_user_id, $3 limit
SELECT u.user_id, u.username, p.display_name, p.avatar_url
FROM users u
LEFT JOIN user_profiles p    ON p.user_id = u.user_id
LEFT JOIN blocked_contacts b ON b.user_id = u.user_id
                            AND b.blocked_contact_id = $2
WHERE u.active_status = TRUE
  AND u.user_id <> $2
  AND b.user_id IS NULL
  AND (u.username ILIKE '%' || $1 || '%' OR p.display_name ILIKE '%' || $1 || '%')
ORDER BY u.username
LIMIT $3;

-- 1.12 Newest active users  (uses: idx_users_active_created)
-- READ
-- $1 limit
SELECT user_id, username, created_at
FROM users
WHERE active_status = TRUE
ORDER BY created_at DESC
LIMIT $1;

-- =====================================================================
-- 2. USER PROFILES
-- =====================================================================

-- 2.1 Upsert profile (NULL keeps the existing value)
-- WRITE
-- $1 user_id, $2 display_name, $3 about, $4 avatar_url
INSERT INTO user_profiles (user_id, display_name, about, avatar_url)
VALUES ($1, $2, $3, $4)
ON CONFLICT (user_id) DO UPDATE
SET display_name = COALESCE(EXCLUDED.display_name, user_profiles.display_name),
    about        = COALESCE(EXCLUDED.about,        user_profiles.about),
    avatar_url   = COALESCE(EXCLUDED.avatar_url,   user_profiles.avatar_url)
RETURNING *;

-- 2.2 Remove avatar
-- WRITE
-- $1 user_id
UPDATE user_profiles SET avatar_url = NULL WHERE user_id = $1;

-- =====================================================================
-- 3. CONTACTS
-- =====================================================================

-- 3.1 Add contact (idempotent; refused if either side has blocked the other)
-- WRITE
-- $1 user_id, $2 contact_id
INSERT INTO contacts (user_id, contact_id)
SELECT p.uid, p.cid
FROM (SELECT $1::BIGINT AS uid, $2::BIGINT AS cid) AS p
LEFT JOIN blocked_contacts b
       ON (b.user_id = p.uid AND b.blocked_contact_id = p.cid)
       OR (b.user_id = p.cid AND b.blocked_contact_id = p.uid)
WHERE b.user_id IS NULL
ON CONFLICT DO NOTHING;

-- 3.2 Remove contact
-- WRITE
-- $1 user_id, $2 contact_id
DELETE FROM contacts WHERE user_id = $1 AND contact_id = $2;

-- 3.3 List my contacts with profile  (uses: contacts PK)
-- READ
-- $1 user_id
SELECT c.contact_id AS user_id, u.username, p.display_name, p.avatar_url,
       u.active_status, c.created_at AS added_at
FROM contacts c
JOIN users u              ON u.user_id = c.contact_id
LEFT JOIN user_profiles p ON p.user_id = c.contact_id
WHERE c.user_id = $1
ORDER BY COALESCE(p.display_name, u.username);

-- 3.4 Is X in my contacts?
-- READ
-- $1 user_id, $2 contact_id
SELECT c.user_id IS NOT NULL AS is_contact
FROM (SELECT 1) AS d
LEFT JOIN contacts c ON c.user_id = $1 AND c.contact_id = $2;

-- 3.5 Who has added me  (uses: idx_contacts_contact_id)
-- READ
-- $1 user_id
SELECT c.user_id, u.username, p.display_name
FROM contacts c
JOIN users u              ON u.user_id = c.user_id
LEFT JOIN user_profiles p ON p.user_id = c.user_id
WHERE c.contact_id = $1;

-- 3.6 Mutual contacts between two users
-- READ
-- $1 user_a, $2 user_b
SELECT a.contact_id AS user_id, u.username
FROM contacts a
JOIN contacts b ON b.contact_id = a.contact_id AND b.user_id = $2
JOIN users u    ON u.user_id = a.contact_id
WHERE a.user_id = $1;

-- 3.7 "People you may know": contacts of my contacts, not yet mine, not blocked
-- READ
-- $1 user_id, $2 limit
SELECT c2.contact_id AS user_id, u.username, COUNT(*) AS mutual_count
FROM contacts c1
JOIN contacts c2             ON c2.user_id = c1.contact_id
JOIN users u                 ON u.user_id = c2.contact_id AND u.active_status = TRUE
LEFT JOIN contacts already   ON already.user_id = $1 AND already.contact_id = c2.contact_id
LEFT JOIN blocked_contacts b ON (b.user_id = $1 AND b.blocked_contact_id = c2.contact_id)
                             OR (b.user_id = c2.contact_id AND b.blocked_contact_id = $1)
WHERE c1.user_id = $1
  AND c2.contact_id <> $1
  AND already.user_id IS NULL
  AND b.user_id IS NULL
GROUP BY c2.contact_id, u.username
ORDER BY mutual_count DESC
LIMIT $2;

-- 3.8 Contact count
-- READ
-- $1 user_id
SELECT COUNT(*) AS contact_count FROM contacts WHERE user_id = $1;

-- =====================================================================
-- 4. BLOCKING
-- =====================================================================

-- 4.1 Block user, and drop any contact link in both directions (one statement)
-- WRITE
-- $1 user_id, $2 blocked_contact_id
WITH new_block AS (
    INSERT INTO blocked_contacts (user_id, blocked_contact_id)
    VALUES ($1, $2)
    ON CONFLICT DO NOTHING
    RETURNING user_id
)
DELETE FROM contacts
WHERE (user_id = $1 AND contact_id = $2)
   OR (user_id = $2 AND contact_id = $1);

-- 4.2 Unblock user
-- WRITE
-- $1 user_id, $2 blocked_contact_id
DELETE FROM blocked_contacts WHERE user_id = $1 AND blocked_contact_id = $2;

-- 4.3 List users I blocked
-- READ
-- $1 user_id
SELECT b.blocked_contact_id AS user_id, u.username, p.display_name, b.created_at
FROM blocked_contacts b
JOIN users u              ON u.user_id = b.blocked_contact_id
LEFT JOIN user_profiles p ON p.user_id = b.blocked_contact_id
WHERE b.user_id = $1
ORDER BY b.created_at DESC;

-- 4.4 Is there a block in either direction?
--     (uses: blocked_contacts PK + idx_blocked_contacts_blocked_id)
-- READ
-- $1 user_a, $2 user_b
SELECT COUNT(*) > 0 AS is_blocked
FROM blocked_contacts
WHERE (user_id = $1 AND blocked_contact_id = $2)
   OR (user_id = $2 AND blocked_contact_id = $1);

-- 4.5 Who has blocked me (abuse analysis)
-- READ
-- $1 user_id
SELECT b.user_id AS blocked_by, u.username, b.created_at
FROM blocked_contacts b
JOIN users u ON u.user_id = b.user_id
WHERE b.blocked_contact_id = $1;

-- =====================================================================
-- 5. CONVERSATIONS
-- =====================================================================

-- 5.1 Find existing direct conversation between two users
-- READ
-- $1 user_a, $2 user_b
SELECT c.conversation_id
FROM conversations c
JOIN conversation_members m1 ON m1.conversation_id = c.conversation_id AND m1.user_id = $1
JOIN conversation_members m2 ON m2.conversation_id = c.conversation_id AND m2.user_id = $2
WHERE c.type = 'direct'
LIMIT 1;

-- 5.2 Create direct conversation with both members
--     (run 4.4 first to refuse if blocked, and 5.1 to avoid duplicates)
-- WRITE
-- $1 creator_id, $2 other_user_id
WITH conv AS (
    INSERT INTO conversations (type, created_by)
    VALUES ('direct', $1)
    RETURNING conversation_id
)
INSERT INTO conversation_members (conversation_id, user_id, role)
SELECT conv.conversation_id, u.id, 'member'
FROM conv
CROSS JOIN UNNEST(ARRAY[$1, $2]::BIGINT[]) AS u(id)
RETURNING conversation_id, user_id;

-- 5.3 Create group conversation; creator becomes owner
-- WRITE
-- $1 creator_id, $2 title, $3 member_ids BIGINT[]
WITH conv AS (
    INSERT INTO conversations (type, title, created_by)
    VALUES ('group', $2, $1)
    RETURNING conversation_id
)
INSERT INTO conversation_members (conversation_id, user_id, role)
SELECT conv.conversation_id, m.id, CASE WHEN m.id = $1 THEN 'owner' ELSE 'member' END
FROM conv
CROSS JOIN (SELECT DISTINCT UNNEST(ARRAY[$1]::BIGINT[] || $3::BIGINT[]) AS id) AS m
RETURNING conversation_id, user_id, role;

-- 5.4 Rename group (acting user must be owner / admin)
-- WRITE
-- $1 conversation_id, $2 new_title, $3 acting_user_id
UPDATE conversations c
SET title = $2
FROM conversation_members m
WHERE c.conversation_id = $1
  AND c.type = 'group'
  AND m.conversation_id = c.conversation_id
  AND m.user_id = $3
  AND m.role IN ('owner', 'admin')
RETURNING c.conversation_id, c.title;

-- 5.5 INBOX: my conversations with last message, unread count and, for direct
--     chats, the counterpart's name; newest activity first
--     (uses: idx_conv_members_user, idx_messages_conv_timeline,
--            idx_receipts_recipient_unread)
-- READ
-- $1 user_id, $2 limit, $3 offset
SELECT c.conversation_id,
       c.type,
       COALESCE(c.title, other.display_name, other.username) AS name,
       other.avatar_url,
       lm.message_id           AS last_message_id,
       lm.content              AS last_message,
       lm.sender_id            AS last_sender_id,
       lm.created_at           AS last_message_at,
       COALESCE(unread.cnt, 0) AS unread_count
FROM conversation_members me
JOIN conversations c ON c.conversation_id = me.conversation_id
LEFT JOIN LATERAL (
    SELECT m.message_id, m.content, m.sender_id, m.created_at
    FROM messages m
    WHERE m.conversation_id = c.conversation_id AND m.deleted_at IS NULL
    ORDER BY m.created_at DESC, m.message_id DESC
    LIMIT 1
) lm ON TRUE
LEFT JOIN LATERAL (
    SELECT COUNT(*) AS cnt
    FROM message_receipts r
    JOIN messages m ON m.message_id = r.message_id
    WHERE r.recipient_id = $1
      AND r.status <> 'read'
      AND m.conversation_id = c.conversation_id
      AND m.deleted_at IS NULL
) unread ON TRUE
LEFT JOIN LATERAL (
    SELECT u.username, p.display_name, p.avatar_url
    FROM conversation_members om
    JOIN users u              ON u.user_id = om.user_id
    LEFT JOIN user_profiles p ON p.user_id = om.user_id
    WHERE c.type = 'direct'
      AND om.conversation_id = c.conversation_id
      AND om.user_id <> $1
    LIMIT 1
) other ON TRUE
WHERE me.user_id = $1
ORDER BY COALESCE(lm.created_at, c.created_at) DESC
LIMIT $2 OFFSET $3;

-- 5.6 Conversation details + member count (only if requester is a member)
-- READ
-- $1 conversation_id, $2 requesting_user_id
SELECT c.conversation_id, c.type, c.title, c.created_by, c.created_at,
       COUNT(m.user_id) AS member_count
FROM conversations c
JOIN conversation_members me ON me.conversation_id = c.conversation_id AND me.user_id = $2
JOIN conversation_members m  ON m.conversation_id  = c.conversation_id
WHERE c.conversation_id = $1
GROUP BY c.conversation_id;

-- 5.7 Search my group chats by title  (uses: idx_conversations_title_trgm)
-- READ
-- $1 search text, $2 user_id
SELECT c.conversation_id, c.title
FROM conversations c
JOIN conversation_members m ON m.conversation_id = c.conversation_id AND m.user_id = $2
WHERE c.type = 'group' AND c.title ILIKE '%' || $1 || '%';

-- 5.8 Delete conversation (cascades to members, messages, receipts); owner only
-- WRITE
-- $1 conversation_id, $2 acting_user_id
DELETE FROM conversations c
USING conversation_members m
WHERE c.conversation_id = $1
  AND m.conversation_id = c.conversation_id
  AND m.user_id = $2
  AND m.role = 'owner';

-- 5.9 Clean up groups left with no members
-- WRITE
DELETE FROM conversations
WHERE conversation_id IN (
    SELECT c.conversation_id
    FROM conversations c
    LEFT JOIN conversation_members m ON m.conversation_id = c.conversation_id
    WHERE c.type = 'group' AND m.user_id IS NULL
);

-- =====================================================================
-- 6. CONVERSATION MEMBERS
-- =====================================================================

-- 6.1 Add member (actor must be owner/admin; neither side may have blocked the other)
-- WRITE
-- $1 conversation_id, $2 new_user_id, $3 acting_user_id
INSERT INTO conversation_members (conversation_id, user_id)
SELECT actor.conversation_id, $2::BIGINT
FROM conversation_members actor
LEFT JOIN blocked_contacts b
       ON (b.user_id = actor.user_id AND b.blocked_contact_id = $2::BIGINT)
       OR (b.user_id = $2::BIGINT    AND b.blocked_contact_id = actor.user_id)
WHERE actor.conversation_id = $1
  AND actor.user_id = $3
  AND actor.role IN ('owner', 'admin')
  AND b.user_id IS NULL
ON CONFLICT DO NOTHING
RETURNING *;

-- 6.2 Remove member / kick (owner/admin only; the owner cannot be removed)
-- WRITE
-- $1 conversation_id, $2 target_user_id, $3 acting_user_id
DELETE FROM conversation_members t
USING conversation_members actor
WHERE t.conversation_id = $1
  AND t.user_id = $2
  AND t.role <> 'owner'
  AND actor.conversation_id = t.conversation_id
  AND actor.user_id = $3
  AND actor.role IN ('owner', 'admin');

-- 6.3 Leave conversation
-- WRITE
-- $1 conversation_id, $2 user_id
DELETE FROM conversation_members WHERE conversation_id = $1 AND user_id = $2;

-- 6.4 Change member role (owner only)
-- WRITE
-- $1 conversation_id, $2 target_user_id, $3 new_role, $4 acting_user_id
UPDATE conversation_members t
SET role = $3
FROM conversation_members actor
WHERE t.conversation_id = $1
  AND t.user_id = $2
  AND $3 IN ('admin', 'member')
  AND actor.conversation_id = t.conversation_id
  AND actor.user_id = $4
  AND actor.role = 'owner'
RETURNING t.*;

-- 6.5 Transfer ownership; old owner becomes admin (one statement)
-- WRITE
-- $1 conversation_id, $2 old_owner_id, $3 new_owner_id
UPDATE conversation_members
SET role = CASE user_id WHEN $2 THEN 'admin' WHEN $3 THEN 'owner' END
WHERE conversation_id = $1 AND user_id IN ($2, $3);

-- 6.6 List members with profiles
-- READ
-- $1 conversation_id
SELECT m.user_id, u.username, p.display_name, p.avatar_url, m.role, m.joined_at
FROM conversation_members m
JOIN users u              ON u.user_id = m.user_id
LEFT JOIN user_profiles p ON p.user_id = m.user_id
WHERE m.conversation_id = $1
ORDER BY CASE m.role WHEN 'owner' THEN 0 WHEN 'admin' THEN 1 ELSE 2 END, m.joined_at;

-- 6.7 Is user a member? (call before every read / write to a conversation)
-- READ
-- $1 conversation_id, $2 user_id
SELECT COUNT(*) > 0 AS is_member
FROM conversation_members
WHERE conversation_id = $1 AND user_id = $2;

-- 6.8 Owners / admins of a conversation  (uses: idx_conv_members_admins)
-- READ
-- $1 conversation_id
SELECT m.user_id, u.username, m.role
FROM conversation_members m
JOIN users u ON u.user_id = m.user_id
WHERE m.conversation_id = $1 AND m.role IN ('owner', 'admin');

-- =====================================================================
-- 7. MESSAGES
-- =====================================================================

-- 7.1 Send message: inserts the message, one receipt per other member, and
--     bumps the conversation, atomically. Inserts nothing if the sender is not a
--     member, or if the reply target belongs to another conversation.
-- WRITE
-- $1 conversation_id, $2 sender_id, $3 content, $4 reply_to_message_id (nullable)
WITH new_msg AS (
    INSERT INTO messages (conversation_id, sender_id, content, reply_to_message_id)
    SELECT cm.conversation_id, cm.user_id, $3::TEXT, $4::BIGINT
    FROM conversation_members cm
    LEFT JOIN messages parent ON parent.message_id = $4::BIGINT
    WHERE cm.conversation_id = $1
      AND cm.user_id = $2
      AND ($4::BIGINT IS NULL OR parent.conversation_id = cm.conversation_id)
    RETURNING message_id, conversation_id, sender_id, content, reply_to_message_id, created_at
),
new_receipts AS (
    INSERT INTO message_receipts (message_id, recipient_id)
    SELECT nm.message_id, cm.user_id
    FROM new_msg nm
    JOIN conversation_members cm ON cm.conversation_id = nm.conversation_id
                                AND cm.user_id <> nm.sender_id
    RETURNING message_id
),
touch AS (
    UPDATE conversations c
    SET updated_at = NOW()
    FROM new_msg nm
    WHERE c.conversation_id = nm.conversation_id
    RETURNING c.conversation_id
)
SELECT * FROM new_msg;

-- 7.2 Chat history, FIRST PAGE (latest messages)  (uses: idx_messages_conv_timeline)
-- READ
-- $1 conversation_id, $2 page_size
SELECT m.message_id, m.sender_id, u.username, m.content, m.created_at,
       m.edited_at, m.reply_to_message_id
FROM messages m
JOIN users u ON u.user_id = m.sender_id
WHERE m.conversation_id = $1 AND m.deleted_at IS NULL
ORDER BY m.created_at DESC, m.message_id DESC
LIMIT $2;

-- 7.3 Chat history, OLDER than cursor (infinite scroll up; keyset pagination)
-- READ
-- $1 conversation_id, $2 cursor_created_at, $3 cursor_message_id, $4 page_size
SELECT m.message_id, m.sender_id, u.username, m.content, m.created_at,
       m.edited_at, m.reply_to_message_id
FROM messages m
JOIN users u ON u.user_id = m.sender_id
WHERE m.conversation_id = $1
  AND m.deleted_at IS NULL
  AND (m.created_at, m.message_id) < ($2, $3)
ORDER BY m.created_at DESC, m.message_id DESC
LIMIT $4;

-- 7.4 NEWER than a message (sync after reconnect / polling)
-- READ
-- $1 conversation_id, $2 last_seen_message_id
SELECT m.message_id, m.sender_id, u.username, m.content, m.created_at,
       m.edited_at, m.deleted_at, m.reply_to_message_id
FROM messages m
JOIN users u ON u.user_id = m.sender_id
WHERE m.conversation_id = $1 AND m.message_id > $2
ORDER BY m.message_id;

-- 7.5 Single message with quoted reply preview
-- READ
-- $1 message_id
SELECT m.message_id, m.conversation_id, m.sender_id, m.content, m.created_at,
       m.edited_at, m.deleted_at,
       r.message_id AS reply_id,
       r.sender_id  AS reply_sender_id,
       CASE WHEN r.deleted_at IS NULL THEN LEFT(r.content, 100) END AS reply_preview
FROM messages m
LEFT JOIN messages r ON r.message_id = m.reply_to_message_id
WHERE m.message_id = $1;

-- 7.6 Replies to a message (thread)  (uses: idx_messages_reply_to)
-- READ
-- $1 message_id
SELECT m.message_id, m.sender_id, u.username, m.content, m.created_at
FROM messages m
JOIN users u ON u.user_id = m.sender_id
WHERE m.reply_to_message_id = $1 AND m.deleted_at IS NULL
ORDER BY m.created_at;

-- 7.7 Edit message (sender only, not deleted)
-- WRITE
-- $1 message_id, $2 sender_id, $3 new_content
UPDATE messages
SET content = $3, edited_at = NOW()
WHERE message_id = $1 AND sender_id = $2 AND deleted_at IS NULL
RETURNING message_id, content, edited_at;

-- 7.8 Delete message (soft delete, sender only)
-- WRITE
-- $1 message_id, $2 sender_id
UPDATE messages
SET deleted_at = NOW()
WHERE message_id = $1 AND sender_id = $2 AND deleted_at IS NULL
RETURNING message_id, deleted_at;

-- 7.9 Full-text search inside ONE conversation (requester must be a member)
--     (uses: idx_messages_content_fts)
-- READ
-- $1 conversation_id, $2 search text, $3 user_id, $4 limit
SELECT m.message_id, m.sender_id, m.created_at,
       TS_HEADLINE('english', m.content, WEBSEARCH_TO_TSQUERY('english', $2)) AS snippet,
       TS_RANK(TO_TSVECTOR('english', m.content), WEBSEARCH_TO_TSQUERY('english', $2)) AS rank
FROM messages m
JOIN conversation_members cm ON cm.conversation_id = m.conversation_id AND cm.user_id = $3
WHERE m.conversation_id = $1
  AND m.deleted_at IS NULL
  AND TO_TSVECTOR('english', m.content) @@ WEBSEARCH_TO_TSQUERY('english', $2)
ORDER BY rank DESC, m.created_at DESC
LIMIT $4;

-- 7.10 Full-text search across ALL my conversations
-- READ
-- $1 user_id, $2 search text, $3 limit
SELECT m.message_id, m.conversation_id, c.title, m.sender_id, m.created_at,
       TS_HEADLINE('english', m.content, WEBSEARCH_TO_TSQUERY('english', $2)) AS snippet
FROM conversation_members cm
JOIN messages m      ON m.conversation_id = cm.conversation_id
JOIN conversations c ON c.conversation_id = m.conversation_id
WHERE cm.user_id = $1
  AND m.deleted_at IS NULL
  AND TO_TSVECTOR('english', m.content) @@ WEBSEARCH_TO_TSQUERY('english', $2)
ORDER BY m.created_at DESC
LIMIT $3;

-- 7.11 Messages sent by a user  (uses: idx_messages_sender_created)
-- READ
-- $1 sender_id, $2 limit
SELECT m.message_id, m.conversation_id, c.title, m.content, m.created_at
FROM messages m
JOIN conversations c ON c.conversation_id = m.conversation_id
WHERE m.sender_id = $1 AND m.deleted_at IS NULL
ORDER BY m.created_at DESC
LIMIT $2;

-- 7.12 Message count in a conversation
-- READ
-- $1 conversation_id
SELECT COUNT(*) AS message_count
FROM messages
WHERE conversation_id = $1 AND deleted_at IS NULL;

-- 7.13 Permanently purge messages soft-deleted over 30 days ago (scheduled job)
-- WRITE
DELETE FROM messages
WHERE deleted_at IS NOT NULL AND deleted_at < NOW() - INTERVAL '30 days';

-- =====================================================================
-- 8. MESSAGE RECEIPTS (delivered / read)
-- =====================================================================

-- 8.1 Mark everything pending for a user as DELIVERED (user comes online)
-- WRITE
-- $1 recipient_id
UPDATE message_receipts
SET status = 'delivered', delivered_at = NOW()
WHERE recipient_id = $1 AND status = 'sent';

-- 8.2 Mark one message delivered
-- WRITE
-- $1 message_id, $2 recipient_id
UPDATE message_receipts
SET status = 'delivered', delivered_at = NOW()
WHERE message_id = $1 AND recipient_id = $2 AND status = 'sent';

-- 8.3 Mark a conversation READ up to a message (user opened the chat)
--     (uses: idx_receipts_recipient_unread)
-- WRITE
-- $1 recipient_id, $2 conversation_id, $3 up_to_message_id
UPDATE message_receipts r
SET status       = 'read',
    read_at      = NOW(),
    delivered_at = COALESCE(r.delivered_at, NOW())
FROM messages m
WHERE r.message_id   = m.message_id
  AND r.recipient_id = $1
  AND r.status      <> 'read'
  AND m.conversation_id = $2
  AND m.message_id  <= $3;

-- 8.4 Who has received / read a given message (sender's "seen by" view)
-- READ
-- $1 message_id
SELECT r.recipient_id, u.username, r.status, r.delivered_at, r.read_at
FROM message_receipts r
JOIN users u ON u.user_id = r.recipient_id
WHERE r.message_id = $1
ORDER BY r.read_at NULLS LAST, u.username;

-- 8.5 Overall status of a message for its sender (single / double / blue tick)
-- READ
-- $1 message_id
SELECT CASE
         WHEN COUNT(*) FILTER (WHERE status = 'read') = COUNT(*)                 THEN 'read'
         WHEN COUNT(*) FILTER (WHERE status IN ('delivered', 'read')) = COUNT(*) THEN 'delivered'
         ELSE 'sent'
       END AS overall_status,
       COUNT(*) FILTER (WHERE status = 'read')      AS read_count,
       COUNT(*) FILTER (WHERE status = 'delivered') AS delivered_count,
       COUNT(*)                                     AS total_recipients
FROM message_receipts
WHERE message_id = $1;

-- 8.6 Unread count per conversation (badge numbers)
-- READ
-- $1 recipient_id
SELECT m.conversation_id, c.title, COUNT(*) AS unread_count
FROM message_receipts r
JOIN messages m      ON m.message_id = r.message_id
JOIN conversations c ON c.conversation_id = m.conversation_id
WHERE r.recipient_id = $1 AND r.status <> 'read' AND m.deleted_at IS NULL
GROUP BY m.conversation_id, c.title;

-- 8.7 Total unread count (app icon badge)
-- READ
-- $1 recipient_id
SELECT COUNT(*) AS total_unread
FROM message_receipts r
JOIN messages m ON m.message_id = r.message_id
WHERE r.recipient_id = $1 AND r.status <> 'read' AND m.deleted_at IS NULL;

-- 8.8 Undelivered messages to push when a user reconnects
-- READ
-- $1 recipient_id
SELECT m.message_id, m.conversation_id, m.sender_id, u.username AS sender_name,
       m.content, m.created_at
FROM message_receipts r
JOIN messages m ON m.message_id = r.message_id
JOIN users u    ON u.user_id = m.sender_id
WHERE r.recipient_id = $1 AND r.status = 'sent' AND m.deleted_at IS NULL
ORDER BY m.created_at;

-- 8.9 First unread message in a conversation (scroll-to-unread marker)
-- READ
-- $1 recipient_id, $2 conversation_id
SELECT MIN(m.message_id) AS first_unread_message_id
FROM message_receipts r
JOIN messages m ON m.message_id = r.message_id
WHERE r.recipient_id = $1 AND r.status <> 'read'
  AND m.conversation_id = $2 AND m.deleted_at IS NULL;

-- =====================================================================
-- 9. ADMIN / ANALYTICS / MAINTENANCE
-- =====================================================================

-- 9.1 Messages per day, last 30 days
-- READ
SELECT DATE_TRUNC('day', created_at)::DATE AS day, COUNT(*) AS messages
FROM messages
WHERE created_at >= NOW() - INTERVAL '30 days'
GROUP BY 1
ORDER BY 1;

-- 9.2 Top 10 most active senders, last 7 days
-- READ
SELECT u.user_id, u.username, COUNT(*) AS messages_sent
FROM messages m
JOIN users u ON u.user_id = m.sender_id
WHERE m.created_at >= NOW() - INTERVAL '7 days'
GROUP BY u.user_id, u.username
ORDER BY messages_sent DESC
LIMIT 10;

-- 9.3 Daily active users (users who sent at least one message)
-- READ
SELECT DATE_TRUNC('day', created_at)::DATE AS day, COUNT(DISTINCT sender_id) AS dau
FROM messages
WHERE created_at >= NOW() - INTERVAL '30 days'
GROUP BY 1
ORDER BY 1;

-- 9.4 Largest conversations by member count
-- READ
SELECT c.conversation_id, c.title, COUNT(*) AS members
FROM conversations c
JOIN conversation_members m ON m.conversation_id = c.conversation_id
GROUP BY c.conversation_id, c.title
ORDER BY members DESC
LIMIT 10;

-- 9.5 Busiest conversations, last 24 hours
-- READ
SELECT m.conversation_id, c.title, COUNT(*) AS messages
FROM messages m
JOIN conversations c ON c.conversation_id = m.conversation_id
WHERE m.created_at >= NOW() - INTERVAL '24 hours'
GROUP BY m.conversation_id, c.title
ORDER BY messages DESC
LIMIT 10;

-- 9.6 Users who never sent a message
-- READ
SELECT u.user_id, u.username, u.created_at
FROM users u
LEFT JOIN messages m ON m.sender_id = u.user_id
WHERE m.message_id IS NULL;

-- 9.7 Users with no conversations
-- READ
SELECT u.user_id, u.username
FROM users u
LEFT JOIN conversation_members cm ON cm.user_id = u.user_id
WHERE cm.conversation_id IS NULL;

-- 9.8 Average time from delivery to read (minutes), last 7 days
-- READ
SELECT ROUND(AVG(EXTRACT(EPOCH FROM (read_at - delivered_at)) / 60)::NUMERIC, 2) AS avg_minutes_to_read
FROM message_receipts
WHERE read_at IS NOT NULL
  AND delivered_at IS NOT NULL
  AND read_at >= NOW() - INTERVAL '7 days';

-- 9.9 Most blocked users (abuse signal)
-- READ
SELECT b.blocked_contact_id AS user_id, u.username, COUNT(*) AS times_blocked
FROM blocked_contacts b
JOIN users u ON u.user_id = b.blocked_contact_id
GROUP BY b.blocked_contact_id, u.username
ORDER BY times_blocked DESC
LIMIT 10;

-- 9.10 Edit / delete ratio per user
-- READ
SELECT sender_id,
       COUNT(*)                                       AS total,
       COUNT(*) FILTER (WHERE edited_at  IS NOT NULL) AS edited,
       COUNT(*) FILTER (WHERE deleted_at IS NOT NULL) AS deleted
FROM messages
GROUP BY sender_id
ORDER BY total DESC;

-- 9.11 Integrity check: members missing a receipt for messages sent after they joined
-- READ
SELECT m.message_id, cm.user_id AS missing_recipient
FROM messages m
JOIN conversation_members cm
  ON cm.conversation_id = m.conversation_id
 AND cm.user_id <> m.sender_id
 AND m.created_at >= cm.joined_at
LEFT JOIN message_receipts r
  ON r.message_id = m.message_id AND r.recipient_id = cm.user_id
WHERE r.message_id IS NULL;

-- 9.12 Refresh planner statistics after bulk loads (maintenance; updates catalog stats)
-- WRITE
ANALYZE users, user_profiles, contacts, blocked_contacts,
        conversations, conversation_members, messages, message_receipts;
