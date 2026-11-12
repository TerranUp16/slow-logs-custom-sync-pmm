#!/usr/bin/env python3
"""
MySQL Slow Query Log Reconstruction Daemon
Tails syslog-forwarded MySQL slow query logs from DigitalOcean Managed Databases,
reconstructs multi-line blocks keyed by (source_host, block_id), and appends
complete entries to the native slow query log for PMM QAN consumption.

Deploys to: /var/log/mysql_sink/bin/transform_logs.py
Managed by: slow-query-sink.service (systemd)
"""

import os
import re
import sys
import time
import signal
import logging

COMBINED_FILE = "/var/log/mysql_sink/incoming/combined_mysql.log"
SLOW_LOG_OUTPUT = "/var/log/mysql_sink/processed/native_slow_query.log"
POLL_INTERVAL = 0.1   # seconds between reads when no new data
BLOCK_TTL     = 30.0  # seconds before an incomplete block is discarded

# Defense-in-depth bounds on untrusted syslog input (mTLS gates the sender, but
# the parser still treats every line as hostile and refuses to grow unbounded).
MAX_BLOCKS          = 10000    # distinct in-flight blocks before new ones are dropped
MAX_LINES_PER_BLOCK = 1000     # fragments retained per block
MAX_PAYLOAD_BYTES   = 1 << 20  # max reconstructed payload kept per line (1 MiB)
MAX_LINE_BYTES      = 1 << 20  # ignore absurdly long raw input lines (1 MiB)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger(__name__)

# Source host is the field after the timestamp. DO sends RFC3164 on the wire, but
# what we parse is rsyslog's *file* output, whose shape depends on the omfile
# template — so accept every shape it can realistically have:
#   RSYSLOG_FileFormat (setup.sh pins this):  2026-11-12T21:53:42+00:00 host mysqld[241]: ...
#   RSYSLOG_TraditionalFileFormat:            Nov 12 21:53:42 host mysqld[241]: ...
#   raw RFC3164 with PRI:                     <134>Nov 12 21:53:42 host mysqld[241]: ...
# (An earlier version only matched the last form, which rsyslog never writes to a
# file, so every line was keyed to host "unknown" and per-host block separation
# silently didn't happen.)
SYSLOG_HOST_RE = re.compile(
    r'^(?:<\d+>)?(?:\d{4}-\d{2}-\d{2}T[\d:.]+(?:Z|[+-]\d{2}:?\d{2})|\w{3}\s+\d+\s+[\d:]+)\s+(\S+)\s+'
)
SEQ_RE = re.compile(r'\[(\d+)-(\d+)\]')

_running = True

# Throttle drop warnings so a flood of bad input can't itself flood the journal.
_drop_counts = {}


def _warn_drop(reason):
    n = _drop_counts.get(reason, 0) + 1
    _drop_counts[reason] = n
    if n == 1 or n % 1000 == 0:
        log.warning("Dropping input: %s (occurrences=%d)", reason, n)


def _handle_signal(signum, frame):
    global _running
    _running = False


def _get_inode(path):
    try:
        return os.stat(path).st_ino
    except FileNotFoundError:
        return None


def _open_tail(path):
    """Open path for tailing (seeked to end). Blocks until file exists."""
    while _running:
        try:
            # errors="replace" surfaces malformed/garbage bytes as U+FFFD instead
            # of silently dropping them, so tampering or corruption stays visible.
            f = open(path, "r", errors="replace")
            inode = _get_inode(path)
            f.seek(0, 2)
            return f, inode
        except FileNotFoundError:
            time.sleep(1)
    return None, None


def _open_output(path):
    """Open the processed log for appending; return (file, inode of what we opened).
    The inode is remembered so run() can notice when logrotate (or anything else)
    has moved the file out from under us — see _reopen_output_if_rotated."""
    f = open(path, "a")
    return f, os.fstat(f.fileno()).st_ino


def _reopen_output_if_rotated(path, out_file, out_inode):
    """Reopen the processed log if the file at `path` is no longer the one we
    hold open. Without this, after logrotate renames native_slow_query.log to
    .1 and creates a fresh empty file, we'd keep appending to .1 (and later to a
    deleted .2.gz inode) while pmm-agent tails the new, forever-empty file —
    i.e. QAN silently stops one day after deployment.

    If the path is missing entirely (deleted, or caught between logrotate's
    rename and create), recreate it ourselves; the unit's UMask plus the setgid
    processed/ directory give it the same 0640 mysqlsink:adm that logrotate's
    `create` line would."""
    if _get_inode(path) == out_inode:
        return out_file, out_inode
    log.info("Output file %s was rotated or removed, reopening", path)
    out_file.close()
    return _open_output(path)


