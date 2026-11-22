-- =====================================================================
-- Dwelling — synthetic but realistic dataset
--
-- Fills the schema from 03_schema.sql with plausible messaging-app data:
--   * 2 000 users (a few hundred days old, a handful deactivated)
--   * 1:1 user_profiles with display names, bios and avatars
--   * ~22 000 contact edges, ~1 300 blocks
--   * 1 300 direct + 550 group conversations
--   * ~155 000 messages spread over each conversation's lifetime,
--     ~4 % of them replies, ~5 % edited, ~2 % soft-deleted
--   * ~500 000 message_receipts with delivered / read latencies
--
-- Timestamps are relative to NOW(), so "last 7 days" / "last 30 days"
-- analytics queries always have data to work with.
--
-- Load into an empty schema:
--   psql -v ON_ERROR_STOP=1 -d dwelling -f dbms/seed/synthetic_data.sql
-- =====================================================================
\set ON_ERROR_STOP on
SET client_min_messages = WARNING;
SELECT setseed(0.4242);

BEGIN;

TRUNCATE message_receipts, messages, conversation_members, conversations,
         blocked_contacts, contacts, user_profiles, users
    RESTART IDENTITY CASCADE;

-- ---------------------------------------------------------------------
-- Name material (40 first x 40 last names => varied, readable usernames)
-- ---------------------------------------------------------------------
CREATE TEMP TABLE user_seed AS
SELECT g AS user_id,
       (ARRAY['Aarav','Meera','Rohan','Ananya','Kabir','Ishita','Vivaan','Neha',
              'Arjun','Priya','Dev','Sara','Nikhil','Aditi','Rahul','Tara',
              'Siddharth','Kavya','Manav','Riya','Karan','Pooja','Yash','Sneha',
              'Ankit','Divya','Sameer','Nandini','Omkar','Lavanya','Farhan','Zoya',
              'Harsh','Isha','Nitin','Ayesha','Ayush','Ritu','Varun','Shreya'])[1 + ((g * 7) % 40)] AS fn,
       (ARRAY['Sharma','Patel','Iyer','Nair','Gupta','Reddy','Menon','Kapoor',
              'Joshi','Das','Mehta','Rao','Bose','Verma','Khan','Shah',
              'Pillai','Chauhan','Bhat','Ghosh','Kulkarni','Malhotra','Sethi','Trivedi',
              'Banerjee','Chawla','Desai','Dutta','Goel','Jain','Khanna','Kumar',
              'Mishra','Pandey','Rastogi','Soni','Thakur','Varma','Yadav','Agarwal'])[1 + ((g * 11) % 40)] AS ln
FROM generate_series(1, 2000) AS g;

-- ---------------------------------------------------------------------
-- USERS
-- ---------------------------------------------------------------------
INSERT INTO users (username, email, password_hash, active_status, created_at, updated_at)
SELECT lower(us.fn || '.' || us.ln || us.user_id),
       lower(us.fn || '.' || us.ln || us.user_id)
           || (ARRAY['@example.com','@mail.test','@dwelling.app','@inbox.dev'])[1 + (us.user_id % 4)],
       '$2b$12$' || md5('dwelling-pw-' || us.user_id),
       (us.user_id % 41 <> 0),                                        -- ~2.4 % deactivated
       NOW() - ((random() * 8000)::int * INTERVAL '1 hour'),           -- up to ~11 months old
       NOW()
FROM user_seed us;

-- ---------------------------------------------------------------------
-- USER_PROFILES (one per user)
-- ---------------------------------------------------------------------
INSERT INTO user_profiles (user_id, display_name, about, avatar_url, created_at, updated_at)
SELECT us.user_id,
       us.fn || ' ' || us.ln,
       (ARRAY['Product designer based in Pune.',
              'Backend engineer, mostly PostgreSQL these days.',
              'Coffee, cricket and side projects.',
              'Marketing lead. Usually online after 7pm.',
              'Student at IIT Bombay.',
              'Freelance photographer.',
              'Engineering manager, loves long runs.',
              'Data analyst. Ask me about dashboards.',
              'Building a small cafe with my sister.',
              'Just here for the memes and the group chats.'])[1 + (us.user_id % 10)],
       CASE WHEN us.user_id % 6 <> 0
            THEN 'https://cdn.dwelling.app/avatars/' || us.user_id || '.jpg' END,
       u.created_at,
       u.created_at
FROM user_seed us
JOIN users u ON u.user_id = us.user_id;

-- ---------------------------------------------------------------------
-- CONTACTS (~12 per user, no duplicates, never self)
-- ---------------------------------------------------------------------
INSERT INTO contacts (user_id, contact_id, created_at)
SELECT s.user_id,
       s.contact_id,
       NOW() - ((random() * 7000)::int * INTERVAL '1 hour')
