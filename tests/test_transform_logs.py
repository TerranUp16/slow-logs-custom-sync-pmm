"""Unit tests for transform_logs.py (stdlib unittest only — the sink has no venv).

Run from the repo root:
    python3 -m unittest discover -s tests

Everything here is synthetic RFC3164 input; nothing touches the network or the
real /var/log/mysql_sink paths.
"""
import io
import os
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import transform_logs as tl  # noqa: E402


def syslog_line(host, block_id, line_num, payload):
    """One forwarded line in the shape the parser expects: RFC3164 header, the
    [SlowQuery] marker, then a [block-line] sequence tag and the payload."""
    return f"<134>Nov 12 21:10:00 {host} mysql: [SlowQuery] [{block_id}-{line_num}] {payload}\n"


def block_lines(host, block_id, payloads):
    return [syslog_line(host, block_id, i, p) for i, p in enumerate(payloads, 1)]


def do_file_line(host, block_id, line_num, payload, fmt="file"):
    """A line exactly as rsyslog writes DO's forwarded slow log to the incoming
    file (captured from a live DO Managed MySQL 8.4 -> sink, 2026-11). `fmt`
    selects the rsyslog omfile template: RSYSLOG_FileFormat ("file", what
    setup.sh pins) or RSYSLOG_TraditionalFileFormat ("traditional")."""
    ts = "2026-11-12T21:53:42+00:00" if fmt == "file" else "Nov 12 21:53:42"
    return (f"{ts} {host} mysqld[241]: 2026-11-12T21:53:42.923636Z 1801 [SlowQuery] "
            f"[MY-000000] [Server] [{block_id}-{line_num}] {payload}\n")


REAL_QUERY = [
    "# Time: 2026-11-12T21:53:42.923636Z",
    "# User@Host: app_rw[app_rw] @  [10.0.0.5]  Id:  1801",
    "# Query_time: 0.256635  Lock_time: 0.000000 Rows_sent: 1  Rows_examined: 1",
    "use appdb;",
    "SET timestamp=1794520422;",
    "SELECT /* wl:ps_sleep */ SLEEP(0.256) AS s, 'prepared' AS label;",
]

QUERY_A = ["# Time: 2026-11-12T21:10:00.000000Z", "# Query_time: 0.2  Lock_time: 0.0", "SELECT SLEEP(0.2);"]
QUERY_B = ["# Time: 2026-11-12T21:10:01.000000Z", "# Query_time: 0.3  Lock_time: 0.0", "SELECT 2;"]
QUERY_C = ["# Time: 2026-11-12T21:10:02.000000Z", "# Query_time: 0.4  Lock_time: 0.0", "SELECT 3;"]


def expected(*queries):
    return "".join("\n".join(q) + "\n\n" for q in queries)


def reset_drop_counters():
    tl._drop_counts.clear()
    tl._drop_logged_at.clear()


