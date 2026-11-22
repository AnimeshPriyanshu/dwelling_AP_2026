# Query Timings — `04_queries.sql`

Each query in [`04_queries.sql`](04_queries.sql) was executed three times
against a local PostgreSQL instance loaded with the synthetic dataset from
[`seed/synthetic_data.sql`](seed/synthetic_data.sql).

**Method**

* Timings are the server-side `Execution Time` reported by
  `EXPLAIN (ANALYZE, BUFFERS)` (milliseconds, planning excluded).
* Every run used a fresh connection; the three runs are consecutive,
  so the data set and cache state are identical.
* Statements ran inside `BEGIN … ROLLBACK`, so `INSERT`/`UPDATE`/`DELETE`
  queries were measured without modifying the data.
* Positional parameters (`$1`, `$2`, …) were bound to real rows
  (existing user / conversation / message ids, real search terms).
* Query `9.12` is a bare `ANALYZE` statement, which cannot be wrapped in
  `EXPLAIN`; its three values are psql client-side latencies (`\timing on`).
* Full plans: [`plans/`](plans/) — one file per query (`q1.1.txt` … `q9.12.txt`).

**Environment**

| Item | Value |
| --- | --- |
| Server | PostgreSQL 18.6 (Postgres.app), local socket, port 55432 |
| Machine | macOS (Apple silicon), local SSD |
| Server settings | PostgreSQL defaults, `shared_buffers = 128MB` |
| Statistics | `ANALYZE` + `VACUUM (ANALYZE)` run after the bulk load |

**Dataset**

| Table | Rows |
| --- | ---: |
| `users` | 2,000 |
| `user_profiles` | 2,000 |
| `contacts` | 23,913 |
| `blocked_contacts` | 1,398 |
| `conversations` | 1,850 |
| `conversation_members` | 6,447 |
| `messages` | 155,000 |
| `message_receipts` | 539,580 |

Timestamps in the dataset are relative to `NOW()`, so the "last 7 days" /
"last 30 days" analytics queries operate on populated ranges.

---

## Results

All values in **milliseconds**.


### 1. Users & Auth

| Query | Description | Run 1 | Run 2 | Run 3 | Average |
| --- | --- | ---: | ---: | ---: | ---: |
| 1.1 | Register user + empty profile in one statement | 0.948 | 0.948 | 0.935 | **0.944** |
| 1.2 | Login by email  (uses: uq_users_email_lower) | 0.015 | 0.017 | 0.015 | **0.016** |
| 1.3 | Login by username  (uses: uq_users_username_lower) | 0.014 | 0.015 | 0.014 | **0.014** |
| 1.4 | Check username / email availability | 0.030 | 0.027 | 0.027 | **0.028** |
| 1.5 | Get user by id (with profile) | 0.031 | 0.034 | 0.031 | **0.032** |
| 1.6 | Public profile by username (no email / hash exposed) | 0.022 | 0.022 | 0.019 | **0.021** |
| 1.7 | Change password | 0.547 | 0.634 | 0.558 | **0.580** |
| 1.8 | Change username / email (NULL keeps the current value) | 0.537 | 0.527 | 0.550 | **0.538** |
| 1.9 | Deactivate account (soft delete; hard delete is blocked by ON DELETE RESTRICT on messages / conversations) | 0.504 | 0.553 | 0.637 | **0.565** |
| 1.10 | Reactivate account | 0.804 | 0.679 | 0.581 | **0.688** |
| 1.11 | Search users by username / display name, hiding users who blocked me (uses: idx_users_username_trgm, idx_user_profiles_display_name_trgm) | 0.833 | 0.823 | 1.858 | **1.171** |
| 1.12 | Newest active users  (uses: idx_users_active_created) | 0.047 | 0.033 | 0.035 | **0.038** |

### 2. User Profiles

| Query | Description | Run 1 | Run 2 | Run 3 | Average |
| --- | --- | ---: | ---: | ---: | ---: |
| 2.1 | Upsert profile (NULL keeps the existing value) | 0.565 | 0.566 | 0.535 | **0.555** |
| 2.2 | Remove avatar | 0.500 | 0.498 | 0.616 | **0.538** |

### 3. Contacts

| Query | Description | Run 1 | Run 2 | Run 3 | Average |
| --- | --- | ---: | ---: | ---: | ---: |
| 3.1 | Add contact (idempotent; refused if either side has blocked the other) | 0.396 | 0.411 | 0.424 | **0.410** |
| 3.2 | Remove contact | 0.069 | 0.068 | 0.075 | **0.071** |
| 3.3 | List my contacts with profile  (uses: contacts PK) | 0.265 | 0.249 | 0.259 | **0.258** |
| 3.4 | Is X in my contacts? | 0.046 | 0.049 | 0.049 | **0.048** |
| 3.5 | Who has added me  (uses: idx_contacts_contact_id) | 0.196 | 0.193 | 0.195 | **0.195** |
| 3.6 | Mutual contacts between two users | 0.045 | 0.042 | 0.043 | **0.043** |
| 3.7 | "People you may know": contacts of my contacts, not yet mine, not blocked | 0.303 | 0.284 | 0.299 | **0.295** |
| 3.8 | Contact count | 0.047 | 0.049 | 0.053 | **0.050** |

