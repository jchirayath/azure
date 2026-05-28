#!/usr/bin/env python3
"""Idempotently seed Uptime Kuma HTTP(s) monitors from a list file.

Usage: seed-uptime-kuma.py <kuma.db> <monitors.txt>

List-file lines are "Display Name|https://url"; blank lines and lines starting
with # are ignored. A monitor is inserted only when its URL is not already in
the table, so re-running just adds the new entries.

We write the row directly with sqlite3 (no admin password needed, which is why
this also works against a box whose admin was set up by hand). Only the fields
we care about are set; every other column is left to its schema DEFAULT, so this
stays compatible across Uptime Kuma 1.x schema revisions (all NOT NULL columns
carry defaults). The CALLER must stop the container before running this and
start it afterwards — Kuma caches the monitor list in memory and only reloads it
on boot.
"""
import sqlite3
import sys


def main():
    if len(sys.argv) != 3:
        print("usage: seed-uptime-kuma.py <kuma.db> <monitors.txt>", file=sys.stderr)
        return 2
    db_path, list_path = sys.argv[1], sys.argv[2]

    entries = []
    with open(list_path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            name, _, url = line.partition("|")
            name, url = name.strip(), url.strip()
            if url:
                entries.append((name or url, url))

    conn = sqlite3.connect(db_path)
    # Owner = first existing user (the admin). On a fresh install done by this
    # module the account is created at first web visit and gets id 1, so default
    # to 1 when no user row exists yet.
    row = conn.execute("SELECT id FROM user ORDER BY id LIMIT 1").fetchone()
    user_id = row[0] if row else 1

    existing = {r[0] for r in conn.execute(
        "SELECT url FROM monitor WHERE url IS NOT NULL")}

    added = 0
    for name, url in entries:
        if url in existing:
            print(f"  skip (exists): {name}  {url}")
            continue
        conn.execute(
            "INSERT INTO monitor "
            "(name, type, url, user_id, active, interval, retry_interval, maxretries, timeout) "
            "VALUES (?, 'http', ?, ?, 1, 60, 60, 1, 48)",
            (name, url, user_id),
        )
        existing.add(url)
        added += 1
        print(f"  added: {name}  {url}")

    conn.commit()
    conn.close()
    print(f"Seed complete: {added} added, {len(entries) - added} already present "
          f"(owner user_id={user_id}).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