class ParserTests(unittest.TestCase):
    def setUp(self):
        reset_drop_counters()
        self.blocks, self.block_times, self.active = {}, {}, {}
        self.out = io.StringIO()

    def feed(self, lines):
        for line in lines:
            tl._process_line(line, self.blocks, self.block_times, self.active, self.out)

    def age_all(self):
        """Pretend every in-flight block arrived longer than BLOCK_TTL ago."""
        for k in self.block_times:
            self.block_times[k] -= tl.BLOCK_TTL + 1

    def test_block_finalized_when_same_host_starts_next(self):
        self.feed(block_lines("db-1", 10, QUERY_A))
        self.assertEqual(self.out.getvalue(), "", "block must not be written while it may still grow")
        self.feed(block_lines("db-1", 11, QUERY_B)[:1])
        self.assertEqual(self.out.getvalue(), expected(QUERY_A))

    def test_interleaved_hosts_do_not_mix(self):
        a, b = block_lines("db-1", 5, QUERY_A), block_lines("db-2", 5, QUERY_B)
        self.feed([a[0], b[0], a[1], b[1], a[2], b[2]])
        self.feed(block_lines("db-1", 6, QUERY_C)[:1])
        self.feed(block_lines("db-2", 6, QUERY_C)[:1])
        self.assertEqual(self.out.getvalue(), expected(QUERY_A, QUERY_B))

    def test_block_with_gap_is_dropped(self):
        lines = block_lines("db-1", 1, QUERY_A)
        self.feed([lines[0], lines[2]])
        self.feed(block_lines("db-1", 2, QUERY_B)[:1])
        self.assertEqual(self.out.getvalue(), "")
        self.assertEqual(tl._drop_counts.get("finalized block has gaps"), 1)

    def test_out_of_order_lines_reassembled(self):
        lines = block_lines("db-1", 3, QUERY_A)
        self.feed([lines[0], lines[2], lines[1]])
        self.feed(block_lines("db-1", 4, QUERY_B)[:1])
        self.assertEqual(self.out.getvalue(), expected(QUERY_A))

    def test_stale_complete_block_is_written(self):
        # Regression: the last block before a quiet period never sees a
        # "next block" signal and used to be discarded by _purge_stale.
        self.feed(block_lines("db-1", 7, QUERY_A))
        self.age_all()
        tl._purge_stale(self.blocks, self.block_times, self.active, self.out)
        self.assertEqual(self.out.getvalue(), expected(QUERY_A))
        self.assertEqual(self.blocks, {})
        self.assertEqual(self.active, {})

    def test_stale_incomplete_block_is_discarded(self):
        lines = block_lines("db-1", 8, QUERY_A)
        self.feed([lines[0], lines[2]])
        self.age_all()
        with self.assertLogs(tl.log, level="WARNING") as cm:
            tl._purge_stale(self.blocks, self.block_times, self.active, self.out)
        self.assertEqual(self.out.getvalue(), "")
        self.assertIn("Discarding stale incomplete block", cm.output[0])
        self.assertEqual(self.blocks, {})

    def test_fresh_block_not_purged(self):
        self.feed(block_lines("db-1", 9, QUERY_A))
        tl._purge_stale(self.blocks, self.block_times, self.active, self.out)
        self.assertEqual(self.out.getvalue(), "")
        self.assertIn(("db-1", 9), self.blocks)

    def test_host_parsed_from_real_rsyslog_file_formats(self):
        for fmt in ("file", "traditional"):
            with self.subTest(fmt=fmt):
                self.blocks.clear()
                self.feed([do_file_line("prod-primary-1", 42, 1, "x", fmt=fmt)])
                self.assertIn(("prod-primary-1", 42), self.blocks)

    def test_real_format_block_reassembled(self):
        self.feed([do_file_line("prod-primary-1", 720787, i, p) for i, p in enumerate(REAL_QUERY, 1)])
        self.feed([do_file_line("prod-primary-1", 721039, 1, "# Time: next")])
        self.assertEqual(self.out.getvalue(), expected(REAL_QUERY))

    def test_real_format_interleaved_hosts_kept_separate(self):
        # Regression: with host parsing broken, both nodes were keyed "unknown",
        # so node 2's line 1 "finished" node 1's half-delivered block (dropped
        # for gaps) and the two queries were lost or mixed.
        a = [do_file_line("prod-primary-1", 100, i, p) for i, p in enumerate(QUERY_A, 1)]
        b = [do_file_line("prod-replica-1", 100, i, p) for i, p in enumerate(QUERY_B, 1)]
        self.feed([a[0], b[0], a[1], b[1], a[2], b[2]])
        self.feed([do_file_line("prod-primary-1", 101, 1, "x"), do_file_line("prod-replica-1", 101, 1, "x")])
        self.assertEqual(self.out.getvalue(), expected(QUERY_A, QUERY_B))

    def test_payload_containing_sequence_like_text_not_truncated(self):
        sql = "SELECT '[7-1] looks like a tag' AS s;"
        self.feed([do_file_line("prod-primary-1", 7, 1, sql)])
        self.assertEqual(self.blocks[("prod-primary-1", 7)][1], sql)

    def test_non_slowquery_lines_ignored(self):
        self.feed(["<134>Nov 12 21:10:00 db-1 mysql: [Note] something [1-1] else\n"])
        self.assertEqual(self.blocks, {})

    def test_line_without_sequence_ignored(self):
        self.feed(["<134>Nov 12 21:10:00 db-1 mysql: [SlowQuery] no sequence tag\n"])
        self.assertEqual(self.blocks, {})

    def test_unparseable_header_keyed_as_unknown_host(self):
        self.feed(["garbage [SlowQuery] [1-1] payload\n"])
        self.assertIn(("unknown", 1), self.blocks)

    def test_oversized_line_dropped(self):
        big = syslog_line("db-1", 1, 1, "x" * (tl.MAX_LINE_BYTES + 1))
        self.feed([big])
        self.assertEqual(self.blocks, {})
        self.assertEqual(tl._drop_counts.get("oversized line"), 1)

    def test_max_lines_per_block_bound(self):
        n = tl.MAX_LINES_PER_BLOCK
        self.feed([syslog_line("db-1", 1, i, "x") for i in range(1, n + 2)])
        self.assertEqual(len(self.blocks[("db-1", 1)]), n)
        self.assertEqual(tl._drop_counts.get("max lines per block reached"), 1)

    def test_max_blocks_bound(self):
        old = tl.MAX_BLOCKS
        tl.MAX_BLOCKS = 3
        try:
            self.feed([syslog_line(f"db-{i}", 1, 1, "x") for i in range(4)])
        finally:
            tl.MAX_BLOCKS = old
        self.assertEqual(len(self.blocks), 3)
        self.assertEqual(tl._drop_counts.get("max in-flight blocks reached"), 1)

    def test_drop_warnings_throttled_by_time_not_count(self):
        with self.assertLogs(tl.log, level="WARNING") as logs:
            tl._warn_drop("finalized block has gaps")
            tl._warn_drop("finalized block has gaps")   # within the interval: counted only
            tl._drop_logged_at["finalized block has gaps"] -= tl.DROP_LOG_INTERVAL
            tl._warn_drop("finalized block has gaps")   # interval elapsed: logged again
        self.assertEqual(len(logs.records), 2)
        self.assertIn("occurrences=3", logs.output[-1])