### 4. Blocking

| Query | Description | Run 1 | Run 2 | Run 3 | Average |
| --- | --- | ---: | ---: | ---: | ---: |
| 4.1 | Block user, and drop any contact link in both directions (one statement) | 0.450 | 0.408 | 0.380 | **0.413** |
| 4.2 | Unblock user | 0.056 | 0.067 | 0.072 | **0.065** |
| 4.3 | List users I blocked | 0.050 | 0.046 | 0.044 | **0.047** |
| 4.4 | Is there a block in either direction? (uses: blocked_contacts PK + idx_blocked_contacts_blocked_id) | 0.032 | 0.033 | 0.038 | **0.034** |
| 4.5 | Who has blocked me (abuse analysis) | 0.027 | 0.026 | 0.026 | **0.026** |

### 5. Conversations

| Query | Description | Run 1 | Run 2 | Run 3 | Average |
| --- | --- | ---: | ---: | ---: | ---: |
| 5.1 | Find existing direct conversation between two users | 0.038 | 0.034 | 0.038 | **0.037** |
| 5.2 | Create direct conversation with both members (run 4.4 first to refuse if blocked, and 5.1 to avoid duplicates) | 0.688 | 0.699 | 0.625 | **0.671** |
| 5.3 | Create group conversation; creator becomes owner | 1.146 | 1.036 | 1.136 | **1.106** |
| 5.4 | Rename group (acting user must be owner / admin) | 0.492 | 0.549 | 0.649 | **0.563** |
| 5.5 | INBOX: my conversations with last message, unread count and, for direct chats, the counterpart's name; newest activity first (uses: idx_conv_members_user, idx_messages_conv_timeline, idx_receipts_recipient_unread) | 0.750 | 0.729 | 0.879 | **0.786** |
| 5.6 | Conversation details + member count (only if requester is a member) | 0.066 | 0.064 | 0.066 | **0.065** |
| 5.7 | Search my group chats by title  (uses: idx_conversations_title_trgm) | 0.194 | 0.203 | 0.201 | **0.199** |
| 5.8 | Delete conversation (cascades to members, messages, receipts); owner only | 1.299 | 1.471 | 1.317 | **1.362** |
| 5.9 | Clean up groups left with no members | 0.657 | 0.656 | 0.651 | **0.655** |

### 6. Conversation Members

| Query | Description | Run 1 | Run 2 | Run 3 | Average |
| --- | --- | ---: | ---: | ---: | ---: |
| 6.1 | Add member (actor must be owner/admin; neither side may have blocked the other) | 0.499 | 0.536 | 0.551 | **0.529** |
| 6.2 | Remove member / kick (owner/admin only; the owner cannot be removed) | 0.063 | 0.066 | 0.071 | **0.067** |
| 6.3 | Leave conversation | 0.057 | 0.058 | 0.066 | **0.060** |
| 6.4 | Change member role (owner only) | 0.142 | 0.135 | 0.143 | **0.140** |
| 6.5 | Transfer ownership; old owner becomes admin (one statement) | 0.152 | 0.148 | 0.121 | **0.140** |
| 6.6 | List members with profiles | 0.093 | 0.071 | 0.071 | **0.078** |
| 6.7 | Is user a member? (call before every read / write to a conversation) | 0.048 | 0.045 | 0.047 | **0.047** |
| 6.8 | Owners / admins of a conversation  (uses: idx_conv_members_admins) | 0.031 | 0.027 | 0.027 | **0.028** |

### 7. Messages