FROM (
    SELECT u.user_id,
           (1 + floor(random() * 2000))::BIGINT AS contact_id
    FROM users u
    CROSS JOIN generate_series(1, 12)
) s
WHERE s.contact_id <> s.user_id
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- BLOCKED_CONTACTS (~1 300 blocks, spread over the last ~8 months)
-- ---------------------------------------------------------------------
INSERT INTO blocked_contacts (user_id, blocked_contact_id, created_at)
SELECT s.user_id,
       s.blocked_contact_id,
       NOW() - ((random() * 6000)::int * INTERVAL '1 hour')
FROM (
    SELECT u.user_id,
           (1 + floor(random() * 2000))::BIGINT AS blocked_contact_id
    FROM users u
) s
WHERE s.blocked_contact_id <> s.user_id
  AND random() < 0.7
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- CONVERSATIONS
--   conv_seed reserves ids up front so member arrays and the conversation
--   rows stay linked without a round trip.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE conv_seed (
    conversation_id BIGINT,
    type            TEXT,
    title           TEXT,
    created_by      BIGINT,
    created_at      TIMESTAMPTZ,
    member_ids      BIGINT[],
    members         BIGINT[]
);

-- 1 300 direct chats: one per distinct contact pair
INSERT INTO conv_seed (conversation_id, type, title, created_by, created_at, member_ids)
SELECT nextval(pg_get_serial_sequence('conversations', 'conversation_id')::regclass),
       'direct', NULL, p.a, NOW() - ((random() * 6500)::int * INTERVAL '1 hour'),
       ARRAY[p.a, p.b]
FROM (
    SELECT LEAST(user_id, contact_id) AS a,
           GREATEST(user_id, contact_id) AS b
    FROM (
        SELECT DISTINCT ON (LEAST(user_id, contact_id), GREATEST(user_id, contact_id))
               user_id, contact_id
        FROM contacts
        ORDER BY LEAST(user_id, contact_id), GREATEST(user_id, contact_id), random()
        LIMIT 1300
    ) d
) p;

-- 550 groups: 4-8 members, creator becomes owner
INSERT INTO conv_seed (conversation_id, type, title, created_by, created_at, member_ids)
SELECT nextval(pg_get_serial_sequence('conversations', 'conversation_id')::regclass),
       'group',
       g.title,
       g.owner,
       g.created_at,
       g.member_ids
FROM (
    SELECT (ARRAY['Weekend Trip','Family','Project Falcon','College Friends',
                  'Office Lunch','Book Club','Flatmates','Design Team',
                  'Cricket Squad','Startup Founders','Backend Guild','Diwali Plans',
                  'Trek Group','Dwelling Beta Testers'])[1 + (n % 14)] AS title,
           (1 + floor(random() * 2000))::BIGINT AS owner,
           NOW() - ((random() * 6000)::int * INTERVAL '1 hour') AS created_at,
           ARRAY(
               SELECT DISTINCT (1 + floor(random() * 2000))::BIGINT
               FROM generate_series(1, (4 + floor(random() * 5))::INT)
           ) AS member_ids
    FROM generate_series(1, 550) AS n
) g;

UPDATE conv_seed
SET members = ARRAY(SELECT DISTINCT m FROM unnest(member_ids || created_by) AS m);

INSERT INTO conversations (conversation_id, type, title, created_by, created_at, updated_at)
SELECT conversation_id, type, title, created_by, created_at, created_at
FROM conv_seed;

SELECT setval(pg_get_serial_sequence('conversations', 'conversation_id')::regclass,
              (SELECT MAX(conversation_id) FROM conversations));

INSERT INTO conversation_members (conversation_id, user_id, role, joined_at, updated_at)
SELECT cs.conversation_id,
       m.uid,
       CASE WHEN m.uid = cs.created_by              THEN 'owner'
            WHEN cs.type = 'group' AND m.uid % 17 = 0 THEN 'admin'
            ELSE 'member' END,
       cs.created_at,
       cs.created_at
FROM conv_seed cs
CROSS JOIN LATERAL (
    SELECT DISTINCT u AS uid
    FROM unnest(cs.members) AS u
) m;

-- ---------------------------------------------------------------------
-- MESSAGES
--   Direct chats get ~60 messages, groups ~140. Message timestamps are
--   spread from the conversation's creation to now, skewed towards
--   recent activity (power(random(), 1.6)).
-- ---------------------------------------------------------------------
INSERT INTO messages (conversation_id, sender_id, content, created_at, edited_at, deleted_at)
SELECT m.conversation_id,
       m.sender_id,
       m.content,
       m.created_at,
       CASE WHEN m.r_edit < 0.05
            THEN m.created_at + ((1 + random() * 90)::int * INTERVAL '1 minute') END,
       CASE WHEN m.r_del < 0.02
            THEN LEAST(NOW() - INTERVAL '1 minute',
                       m.created_at + ((1 + random() * 2000)::int * INTERVAL '1 minute')) END
