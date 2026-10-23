"""Local clock and durable slot claims; no network or database-server access."""
from datetime import datetime, timezone, timedelta
import os
import sqlite3

BEIJING=timezone(timedelta(hours=8))
HOURS=(0,7,12,16)
LABEL='北京时间每天07:00、12:00、16:00、00:00'

def claim_slot(path,now=None):
    now=now or datetime.now(BEIJING)
    if now.tzinfo is None:raise ValueError('Timezone required')
    now=now.astimezone(BEIJING)
    if now.hour not in HOURS or now.minute!=0:return False
    key=now.strftime('%Y-%m-%dT%H:00+08:00')
    path.parent.mkdir(parents=True,exist_ok=True)
    db=sqlite3.connect(path,timeout=5)
    try:
        os.chmod(path,0o600)
        db.execute('CREATE TABLE IF NOT EXISTS slots(slot TEXT PRIMARY KEY,claimed_at TEXT NOT NULL)')
        with db:
            cursor=db.execute('INSERT OR IGNORE INTO slots VALUES(?,?)',(key,now.isoformat()))
            return cursor.rowcount==1
    finally:db.close()