def _finalize_block(key, blocks, block_times, out_file, stale=False):
    """Write out a block once we're sure no more lines are coming for it: either
    the same host started a new block (see active_block in _process_line), or it
    went stale. A block's true line count isn't known up front (it varies with
    SQL length), so completeness can't be checked line-by-line as data arrives —
    only at the moment we decide the block is done."""
    lines = blocks.pop(key, None)
    block_times.pop(key, None)
    if not lines:
        return
    max_line = max(lines)
    if len(lines) != max_line or not all(i in lines for i in range(1, max_line + 1)):
        if stale:
            log.warning("Discarding stale incomplete block host=%s block_id=%s", *key)
        else:
            _warn_drop("finalized block has gaps")
        return
    rebuilt = [lines[i] for i in range(1, max_line + 1)]
    out_file.write("\n".join(rebuilt) + "\n\n")
    out_file.flush()


def _process_line(line, blocks, block_times, active_block, out_file):
    if len(line) > MAX_LINE_BYTES:
        _warn_drop("oversized line")
        return

    if "[SlowQuery]" not in line:
        return

    host_match = SYSLOG_HOST_RE.match(line)
    source_host = host_match.group(1) if host_match else "unknown"

    seq_match = SEQ_RE.search(line)
    if not seq_match:
        return

    block_id = int(seq_match.group(1))
    line_num  = int(seq_match.group(2))

    # Everything after the FIRST [block-line] tag is payload. (maxsplit matters:
    # SQL text that happens to contain the same "[12-3]" string must not be
    # truncated at it.)
    payload = line[seq_match.end():].strip()
    if len(payload) > MAX_PAYLOAD_BYTES:
        _warn_drop("oversized payload")
        return

    key = (source_host, block_id)

    # A per-host slow-log writer is serialized, so line 1 of a new block_id can
    # only appear once the previous block for that same host has fully arrived —
    # that's the actual "block is done" signal, not any line-count arithmetic.
    prev_active = active_block.get(source_host)
    if line_num == 1 and prev_active is not None and prev_active != key:
        _finalize_block(prev_active, blocks, block_times, out_file)

    if key not in blocks:
        if len(blocks) >= MAX_BLOCKS:
            _warn_drop("max in-flight blocks reached")
            return
        blocks[key] = {}
        block_times[key] = time.monotonic()
    elif line_num not in blocks[key] and len(blocks[key]) >= MAX_LINES_PER_BLOCK:
        _warn_drop("max lines per block reached")
        return
    blocks[key][line_num] = payload
    active_block[source_host] = key


def _purge_stale(blocks, block_times, active_block, out_file):
    """Finalize blocks older than BLOCK_TTL. Normally a block is finalized when
    its host starts the next one (see _process_line), but the LAST block before
    a quiet period never gets that signal — so it has to be finalized here, and
    written out if it's complete. (Discarding it instead, as this used to, lost
    the final slow query of every burst on a quiet DB.)"""
    now   = time.monotonic()
    stale = [k for k, ts in block_times.items() if now - ts > BLOCK_TTL]
    for key in stale:
        host = key[0]
        if active_block.get(host) == key:
            del active_block[host]
        _finalize_block(key, blocks, block_times, out_file, stale=True)


def run():
    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    os.makedirs(os.path.dirname(SLOW_LOG_OUTPUT), exist_ok=True)

    blocks       = {}  # (host, block_id) -> {line_num: payload}
    block_times  = {}  # (host, block_id) -> monotonic timestamp of first line seen
    active_block = {}  # host -> the (host, block_id) key currently being written

    log.info("Starting slow query log daemon, tailing %s", COMBINED_FILE)

    f, current_inode = _open_tail(COMBINED_FILE)
    if f is None:
        return

    out_file, out_inode = _open_output(SLOW_LOG_OUTPUT)
    try:
        while _running:
            line = f.readline()

            if line:
                _process_line(line, blocks, block_times, active_block, out_file)
            else:
                new_inode = _get_inode(COMBINED_FILE)
                if new_inode is None or new_inode != current_inode:
                    log.info("File rotation detected, reopening %s", COMBINED_FILE)
                    f.close()
                    f, current_inode = _open_tail(COMBINED_FILE)
                    if f is None:
                        break
                    f.seek(0)
                    continue

                out_file, out_inode = _reopen_output_if_rotated(SLOW_LOG_OUTPUT, out_file, out_inode)
                _purge_stale(blocks, block_times, active_block, out_file)
                time.sleep(POLL_INTERVAL)
    finally:
        # In-flight blocks are deliberately NOT flushed on stop: one that's
        # mid-delivery can look gap-free (lines 1..k of N) and would be written
        # truncated. Losing at most the last few seconds' worth across a restart
        # is the safer trade.
        out_file.close()
        if f:
            f.close()
    log.info("Daemon stopped")


if __name__ == "__main__":
    run()