FROM (
    SELECT cs.conversation_id,
           cs.members[1 + floor(random() * array_length(cs.members, 1))::int] AS sender_id,
           (ARRAY['Are we still on for dinner tonight?',
                  'Dinner at eight works for me.',
                  'Sorry, I will be ten minutes late to the meeting.',
                  'The meeting moved to Thursday afternoon.',
                  'Sent you the project files.',
                  'The project deadline is next Friday, right?',
                  'Can you review the deck before the call?',
                  'Thanks, talk soon.',
                  'On my way.',
                  'Let me check and get back to you.',
                  'That sounds good to me.',
                  'Do you have a minute to chat?',
                  'Coffee tomorrow morning?',
                  'I just landed, will call you after baggage claim.',
                  'Happy birthday, hope you have a great day.',
                  'The invoice has been paid.',
                  'Please share the updated schedule.',
                  'The flight is delayed by two hours.',
                  'Let us finalise the budget by Monday.',
                  'Great work on the presentation yesterday.',
                  'Do you want to grab lunch?',
                  'I will send the notes shortly.',
                  'Sorry, I missed your call.',
                  'Can we reschedule to next week?',
                  'Sounds like a plan.',
                  'The client approved the design.',
                  'I am heading home now.',
                  'Please add the venue address to the invite.',
                  'Looks good, ship it.',
                  'Weekend trip planning: who is driving?'])[1 + floor(random() * 30)::int] AS content,
           cs.created_at + (NOW() - cs.created_at) * power(random(), 1.6) AS created_at,
           random() AS r_edit,
           random() AS r_del
    FROM conv_seed cs
    CROSS JOIN LATERAL generate_series(
        1, CASE WHEN cs.type = 'group' THEN 140 ELSE 60 END) AS g
) m;

-- Threads: ~4 % of messages answer an earlier message in the same chat
UPDATE messages m
SET reply_to_message_id = p.prev_id
FROM (
    SELECT x.message_id,
           (SELECT p.message_id
            FROM messages p
            WHERE p.conversation_id = x.conversation_id
              AND p.created_at <= x.created_at
              AND p.deleted_at IS NULL
            ORDER BY p.created_at DESC, p.message_id DESC
            LIMIT 1) AS prev_id
    FROM (
        SELECT message_id, conversation_id, created_at
        FROM messages
        WHERE random() < 0.04
    ) x
) p
WHERE m.message_id = p.message_id
  AND p.prev_id IS NOT NULL;

-- Keep conversation activity in sync with the last message
UPDATE conversations c
SET updated_at = s.last_message_at
FROM (
    SELECT conversation_id, MAX(created_at) AS last_message_at
    FROM messages
    GROUP BY conversation_id
) s
WHERE c.conversation_id = s.conversation_id;

-- ---------------------------------------------------------------------
-- MESSAGE_RECEIPTS (one per other member; ~88 % read, 9 % delivered,
-- 3 % still queued, with realistic delivery / read latencies)
-- ---------------------------------------------------------------------
INSERT INTO message_receipts (message_id, recipient_id, status, delivered_at, read_at)
SELECT r.message_id,
       r.recipient_id,
       r.status,
       CASE WHEN r.status <> 'sent' THEN r.created_at + r.deliver_lag END,
       CASE WHEN r.status = 'read' THEN r.created_at + r.deliver_lag + r.read_lag END
FROM (
    SELECT m.message_id,
           cm.user_id AS recipient_id,
           m.created_at,
           CASE WHEN random() < 0.88 THEN 'read'
                WHEN random() < 0.70 THEN 'delivered'
                ELSE 'sent' END AS status,
           ((random() * 240)::int * INTERVAL '1 second') AS deliver_lag,
           ((random() * 90)::int * INTERVAL '1 minute') AS read_lag
    FROM messages m
    JOIN conversation_members cm
      ON cm.conversation_id = m.conversation_id
     AND cm.user_id <> m.sender_id
) r;

ANALYZE users;
ANALYZE user_profiles;
ANALYZE contacts;
ANALYZE blocked_contacts;
ANALYZE conversations;
ANALYZE conversation_members;
ANALYZE messages;
ANALYZE message_receipts;

COMMIT;

-- Visibility map + statistics for the read queries
VACUUM (ANALYZE) users, user_profiles, contacts, blocked_contacts,
                 conversations, conversation_members, messages, message_receipts;

\echo 'Synthetic dataset loaded.'