class LineReaderTests(unittest.TestCase):
    """_LineReader against a real file that's appended to between reads, the
    way rsyslog appends to the incoming file while the daemon polls it."""

    def setUp(self):
        reset_drop_counters()
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, "in.log")
        open(self.path, "wb").close()
        self.f = open(self.path, "rb")
        self.reader = tl._LineReader(self.f)

    def tearDown(self):
        self.f.close()
        self.tmp.cleanup()

    def append(self, data):
        with open(self.path, "ab") as f:
            f.write(data)

    def test_fragment_held_until_its_newline_arrives(self):
        self.append(b"first half, ")
        self.assertEqual(self.reader.readline(), "")
        self.append(b"second half\nnext\n")
        self.assertEqual(self.reader.readline(), "first half, second half\n")
        self.assertEqual(self.reader.readline(), "next\n")
        self.assertEqual(self.reader.readline(), "")

    def test_multibyte_character_split_across_reads(self):
        data = "SELECT 'café';\n".encode("utf-8")
        cut = data.index("é".encode("utf-8")) + 1   # between the two bytes of é
        self.append(data[:cut])
        self.assertEqual(self.reader.readline(), "")
        self.append(data[cut:])
        self.assertEqual(self.reader.readline(), "SELECT 'café';\n")

    def test_malformed_bytes_still_surface_as_replacement_char(self):
        self.append(b"bad \xff byte\n")
        self.assertEqual(self.reader.readline(), "bad � byte\n")

    def test_oversized_line_discarded_up_to_its_newline(self):
        old = tl.MAX_LINE_BYTES
        tl.MAX_LINE_BYTES = 64
        try:
            self.append(b"x" * 100)                  # no newline yet, already too long
            self.assertEqual(self.reader.readline(), "")
            self.assertEqual(self.reader.pending, b"", "must not buffer past the bound")
            self.append(b"y" * 100 + b"\nok\n")
            self.assertEqual(self.reader.readline(), "ok\n")
        finally:
            tl.MAX_LINE_BYTES = old
        self.assertEqual(tl._drop_counts.get("oversized line"), 1)


