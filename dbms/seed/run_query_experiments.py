#!/usr/bin/env python3
"""Run every query in dbms/04_queries.sql three times in PostgreSQL.

Writes:
  * dbms/05_query_timings.md   (Run 1 / Run 2 / Run 3 / Average, in ms)
  * dbms/plans/q<number>.txt   (EXPLAIN (ANALYZE, BUFFERS) output per run)

Parameters are bound to real rows fetched from the database. Every statement
runs inside BEGIN ... ROLLBACK, so write queries (INSERT/UPDATE/DELETE) are
measured without mutating the dataset; all three runs therefore see exactly
the same data.

Usage: python3 dbms/seed/run_query_experiments.py
"""

import os
import re
import statistics
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DBMS = os.path.dirname(HERE)
ROOT = os.path.dirname(DBMS)
PSQL = os.environ.get(
    "PSQL_BIN", "/Applications/Postgres.app/Contents/Versions/latest/bin/psql"
)
CONN = ["-h", "/tmp", "-p", "55432", "-U", "postgres", "-d", "dwelling"]
RUNS = 3


def psql(script):
    cmd = [PSQL, "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1"] + CONN
    proc = subprocess.run(cmd, input=script, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip()[:4000])
    return proc.stdout


def one(sql):
    out = [l for l in psql(sql).splitlines() if l.strip()]
    return out[0].strip() if out else ""


def cols(sql, n):
    row = one(sql).split("|")
    if len(row) != n:
        raise RuntimeError("expected %d columns from %r, got %r" % (n, sql, row))
    return row


def lit(value):
    return "'" + str(value).replace("'", "''") + "'"


def ts(value):
    return lit(value) + "::timestamptz"


# ---------------------------------------------------------------- reference rows
u1, u1name, u1email = cols(
    "SELECT user_id, username, email FROM users ORDER BY user_id LIMIT 1", 3
)
u2 = one("SELECT user_id FROM users WHERE user_id > 1 ORDER BY user_id LIMIT 1")
u3 = one("SELECT user_id FROM users WHERE user_id > 2 ORDER BY user_id LIMIT 1")
c1 = one("SELECT contact_id FROM contacts WHERE user_id = %s LIMIT 1" % u1)
mutual = cols(
    "SELECT a.user_id, b.contact_id "
    "FROM contacts a JOIN contacts b "
    "  ON b.contact_id = a.contact_id AND b.user_id <> a.user_id "
    "WHERE a.user_id = %s LIMIT 1" % u1,
    2,
)
direct = cols(
    "SELECT c.conversation_id, MIN(m.user_id), MAX(m.user_id) "
    "FROM conversations c JOIN conversation_members m USING (conversation_id) "
    "WHERE c.type = 'direct' GROUP BY 1 HAVING COUNT(*) = 2 ORDER BY 1 LIMIT 1",
    3,
)
gid, gowner = cols(
    "SELECT conversation_id, created_by FROM conversations "
    "WHERE type = 'group' ORDER BY 1 LIMIT 1",
    2,
)
gmember = one(
    "SELECT user_id FROM conversation_members WHERE conversation_id = %s "
    "AND role = 'member' ORDER BY user_id LIMIT 1" % gid
)
gadmin = (
    one(
        "SELECT user_id FROM conversation_members WHERE conversation_id = %s "
        "AND role = 'admin' ORDER BY user_id LIMIT 1" % gid
    )
    or gowner
)
guser = one(
    "SELECT user_id FROM conversation_members WHERE conversation_id = %s "
    "ORDER BY user_id LIMIT 1" % gid
)
reply_msg, reply_sender = cols(
    "SELECT message_id, sender_id FROM messages "
    "WHERE reply_to_message_id IS NOT NULL LIMIT 1",
    2,
)
thread_parent = one(
    "SELECT reply_to_message_id FROM messages WHERE reply_to_message_id IS NOT NULL "
    "GROUP BY 1 ORDER BY COUNT(*) DESC LIMIT 1"
)
recipient = one(
    "SELECT recipient_id FROM message_receipts WHERE status <> 'read' "
    "GROUP BY 1 ORDER BY COUNT(*) DESC LIMIT 1"
)
sent_msg, sent_recipient = cols(
    "SELECT message_id, recipient_id FROM message_receipts "
    "WHERE status = 'sent' LIMIT 1",
    2,
)
recip_conv, recip_conv_msg = cols(
    "SELECT m.conversation_id, MAX(m.message_id) FROM message_receipts r "
    "JOIN messages m USING (message_id) WHERE r.recipient_id = %s "
    "GROUP BY 1 ORDER BY COUNT(*) DESC LIMIT 1" % recipient,
    2,
)
blocker, blocked = cols(
    "SELECT user_id, blocked_contact_id FROM blocked_contacts LIMIT 1", 2
)
cursor_ts, cursor_id = cols(
    "SELECT created_at, message_id FROM messages WHERE conversation_id = %s "
    "ORDER BY created_at DESC, message_id DESC OFFSET 60 LIMIT 1" % gid,
    2,
)
first_msg = one("SELECT MIN(message_id) FROM messages WHERE conversation_id = %s" % gid)
msg_id, msg_sender = cols(
    "SELECT message_id, sender_id FROM messages ORDER BY message_id LIMIT 1", 2
)
u5 = one("SELECT user_id FROM users WHERE user_id = 5")
u6 = one("SELECT user_id FROM users WHERE user_id = 6")


