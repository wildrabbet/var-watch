"""Read a small WAL-backed stand-in database through the real export helper, without touching live plugin data."""
from hashlib import sha256
from contextlib import closing
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
from tempfile import TemporaryDirectory

tool = Path(__file__).resolve().parents[1] / 'tools/var_watch_export.py'
with TemporaryDirectory(prefix='nex-var-export-test-') as temporary:
    root = Path(temporary)
    database_path, output = root / 'PluginData.db', root / 'export.tsv'
    text = 'ability_id\tderived_label\tgame_var_stem\n47129\tBladed Dive\tATTACK_BLADED_DIVE\n'
    info = {'complete': True, 'parts': 1, 'rows': 1, 'mode': 'abilities', 'bytes': len(text.encode('utf-8'))}
    with closing(sqlite3.connect(database_path)) as database:
        database.execute('PRAGMA journal_mode=WAL')
        database.execute('CREATE TABLE DataStore (PluginID TEXT, Key TEXT, Value BLOB)')
        database.execute('INSERT INTO DataStore VALUES (?,?,?)',
                         ('Other Plugin', 'exportInfo', b'not ours'))
        database.execute('INSERT INTO DataStore VALUES (?,?,?)',
                         ('Var Watch', 'exportInfo', json.dumps([{'key': key, 'value': value} for key, value in info.items()]).encode()))
        database.execute('INSERT INTO DataStore VALUES (?,?,?)', ('Var Watch', 'exportText001', text.encode()))
        database.commit()
        before = {p.name: sha256(p.read_bytes()).hexdigest() for p in root.glob('PluginData.db*')}
        run = subprocess.run([sys.executable, str(tool), '--db', str(database_path), '--out', str(output)],
                             capture_output=True, text=True)
        assert run.returncode == 0, run.stderr
        assert output.read_bytes() == text.encode()
        assert before == {p.name: sha256(p.read_bytes()).hexdigest() for p in root.glob('PluginData.db*')}
        info['complete'] = False
        database.execute('UPDATE DataStore SET Value=? WHERE PluginID=? AND Key=?',
                         (json.dumps(info).encode(), 'Var Watch', 'exportInfo'))
        database.commit()
        refused = root / 'refused.tsv'
        run = subprocess.run([sys.executable, str(tool), '--db', str(database_path), '--out', str(refused)],
                             capture_output=True, text=True)
        assert run.returncode != 0 and not refused.exists() and 'incomplete' in run.stderr
print('Var Watch export tool: WAL snapshot, exact file, foreign-row isolation, read-only input, incomplete rejection passed')