class DaemonLoopTests(unittest.TestCase):
    """Drive run() for real against temp files, to cover file-rotation handling."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = self.tmp.name
        self.incoming = os.path.join(d, "incoming", "combined_mysql.log")
        self.output = os.path.join(d, "processed", "native_slow_query.log")
        os.makedirs(os.path.dirname(self.incoming))
        open(self.incoming, "w").close()
        self._saved = (tl.COMBINED_FILE, tl.SLOW_LOG_OUTPUT, tl.BLOCK_TTL)
        tl.COMBINED_FILE, tl.SLOW_LOG_OUTPUT = self.incoming, self.output
        tl.BLOCK_TTL = 0.5  # so stale-finalization happens within the test
        tl._running = True
        reset_drop_counters()
        self.thread = threading.Thread(target=self._run_quietly, daemon=True)
        self.thread.start()
        self._wait_for(lambda: os.path.exists(self.output))

    def _run_quietly(self):
        # run() installs SIGTERM/SIGINT handlers, which only works on the main
        # thread; stub signal.signal out for the duration of the test.
        orig = tl.signal.signal
        tl.signal.signal = lambda *a, **k: None
        try:
            tl.run()
        finally:
            tl.signal.signal = orig

    def tearDown(self):
        tl._running = False
        self.thread.join(timeout=5)
        tl.COMBINED_FILE, tl.SLOW_LOG_OUTPUT, tl.BLOCK_TTL = self._saved
        self.tmp.cleanup()

    @staticmethod
    def _wait_for(cond, timeout=5.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if cond():
                return True
            time.sleep(0.05)
        raise AssertionError("condition not met within %.1fs" % timeout)

    def _append_input(self, lines):
        with open(self.incoming, "a") as f:
            f.writelines(lines)

    @staticmethod
    def _read(path):
        with open(path) as f:
            return f.read()

    def test_last_block_of_a_burst_reaches_output(self):
        self._append_input(block_lines("db-1", 1, QUERY_A))
        self._wait_for(lambda: self._read(self.output) == expected(QUERY_A))

    def test_output_reopened_after_logrotate_create(self):
        self._append_input(block_lines("db-1", 1, QUERY_A))
        self._wait_for(lambda: self._read(self.output) == expected(QUERY_A))

        # What logrotate's `create` mode does: rename, then create a new empty file.
        os.rename(self.output, self.output + ".1")
        open(self.output, "w").close()

        self._append_input(block_lines("db-1", 2, QUERY_B))
        self._wait_for(lambda: self._read(self.output) == expected(QUERY_B))
        self.assertEqual(self._read(self.output + ".1"), expected(QUERY_A),
                         "post-rotation data must not keep going into the rotated file")

    def test_output_recreated_if_deleted(self):
        os.remove(self.output)
        self._append_input(block_lines("db-1", 1, QUERY_A))
        self._wait_for(lambda: os.path.exists(self.output) and self._read(self.output) == expected(QUERY_A))

    def test_input_rotation_followed(self):
        self._append_input(block_lines("db-1", 1, QUERY_A))
        self._wait_for(lambda: self._read(self.output) == expected(QUERY_A))
        os.rename(self.incoming, self.incoming + ".1")
        with open(self.incoming, "w") as f:
            f.writelines(block_lines("db-1", 2, QUERY_B))
        self._wait_for(lambda: self._read(self.output) == expected(QUERY_A, QUERY_B))

    def _let_daemon_poll(self):
        time.sleep(tl.POLL_INTERVAL * 4)

    def test_line_cut_mid_write_is_reassembled(self):
        # rsyslog's write() lands in the file a page at a time, so the daemon
        # can read a line in two pieces. Cut line 2 at each kind of position
        # that broke the old parser: before [SlowQuery] (rest filed under host
        # "unknown"), between [SlowQuery] and the [block-line] tag (line lost,
        # block dropped for a gap — what happened live), and in the payload
        # (line truncated).
        lines = [do_file_line("db-1", 1, i, p) for i, p in enumerate(REAL_QUERY, 1)]
        target = lines[1]
        cuts = {
            "prefix": target.index("[SlowQuery]") - 5,
            "tag-window": target.index("[MY-000000]"),
            "payload": len(target) - 10,
        }
        for block_id, (name, cut) in enumerate(cuts.items(), 1):
            with self.subTest(cut=name):
                reset_drop_counters()
                before = len(self._read(self.output))
                lines = [do_file_line("db-1", block_id, i, p) for i, p in enumerate(REAL_QUERY, 1)]
                self._append_input(lines[:1] + [lines[1][:cut]])
                self._let_daemon_poll()
                self._append_input([lines[1][cut:]] + lines[2:])
                # BLOCK_TTL is 0.5 s here, so the block is flushed even though
                # no next block follows it.
                self._wait_for(lambda: self._read(self.output)[before:] == expected(REAL_QUERY))
                time.sleep(tl.BLOCK_TTL * 2)   # let any stray "unknown" fragment block expire
                self.assertEqual(tl._drop_counts, {})
                self.assertEqual(self._read(self.output)[before:], expected(REAL_QUERY))

    def test_fragment_left_at_input_rotation_is_dropped_not_glued(self):
        self._append_input([syslog_line("db-1", 1, 1, "# Time: cut short")[:30]])
        self._let_daemon_poll()
        os.rename(self.incoming, self.incoming + ".1")
        with open(self.incoming, "w") as f:
            f.writelines(block_lines("db-1", 2, QUERY_B))
        self._wait_for(lambda: self._read(self.output) == expected(QUERY_B))
        self.assertEqual(tl._drop_counts.get("incomplete line at input rotation"), 1)


if __name__ == "__main__":
    unittest.main()