# ---------------------------------------------------------------- parameters
# Positional parameters for every numbered statement in 04_queries.sql.
PARAMS = {
    "1.1": [lit("test.newuser"), lit("test.newuser@example.com"),
            lit("$2b$12$eImiTXuWVxfM37uY4JANjQ=="), lit("Test Newuser")],
    "1.2": [lit(u1email)],
    "1.3": [lit(u1name)],
    "1.4": [lit(u1name), lit(u1email)],
    "1.5": [u1],
    "1.6": [lit(u1name)],
    "1.7": [u2, lit("$2b$12$Q9kP0lJ4m4Rn2V0aB1cDeF")],
    "1.8": [u2, "NULL::varchar", "NULL::varchar"],
    "1.9": [u3],
    "1.10": [u3],
    "1.11": [lit("a"), u1, "20"],
    "1.12": ["20"],
    "2.1": [u1, lit("Aarav S."), lit("Rebuilt my profile after the move."),
            lit("https://cdn.dwelling.app/avatars/%s.jpg" % u1)],
    "2.2": [u1],
    "3.1": [u5, u6],
    "3.2": [u1, c1],
    "3.3": [u1],
    "3.4": [u1, c1],
    "3.5": [u1],
    "3.6": [mutual[0], mutual[1]],
    "3.7": [u1, "20"],
    "3.8": [u1],
    "4.1": [u5, u6],
    "4.2": [blocker, blocked],
    "4.3": [blocker],
    "4.4": [blocker, blocked],
    "4.5": [blocked],
    "5.1": [direct[1], direct[2]],
    "5.2": [u5, u6],
    "5.3": [u5, lit("Weekend Trip"), "ARRAY[%s, %s, %s]::BIGINT[]" % (u6, u3, u2)],
    "5.4": [gid, lit("Renamed Group"), gowner],
    "5.5": [u1, "30", "0"],
    "5.6": [direct[0], direct[1]],
    "5.7": [lit("a"), guser],
    "5.8": [gid, gowner],
    "5.9": [],
    "6.1": [gid, u5, gadmin],
    "6.2": [gid, gmember, gadmin],
    "6.3": [gid, gmember],
    "6.4": [gid, gmember, lit("admin"), gowner],
    "6.5": [gid, gowner, gmember],
    "6.6": [gid],
    "6.7": [gid, guser],
    "6.8": [gid],
    "7.1": [gid, gmember, lit("Running five minutes late, start without me."),
            "NULL::BIGINT"],
    "7.2": [gid, "50"],
    "7.3": [gid, ts(cursor_ts), cursor_id, "50"],
    "7.4": [gid, first_msg],
    "7.5": [reply_msg],
    "7.6": [thread_parent],
    "7.7": [msg_id, msg_sender, lit("Edited after sending.")],
    "7.8": [msg_id, msg_sender],
    "7.9": [gid, lit("dinner"), gmember, "20"],
    "7.10": [u1, lit("dinner"), "20"],
    "7.11": [u1, "50"],
    "7.12": [gid],
    "7.13": [],
    "8.1": [recipient],
    "8.2": [sent_msg, sent_recipient],
    "8.3": [recipient, recip_conv, recip_conv_msg],
    "8.4": [sent_msg],
    "8.5": [sent_msg],
    "8.6": [recipient],
    "8.7": [recipient],
    "8.8": [recipient],
    "8.9": [recipient, recip_conv],
    "9.1": [], "9.2": [], "9.3": [], "9.4": [], "9.5": [], "9.6": [],
    "9.7": [], "9.8": [], "9.9": [], "9.10": [], "9.11": [], "9.12": [],
}

SECTIONS = {
    "1": "1. Users & Auth",
    "2": "2. User Profiles",
    "3": "3. Contacts",
    "4": "4. Blocking",
    "5": "5. Conversations",
    "6": "6. Conversation Members",
    "7": "7. Messages",
    "8": "8. Message Receipts",
    "9": "9. Admin / Analytics / Maintenance",
}

HEADER_RE = re.compile(r"^-- (\d+\.\d+) (.*)$")
CONTINUATION_RE = re.compile(r"^--\s{4,}(?!\$)\S")


