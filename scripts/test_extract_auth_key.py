import importlib.util
from contextlib import closing
from pathlib import Path
import plistlib
import sqlite3
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("extract-auth-key.py")
spec = importlib.util.spec_from_file_location("key_import", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
KEY = "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf"  # public synthetic fixture only


class KeyImportTests(unittest.TestCase):
    def test_multiple_regions_and_archive_dictionary_are_read_without_mutation(self):
        archive = {"$objects": ["$null", {"NS.keys": [plistlib.UID(2), plistlib.UID(3)],
                    "NS.objects": [plistlib.UID(4), plistlib.UID(5)]}, "name", "encryptKey", "Synthetic Band", KEY],
                   "$top": {"root": plistlib.UID(1)}}
        with tempfile.TemporaryDirectory() as directory:
            database = Path(directory) / "manifest.sqlite"
            with closing(sqlite3.connect(database)) as connection:
                connection.execute("CREATE TABLE manifest (key TEXT, inline_data BLOB)")
                for region, data in [("cn", archive), ("de", {"encrypt_key": "0x" + KEY})]:
                    connection.execute("INSERT INTO manifest VALUES (?, ?)",
                                       ("registerList_" + region, plistlib.dumps(data, fmt=plistlib.FMT_BINARY)))
                connection.execute("INSERT INTO manifest VALUES ('unrelated', ?)", (b"not a plist",))
                connection.commit()
            original = database.read_bytes()
            records = module.extract(database)
            self.assertEqual(len(records), 1)
            self.assertEqual(records[0]["auth_key"], KEY)
            self.assertEqual(database.read_bytes(), original)
            output = Path(directory) / "private-auth-key.json"
            result = subprocess.run([sys.executable, str(SCRIPT), str(database), "--out", str(output)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0)
            self.assertNotIn(KEY, result.stdout + result.stderr)
            self.assertIn(KEY, output.read_text())
            again = subprocess.run([sys.executable, str(SCRIPT), str(database), "--out", str(output)], capture_output=True, text=True)
            self.assertEqual(again.returncode, 1)

    def test_archive_cycles_and_bad_references_are_bounded(self):
        cycle = {"$objects": [{"self": plistlib.UID(0)}], "$top": {"root": plistlib.UID(0)}}
        self.assertEqual(module.decode_archive(plistlib.dumps(cycle, fmt=plistlib.FMT_BINARY)), {"root": {"self": None}})
        cycle["$top"]["root"] = plistlib.UID(10)
        with self.assertRaises(ValueError):
            module.decode_archive(plistlib.dumps(cycle, fmt=plistlib.FMT_BINARY))

    def test_invalid_keys_are_never_exported(self):
        self.assertEqual(list(module.device_records([{"encryptKey": "x" * 32}, {"encryptKey": "ab"}])), [])


if __name__ == "__main__":
    unittest.main()