| Query | Description | Run 1 | Run 2 | Run 3 | Average |
| --- | --- | ---: | ---: | ---: | ---: |
| 7.1 | Send message: inserts the message, one receipt per other member, and bumps the conversation, atomically. Inserts nothing if the sender is not a member, or if the reply target belongs to another conversation. | 1.856 | 1.866 | 1.667 | **1.796** |
| 7.2 | Chat history, FIRST PAGE (latest messages)  (uses: idx_messages_conv_timeline) | 0.080 | 0.069 | 0.071 | **0.073** |
| 7.3 | Chat history, OLDER than cursor (infinite scroll up; keyset pagination) | 0.283 | 0.276 | 0.283 | **0.281** |
| 7.4 | NEWER than a message (sync after reconnect / polling) | 0.313 | 0.310 | 0.313 | **0.312** |
| 7.5 | Single message with quoted reply preview | 0.031 | 0.032 | 0.032 | **0.032** |
| 7.6 | Replies to a message (thread)  (uses: idx_messages_reply_to) | 0.038 | 0.039 | 0.039 | **0.039** |
| 7.7 | Edit message (sender only, not deleted) | 0.675 | 0.640 | 0.656 | **0.657** |
| 7.8 | Delete message (soft delete, sender only) | 0.119 | 0.115 | 0.143 | **0.126** |
| 7.9 | Full-text search inside ONE conversation (requester must be a member) (uses: idx_messages_content_fts) | 0.532 | 0.517 | 0.502 | **0.517** |
| 7.10 | Full-text search across ALL my conversations | 7.169 | 7.146 | 9.208 | **7.841** |
| 7.11 | Messages sent by a user  (uses: idx_messages_sender_created) | 0.073 | 0.072 | 0.075 | **0.073** |
| 7.12 | Message count in a conversation | 0.077 | 0.074 | 0.076 | **0.076** |
| 7.13 | Permanently purge messages soft-deleted over 30 days ago (scheduled job) | 21.643 | 26.045 | 24.694 | **24.127** |

### 8. Message Receipts

| Query | Description | Run 1 | Run 2 | Run 3 | Average |
| --- | --- | ---: | ---: | ---: | ---: |
| 8.1 | Mark everything pending for a user as DELIVERED (user comes online) | 12.152 | 11.336 | 11.862 | **11.783** |
| 8.2 | Mark one message delivered | 0.128 | 0.153 | 0.129 | **0.137** |
| 8.3 | Mark a conversation READ up to a message (user opened the chat) (uses: idx_receipts_recipient_unread) | 0.270 | 0.296 | 0.272 | **0.279** |
| 8.4 | Who has received / read a given message (sender's "seen by" view) | 0.045 | 0.042 | 0.045 | **0.044** |
| 8.5 | Overall status of a message for its sender (single / double / blue tick) | 0.034 | 0.034 | 0.131 | **0.066** |
| 8.6 | Unread count per conversation (badge numbers) | 20.336 | 17.126 | 17.334 | **18.265** |
| 8.7 | Total unread count (app icon badge) | 16.102 | 16.497 | 15.744 | **16.114** |
| 8.8 | Undelivered messages to push when a user reconnects | 15.222 | 14.945 | 15.008 | **15.058** |
| 8.9 | First unread message in a conversation (scroll-to-unread marker) | 0.120 | 0.115 | 0.116 | **0.117** |

### 9. Admin / Analytics / Maintenance

| Query | Description | Run 1 | Run 2 | Run 3 | Average |
| --- | --- | ---: | ---: | ---: | ---: |
| 9.1 | Messages per day, last 30 days | 12.988 | 13.184 | 12.914 | **13.029** |
| 9.2 | Top 10 most active senders, last 7 days | 16.116 | 15.876 | 15.672 | **15.888** |
| 9.3 | Daily active users (users who sent at least one message) | 26.295 | 25.844 | 25.641 | **25.927** |
| 9.4 | Largest conversations by member count | 1.390 | 1.363 | 1.323 | **1.359** |
| 9.5 | Busiest conversations, last 24 hours | 3.108 | 2.867 | 2.781 | **2.919** |
| 9.6 | Users who never sent a message | 12.770 | 12.770 | 12.838 | **12.793** |
| 9.7 | Users with no conversations | 0.734 | 0.755 | 0.736 | **0.742** |
| 9.8 | Average time from delivery to read (minutes), last 7 days | 20.228 | 19.954 | 19.448 | **19.877** |
| 9.9 | Most blocked users (abuse signal) | 0.632 | 0.629 | 0.621 | **0.627** |
| 9.10 | Edit / delete ratio per user | 15.838 | 15.614 | 15.664 | **15.705** |
| 9.11 | Integrity check: members missing a receipt for messages sent after they joined | 116.244 | 96.673 | 93.544 | **102.154** |
| 9.12 | Refresh planner statistics after bulk loads (maintenance; updates catalog stats) | 122.238 | 121.290 | 123.284 | **122.271** |

---

## Summary

| Metric | Value |
| --- | ---: |
| Queries measured | 78 |
| Runs per query | 3 |
| Fastest average | 0.014 ms (query 1.3) |
| Median average | 0.304 ms |
| Mean average | 5.709 ms |
| Slowest average | 122.271 ms (query 9.12) |

Five slowest statements (average of the three runs):

| Query | Description | Average (ms) |
| --- | --- | ---: |
| 9.12 | Refresh planner statistics after bulk loads (maintenance; updates catalog stats) | 122.271 |
| 9.11 | Integrity check: members missing a receipt for messages sent after they joined | 102.154 |
| 9.3 | Daily active users (users who sent at least one message) | 25.927 |
| 7.13 | Permanently purge messages soft-deleted over 30 days ago (scheduled job) | 24.127 |
| 9.8 | Average time from delivery to read (minutes), last 7 days | 19.877 |