def parse_queries(path):
    queries, cur = [], None
    for raw in open(path, encoding="utf-8").read().splitlines():
        m = HEADER_RE.match(raw)
        if m:
            cur = {"key": m.group(1), "title": m.group(2).strip(), "body": []}
            queries.append(cur)
            continue
        if cur is not None:
            cur["body"].append(raw)

    for q in queries:
        # merge wrapped title lines ("--      continuation")
        for line in q["body"]:
            if CONTINUATION_RE.match(line):
                q["title"] += " " + line[2:].strip()
            else:
                break

        stmt = []
        for line in q["body"]:
            stmt.append(line)
            if line.rstrip().endswith(";"):
                break
        q["sql"] = "\n".join(stmt).strip()
        if not q["sql"].endswith(";"):
            raise RuntimeError("could not find statement for query %s" % q["key"])
    return queries


def bind(sql, params):
    # parameter-documentation comments ("-- $1 user_id, ...") are not SQL;
    # dropping them also keeps "$3" in prose from looking like a placeholder
    sql = "\n".join(
        line for line in sql.splitlines() if not re.match(r"^--\s*\$", line)
    )
    sql = re.sub(r"\$(\d+)", lambda m: "{{P%s}}" % m.group(1), sql)
    for idx, value in enumerate(params, start=1):
        sql = sql.replace("{{P%d}}" % idx, value)
    left = re.findall(r"\{\{P\d+\}\}", sql)
    if left:
        raise RuntimeError("unbound placeholders %s in: %s" % (left, sql[:120]))
    return sql


EXEC_TIME_RE = re.compile(r"Execution Time: ([0-9.]+) ms")


def main():
    queries = parse_queries(os.path.join(DBMS, "04_queries.sql"))
    plans_dir = os.path.join(DBMS, "plans")
    os.makedirs(plans_dir, exist_ok=True)

    unknown = [q["key"] for q in queries if q["key"] not in PARAMS]
    if unknown:
        raise SystemExit("no parameters defined for: %s" % ", ".join(unknown))

    # pre-flight: every $n in a statement must have a value, and no extras
    mismatched = []
    for q in queries:
        body = "\n".join(
            l for l in q["sql"].splitlines() if not re.match(r"^--\s*\$", l)
        )
        used = {int(n) for n in re.findall(r"\$(\d+)", body)}
        if used != set(range(1, len(PARAMS[q["key"]]) + 1)):
            mismatched.append((q["key"], sorted(used), len(PARAMS[q["key"]])))
    if mismatched:
        raise SystemExit("parameter count mismatch: %r" % (mismatched,))

    results = []
    for q in queries:
        stmt = bind(q["sql"], PARAMS[q["key"]])
        runs, plan_chunks = [], []
        # ANALYZE cannot be explained; measure it with psql's own timer
        is_maintenance = bool(
            re.match(r"\s*(?:--[^\n]*\n\s*)*ANALYZE\b", stmt, re.IGNORECASE)
        )
        for run_idx in range(1, RUNS + 1):
            if is_maintenance:
                script = (
                    "\\set ON_ERROR_STOP on\n"
                    "BEGIN;\n"
                    "\\timing on\n"
                    + stmt
                    + "\n\\timing off\nROLLBACK;\n"
                )
                out = psql(script)
                match = re.search(r"Time: ([0-9.]+) ms", out)
                plan_body = ("-- ANALYZE refreshes catalog statistics and has no "
                             "query plan; timing is psql client-side (\\timing on).")
            else:
                script = (
                    "\\set ON_ERROR_STOP on\n"
                    "BEGIN;\n"
                    "EXPLAIN (ANALYZE, BUFFERS)\n"
                    + stmt
                    + "\nROLLBACK;\n"
                )
                out = psql(script)
                match = EXEC_TIME_RE.search(out)
                plan_body = "\n".join(l for l in out.splitlines() if l.strip())
            if not match:
                raise RuntimeError(
                    "no execution time for %s run %d:\n%s" % (q["key"], run_idx, out)
                )
            runs.append(float(match.group(1)))
            plan_chunks.append("-- Run %d: %s ms\n%s" % (run_idx, match.group(1), plan_body))
            print("  %-5s run %d: %8.3f ms" % (q["key"], run_idx, runs[-1]), flush=True)

        with open(os.path.join(plans_dir, "q%s.txt" % q["key"]), "w") as fh:
            fh.write("-- Query %s: %s\n" % (q["key"], q["title"]))
            fh.write("-- PostgreSQL 18.6, EXPLAIN (ANALYZE, BUFFERS), parameters bound\n\n")
            fh.write("\n\n".join(plan_chunks) + "\n")

        results.append(
            {
                "key": q["key"],
                "title": q["title"],
                "runs": runs,
                "avg": statistics.mean(runs),
            }
        )

    write_markdown(results, plans_dir)
    slowest = max(results, key=lambda r: r["avg"])
    print("\nAll %d queries measured. Slowest: %s (%.3f ms avg)"
          % (len(results), slowest["key"], slowest["avg"]))


