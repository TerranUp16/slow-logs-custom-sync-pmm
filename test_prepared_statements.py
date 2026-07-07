#!/usr/bin/env python3
"""
Test prepared statement slow query logging.

Goal: verify that prepared statements (COM_STMT_PREPARE / COM_STMT_EXECUTE)
are captured in the slow query log forwarded via syslog, since
performance_schema does NOT log these.

Connects via socat proxy on the sink droplet (127.0.0.1:25060).
Requires the pmm_monitor DB password, either way:
  python3 test_prepared_statements.py "$DB_PASS"
  DB_PASS=... python3 test_prepared_statements.py
"""

import os
import sys
import time

try:
    import mysql.connector
except ImportError:
    sys.exit(
        "mysql-connector-python is required. Install it in a virtualenv:\n"
        "  python3 -m venv .venv && . .venv/bin/activate && pip install mysql-connector-python\n"
        "then re-run this script."
    )

HOST = "127.0.0.1"
PORT = 25060
USER = "pmm_monitor"
PASS = os.environ.get("DB_PASS", "")

LONG_QUERY_TIME = 3.1  # just over the 3s threshold

# Each tuple: (description, statement_with_placeholder, params)
# All use SLEEP() to force the query past long_query_time.
TESTS = [
    (
        "Simple SELECT with SLEEP",
        "SELECT SLEEP(?), ? AS label",
        (LONG_QUERY_TIME, "sleep_test"),
    ),
    (
        "SELECT with arithmetic and SLEEP",
        "SELECT ?, ? * 2 + ?, SLEEP(?)",
        (10, 5, 3, LONG_QUERY_TIME),
    ),
    (
        "Conditional expression with SLEEP",
        "SELECT IF(? > 0, SLEEP(?), 0) AS conditional_sleep",
        (1, LONG_QUERY_TIME),
    ),
    (
        "Multi-param string ops with SLEEP",
        "SELECT CONCAT(?, ' ', ?), LENGTH(?), SLEEP(?)",
        ("hello", "world", "prepared_stmt_test", LONG_QUERY_TIME),
    ),
    (
        "CASE expression with SLEEP",
        "SELECT CASE ? WHEN 1 THEN SLEEP(?) ELSE 0 END AS case_result",
        (1, LONG_QUERY_TIME),
    ),
    (
        "Date functions with SLEEP",
        "SELECT NOW(), DATE_ADD(NOW(), INTERVAL ? DAY), SLEEP(?)",
        (7, LONG_QUERY_TIME),
    ),
    (
        "Subquery-style expression with SLEEP",
        "SELECT (SELECT SLEEP(?)) AS sub, ? AS marker",
        (LONG_QUERY_TIME, "subquery_prepared"),
    ),
]


def run_tests(password: str) -> None:
    print(f"Connecting to {HOST}:{PORT} as {USER}...")
    conn = mysql.connector.connect(
        host=HOST,
        port=PORT,
        user=USER,
        password=password,
        ssl_disabled=False,
        use_pure=True,
    )
    cursor = conn.cursor(prepared=True)  # forces COM_STMT_PREPARE protocol
    print(f"Connected. Running {len(TESTS)} prepared statement tests (each >{LONG_QUERY_TIME}s).\n")

    for i, (desc, sql, params) in enumerate(TESTS, 1):
        print(f"[{i}/{len(TESTS)}] {desc}")
        print(f"         SQL: {sql}")
        print(f"      params: {params}")
        t0 = time.time()
        cursor.execute(sql, params)
        cursor.fetchall()
        elapsed = time.time() - t0
        print(f"    elapsed: {elapsed:.2f}s\n")

    cursor.close()
    conn.close()
    print("All queries done. The slow-query-sink daemon processes entries continuously;")
    print("check: tail -f /var/log/mysql_sink/processed/native_slow_query.log")
    print("\nYou should see entries with 'Query_time' >= 3 and the prepared SQL text.")
    print("If they appear here but NOT in PMM performance_schema QAN, the pipeline")
    print("is capturing what performance_schema misses.")


if __name__ == "__main__":
    password = PASS or (sys.argv[1] if len(sys.argv) > 1 else "")
    if not password:
        print("Usage: DB_PASS=... python3 test_prepared_statements.py")
        print("   or: python3 test_prepared_statements.py <password>")
        sys.exit(1)
    run_tests(password)
