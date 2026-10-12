#!/usr/bin/env python3
"""Install a verified staged release after the desktop app has been quit."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import sqlite3
import subprocess
from datetime import datetime


def checksum(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for part in iter(lambda: stream.read(65536), b''):
            result.update(part)
    return result.hexdigest()


def install(stage):
    root = Path(__file__).resolve().parent.parent
    app_name = 'Internet Downloader.app'
    source_app = stage / app_name
    version = plistlib.loads((source_app / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
    manifest = json.loads((stage / 'Extension/manifest.json').read_text())
    digest = hashlib.sha256(__import__('base64').b64decode(manifest['key'])).hexdigest()[:32]
    extension_id = ''.join(chr(97 + int(letter, 16)) for letter in digest)
    if (version, manifest['version'], extension_id) != ('1.1.0', '1.3.0', 'nljinpcahdihnlhidjdacnhlchlpblnk'):
        raise SystemExit('Release version/extension identity mismatch')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(source_app)], check=True)
    if subprocess.run(['pgrep', '-f', '/Contents/MacOS/InternetDownloader$'], stdout=subprocess.DEVNULL).returncode == 0:
        raise SystemExit('Quit Internet Downloader after all jobs finish, then install again')
    database = Path.home() / 'Library/Application Support/InternetDownloader/downloader.sqlite3'
    connection = sqlite3.connect(database)
    if connection.execute("select count(*) from tasks where status in ('pending','downloading','assembling','needs_confirmation')").fetchone()[0]:
        raise SystemExit('Pending/active browser or HTTP jobs prevent rollout')
    backup = root / '.runtime' / ('rollout-' + datetime.now().strftime('%Y%m%d-%H%M%S'))
    backup.mkdir(parents=True, mode=0o700)
    with sqlite3.connect(backup / 'before.sqlite3') as target:
        connection.backup(target)
    os.chmod(backup / 'before.sqlite3', 0o600)
    columns = [row[1] for row in connection.execute('pragma table_info(tasks)')]
    rows = [dict(zip(columns, row)) for row in connection.execute('select * from tasks')]
    outputs = []
    for row in rows:
        path = Path(row['destination_folder']) / row['filename']
        if path.is_file():
            outputs.append({'id': row['id'], 'path': str(path), 'bytes': path.stat().st_size, 'sha256': checksum(path)})
    state = {'columns': columns, 'rows': {row['id']: hashlib.sha256(json.dumps(row, sort_keys=True).encode()).hexdigest() for row in rows}, 'outputs': outputs}
    state_path = backup / 'before-state.json'
    state_path.write_text(json.dumps(state, indent=2)); os.chmod(state_path, 0o600)
    host = Path.home() / 'Library/Application Support/Google/Chrome/NativeMessagingHosts/com.internetdownloader.host.json'
    if host.exists():
        shutil.copy2(host, backup / 'native-host-before.json')
    dist = root / 'dist'; dist.mkdir(exist_ok=True)
    # Prepare all replacements before moving the installed release.
    replacements = []
    for name in [app_name, 'Extension', 'Internet-Downloader-Extension.zip']:
        source = stage / name
        next_path = dist / (name + '.next')
        if next_path.exists():
            raise SystemExit('A previous staging replacement remains: ' + str(next_path))
        if source.is_dir():
            shutil.copytree(source, next_path)
        else:
            shutil.copy2(source, next_path)
        replacements.append((name, next_path))
    if subprocess.run(['pgrep', '-f', '/Contents/MacOS/InternetDownloader$'], stdout=subprocess.DEVNULL).returncode == 0 or connection.execute("select count(*) from tasks where status in ('pending','downloading','assembling','needs_confirmation')").fetchone()[0]:
        for _, next_path in replacements:
            if next_path.is_dir():
                shutil.rmtree(next_path)
            else:
                next_path.unlink()
        raise SystemExit('App/jobs changed while preparing; existing release preserved')
    for name, next_path in replacements:
        target = dist / name
        if target.exists():
            target.rename(backup / name)
        next_path.rename(target)
    host.parent.mkdir(parents=True, exist_ok=True)
    host.write_text(json.dumps({'name': 'com.internetdownloader.host', 'description': 'Internet Downloader browser protocol 2',
        'path': str(dist / app_name / 'Contents/Helpers/internet-downloader-host'), 'type': 'stdio',
        'allowed_origins': ['chrome-extension://' + extension_id + '/']}, indent=2) + '\n')
    os.chmod(host, 0o600)
    print(json.dumps({'appVersion': version, 'extensionVersion': manifest['version'], 'backup': str(backup), 'originalRows': len(rows), 'outputs': len(outputs)}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stage', type=Path, required=True)
    install(parser.parse_args().stage.resolve())