def counts():
    tables = ["users", "user_profiles", "contacts", "blocked_contacts",
              "conversations", "conversation_members", "messages",
              "message_receipts"]
    return [(t, int(one("SELECT COUNT(*) FROM %s" % t))) for t in tables]


def write_markdown(results, plans_dir):
    lines = [
        "# Query Timings — `04_queries.sql`",
        "",
        "Each query in [`04_queries.sql`](04_queries.sql) was executed three times",
        "against a local PostgreSQL instance loaded with the synthetic dataset from",
        "[`seed/synthetic_data.sql`](seed/synthetic_data.sql).",
        "",
        "**Method**",
        "",
        "* Timings are the server-side `Execution Time` reported by",
        "  `EXPLAIN (ANALYZE, BUFFERS)` (milliseconds, planning excluded).",
        "* Every run used a fresh connection; the three runs are consecutive,",
        "  so the data set and cache state are identical.",
        "* Statements ran inside `BEGIN … ROLLBACK`, so `INSERT`/`UPDATE`/`DELETE`",
        "  queries were measured without modifying the data.",
        "* Positional parameters (`$1`, `$2`, …) were bound to real rows",
        "  (existing user / conversation / message ids, real search terms).",
        "* Query `9.12` is a bare `ANALYZE` statement, which cannot be wrapped in",
        "  `EXPLAIN`; its three values are psql client-side latencies (`\\timing on`).",
        "* Full plans: [`plans/`](plans/) — one file per query (`q1.1.txt` … `q9.12.txt`).",
        "",
        "**Environment**",
        "",
        "| Item | Value |",
        "| --- | --- |",
        "| Server | PostgreSQL 18.6 (Postgres.app), local socket, port 55432 |",
        "| Machine | macOS (Apple silicon), local SSD |",
        "| Server settings | PostgreSQL defaults, `shared_buffers = 128MB` |",
        "| Statistics | `ANALYZE` + `VACUUM (ANALYZE)` run after the bulk load |",
        "",
        "**Dataset**",
        "",
        "| Table | Rows |",
        "| --- | ---: |",
    ]
    for table, n in counts():
        lines.append("| `%s` | %s |" % (table, format(n, ",")))

    lines += [
        "",
        "Timestamps in the dataset are relative to `NOW()`, so the \"last 7 days\" /",
        "\"last 30 days\" analytics queries operate on populated ranges.",
        "",
        "---",
        "",
        "## Results",
        "",
        "All values in **milliseconds**.",
        "",
    ]

    current_section = None
    for r in results:
        section = r["key"].split(".")[0]
        if section != current_section:
            current_section = section
            lines += [
                "",
                "### %s" % SECTIONS[section],
                "",
                "| Query | Description | Run 1 | Run 2 | Run 3 | Average |",
                "| --- | --- | ---: | ---: | ---: | ---: |",
            ]
        title = r["title"].replace("|", "\\|")
        lines.append(
            "| %s | %s | %.3f | %.3f | %.3f | **%.3f** |"
            % (r["key"], title, r["runs"][0], r["runs"][1], r["runs"][2], r["avg"])
        )

    all_avgs = [r["avg"] for r in results]
    slowest = sorted(results, key=lambda r: r["avg"], reverse=True)[:5]
    fastest = min(results, key=lambda r: r["avg"])

    lines += [
        "",
        "---",
        "",
        "## Summary",
        "",
        "| Metric | Value |",
        "| --- | ---: |",
        "| Queries measured | %d |" % len(results),
        "| Runs per query | %d |" % RUNS,
        "| Fastest average | %.3f ms (query %s) |" % (fastest["avg"], fastest["key"]),
        "| Median average | %.3f ms |" % statistics.median(all_avgs),
        "| Mean average | %.3f ms |" % statistics.mean(all_avgs),
        "| Slowest average | %.3f ms (query %s) |" % (slowest[0]["avg"], slowest[0]["key"]),
        "",
        "Five slowest statements (average of the three runs):",
        "",
        "| Query | Description | Average (ms) |",
        "| --- | --- | ---: |",
    ]
    for r in slowest:
        lines.append(
            "| %s | %s | %.3f |"
            % (r["key"], r["title"].replace("|", "\\|"), r["avg"])
        )
    lines.append("")

    with open(os.path.join(DBMS, "05_query_timings.md"), "w") as fh:
        fh.write("\n".join(lines))


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as exc:
        sys.stderr.write("ERROR: %s\n" % exc)
        sys.exit(1)
