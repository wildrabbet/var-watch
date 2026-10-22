"""Save Var Watch's last manually requested export to a local file. Never reads other plugins' rows.

Click Export (or Wiki export) in Var Watch first, then run: python tools/var_watch_export.py
The file is saved in the current folder (var-watch-export.tsv, or var-watch-export-wiki.txt for a wiki export) unless
--out says otherwise. --db points at your client's PluginData.db (default: the plugin beta client's).
The database and any WAL are copied before opening the temporary snapshot. The real database is never written.
"""
import argparse
from contextlib import closing
import json
from pathlib import Path
import shutil
import sqlite3
from tempfile import TemporaryDirectory


def decode(value):
    if isinstance(value, bytes):
        return value.decode('utf-8').rstrip('\0')
    return str(value).rstrip('\0')


def structured(value):
    if isinstance(value, list):
        if value and all(isinstance(row, dict) and 'key' in row and 'value' in row for row in value):
            return {str(row['key']): structured(row['value']) for row in value}
        return [structured(row) for row in value]
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--db', type=Path, default=Path(r'C:\ProgramData\Jagex\RuneScape-BETA\plugins\PluginData.db'))
    parser.add_argument('--out', type=Path, default=None, help='default: var-watch-export.tsv here, or var-watch-export-wiki.txt for a wiki export')
    args = parser.parse_args()
    if not args.db.is_file():
        raise SystemExit('Plugin database not found.')
    with TemporaryDirectory(prefix='nex-var-watch-export-') as temporary:
        snapshot = Path(temporary) / 'PluginData.db'
        shutil.copy2(args.db, snapshot)
        wal = Path(str(args.db) + '-wal')
        if wal.exists():
            shutil.copy2(wal, Path(str(snapshot) + '-wal'))
        with closing(sqlite3.connect(snapshot.as_uri() + '?mode=ro', uri=True)) as database:
            database.execute('BEGIN')
            row = database.execute('SELECT Value FROM DataStore WHERE PluginID=? AND Key=?',
                                   ('Var Watch', 'exportInfo')).fetchone()
            if not row:
                raise SystemExit('No export saved yet. Click Export in Var Watch first.')
            info = structured(json.loads(decode(row[0])))
            if not isinstance(info, dict) or info.get('complete') is not True:
                raise SystemExit('The last export is incomplete. Click Export again.')
            count = int(info['parts'])
            if count < 1 or count > 256:
                raise SystemExit('Invalid export part count.')
            parts = []
            for number in range(1, count + 1):
                row = database.execute('SELECT Value FROM DataStore WHERE PluginID=? AND Key=?',
                                       ('Var Watch', f'exportText{number:03d}')).fetchone()
                if not row:
                    raise SystemExit('An export part is missing. Click Export again.')
                parts.append(decode(row[0]))
    text = ''.join(parts)
    if len(text.encode('utf-8')) != int(info['bytes']):
        raise SystemExit('Export size mismatch. Click Export again.')
    if args.out is None:
        name = 'var-watch-export-wiki.txt' if info.get('mode') == 'wiki' else 'var-watch-export.tsv'
        args.out = Path.cwd() / name
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(text, encoding='utf-8', newline='')
    print(f'{int(info["rows"])} {info["mode"]} rows saved to {args.out}')


if __name__ == '__main__':
    main()
