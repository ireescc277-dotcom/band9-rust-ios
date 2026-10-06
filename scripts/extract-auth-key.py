#!/usr/bin/env python3
"""Read an owner's exported Mi Fitness cache; never print secrets or alter SQLite.

No phone sandbox bypass or full-device backup is performed. Use an exported
directory, or one VirtualDevice_registerList/manifest.sqlite as the input.
"""
import argparse
from contextlib import closing
import json
import os
from pathlib import Path
import plistlib
import re
import sqlite3
import sys

MAX_BLOB = 8 * 1024 * 1024
MAX_NODES = 100_000


def decode_archive(blob):
    if len(blob) > MAX_BLOB:
        raise ValueError("Register-list cache exceeds the size limit")
    archive = plistlib.loads(blob)
    if not isinstance(archive, dict) or "$objects" not in archive:
        return archive
    objects = archive["$objects"]
    if not isinstance(objects, list) or len(objects) > MAX_NODES:
        raise ValueError("Invalid archive object table")
    budget = [MAX_NODES]

    def expand(value, stack=frozenset(), depth=0):
        budget[0] -= 1
        if budget[0] < 0 or depth > 64:
            raise ValueError("Archive graph exceeds traversal limits")
        if isinstance(value, plistlib.UID):
            index = value.data
            if index in stack:
                return None
            if index >= len(objects):
                raise ValueError("Archive contains an invalid object reference")
            return expand(objects[index], stack | {index}, depth + 1)
        if isinstance(value, list):
            return [expand(item, stack, depth + 1) for item in value]
        if isinstance(value, dict):
            if "NS.keys" in value and "NS.objects" in value:
                keys = expand(value["NS.keys"], stack, depth + 1)
                values = expand(value["NS.objects"], stack, depth + 1)
                if not isinstance(keys, list) or not isinstance(values, list) or len(keys) != len(values):
                    raise ValueError("Invalid archived dictionary")
                return {key: item for key, item in zip(keys, values) if isinstance(key, str)}
            if "NS.objects" in value:
                return expand(value["NS.objects"], stack, depth + 1)
            return {key: expand(item, stack, depth + 1) for key, item in value.items() if key != "$class"}
        return None if value == "$null" else value

    return expand(archive.get("$top", {}))


def device_records(root):
    pending = [root]
    count = 0
    while pending:
        item = pending.pop()
        count += 1
        if count > MAX_NODES:
            raise ValueError("Too many register-list entries")
        if isinstance(item, list):
            pending.extend(item)
        elif isinstance(item, dict):
            key = item.get("encryptKey", item.get("encrypt_key"))
            if isinstance(key, str):
                key = key.strip().lower().removeprefix("0x")
                if re.fullmatch(r"[0-9a-f]{32}", key):
                    def field(*names):
                        return next((str(item[name]) for name in names if item.get(name)), "")
                    yield {"name": field("name"), "model": field("model"),
                           "mac": field("mac", "randomMac"),
                           "peripheral_id": field("peripheralID", "huamiBleUUID"), "auth_key": key}
            pending.extend(value for value in item.values() if isinstance(value, (list, dict)))


def extract(source):
    source = source.resolve(strict=True)
    manifests = [source] if source.is_file() else sorted(source.glob("**/VirtualDevice_registerList/manifest.sqlite"))
    if len(manifests) > 256:
        raise ValueError("Too many candidate cache databases")
    records, seen, total_bytes = [], set(), 0
    for manifest in manifests:
        # URI read-only mode allows SQLite to see accompanying WAL files without
        # creating a database or changing journal mode. Copy exported sidecars too.
        with closing(sqlite3.connect(manifest.as_uri() + "?mode=ro", uri=True)) as database:
            database.execute("PRAGMA query_only=ON")
            rows = database.execute("SELECT key, inline_data FROM manifest WHERE key GLOB 'registerList_*' AND length(inline_data) <= ? LIMIT 257", (MAX_BLOB,))
            for row_number, (_, blob) in enumerate(rows):
                if row_number >= 256:
                    raise ValueError("Too many register-list regions")
                if not isinstance(blob, bytes) or not blob:
                    continue
                total_bytes += len(blob)
                if total_bytes > 32 * 1024 * 1024:
                    raise ValueError("Export exceeds the aggregate cache limit")
                for record in device_records(decode_archive(blob)):
                    identity = (record["peripheral_id"], record["mac"], record["auth_key"])
                    if identity not in seen:
                        seen.add(identity)
                        records.append(record)
                        if len(records) > 256:
                            raise ValueError("Too many device records")
    return records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Exported Mi Fitness directory or register-list manifest.sqlite")
    parser.add_argument("--out", type=Path, required=True, help="New private JSON file for local app import; existing files are not overwritten")
    args = parser.parse_args()
    try:
        records = extract(args.source)
        if not records:
            print("No valid device auth key found in this export.", file=sys.stderr)
            return 2
        output = args.out.resolve()
        # Deliberately exclusive; a key export must never silently replace a file.
        descriptor = os.open(output, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump({"schema_version": 1, "devices": records}, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
        print(f"Saved {len(records)} device record(s) to the requested private file. No key was printed.")
        return 0
    except (OSError, ValueError, sqlite3.Error, plistlib.InvalidFileException):
        # Don't echo exception values: malformed exported data could contain keys.
        print("Could not read the export or create the output. Check paths, cache format and output file existence.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
