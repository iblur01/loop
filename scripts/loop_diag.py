#!/usr/bin/env python3
"""Loop — outil de diagnostic local de la chaîne de données.

Imprime: chemin DB/cache, deviceIds présents, count par table, min/max ts,
jours couverts, état du cache.json, derniers dérivés.

Usage:
    python3 scripts/loop_diag.py [chemin/vers/whoop.sqlite]

Sans argument: cherche la DB dans les simulateurs iOS (CoreSimulator).
Sur device réel, exporter le conteneur via Xcode (Devices > Download Container)
puis pointer vers .../AppData/Library/Application Support/Loop/whoop.sqlite.
"""
import sys
import os
import json
import glob
import sqlite3
from datetime import datetime, timezone

# Tables RAW (durables) et dérivées (cache miroir) — ts en epoch seconds.
TS_TABLES = [
    "hrSample", "rrInterval", "gravitySample", "respSample",
    "spo2Sample", "skinTempSample", "battery", "event",
]
DAY_TABLES = ["dailyMetric", "sleepSession", "adviceSignal"]  # startTs pour sleepSession


def find_db(arg):
    if arg:
        return arg
    pat = os.path.expanduser(
        "~/Library/Developer/CoreSimulator/Devices/*/data/Containers/Data/"
        "Application/*/Library/Application Support/Loop/whoop.sqlite"
    )
    hits = glob.glob(pat)
    if not hits:
        sys.exit("Aucune DB trouvée dans les simulateurs. Fournir le chemin en argument "
                 "(device réel: exporter le conteneur via Xcode).")
    # Plus récemment modifiée
    return max(hits, key=os.path.getmtime)


def fmt_ts(ts):
    if ts is None:
        return "—"
    try:
        return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    except (OSError, ValueError, OverflowError):
        return f"?({ts})"


def table_exists(cur, name):
    cur.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,))
    return cur.fetchone() is not None


def cols(cur, name):
    cur.execute(f"PRAGMA table_info({name})")
    return [r[1] for r in cur.fetchall()]


def main():
    db = find_db(sys.argv[1] if len(sys.argv) > 1 else None)
    print(f"DB        : {db}")
    print(f"taille    : {os.path.getsize(db)/1024/1024:.2f} Mo")
    cache = os.path.join(os.path.dirname(db), "cache.json")
    conf = os.path.join(os.path.dirname(db), "configuration.json")

    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    cur = con.cursor()

    # deviceIds présents (union sur les tables qui ont la colonne)
    devices = set()
    for t in TS_TABLES + DAY_TABLES:
        if table_exists(cur, t) and "deviceId" in cols(cur, t):
            cur.execute(f"SELECT DISTINCT deviceId FROM {t}")
            devices.update(r[0] for r in cur.fetchall())
    print(f"\ndeviceIds : {sorted(devices) or '—'}")
    if len(devices) > 1:
        print("  ⚠️  PLUSIEURS deviceIds — race my-whoop/theo-whoop probable (cf. DIAGNOSIS §P1)")

    print(f"\n{'table':<16}{'deviceId':<14}{'rows':>10}  min_ts → max_ts (jours)")
    print("-" * 78)
    for t in TS_TABLES:
        if not table_exists(cur, t):
            continue
        ts_col = "ts"
        for dev in (sorted(devices) or [None]):
            where = "WHERE deviceId=?" if dev else ""
            args = (dev,) if dev else ()
            cur.execute(f"SELECT COUNT(*), MIN({ts_col}), MAX({ts_col}) FROM {t} {where}", args)
            n, mn, mx = cur.fetchone()
            if not n:
                continue
            days = ""
            if mn and mx:
                d = (mx - mn) / 86400
                days = f"({d:.1f}j)"
            print(f"{t:<16}{(dev or '*'):<14}{n:>10}  {fmt_ts(mn)} → {fmt_ts(mx)} {days}")

    # Tables dérivées
    print(f"\n{'table dérivée':<16}{'deviceId':<14}{'rows':>10}  étendue")
    print("-" * 78)
    for t in DAY_TABLES:
        if not table_exists(cur, t):
            continue
        c = cols(cur, t)
        key = "day" if "day" in c else ("startTs" if "startTs" in c else None)
        for dev in (sorted(devices) or [None]):
            where = "WHERE deviceId=?" if (dev and "deviceId" in c) else ""
            args = (dev,) if where else ()
            cur.execute(f"SELECT COUNT(*), MIN({key}), MAX({key}) FROM {t} {where}", args)
            n, mn, mx = cur.fetchone()
            if not n:
                continue
            extent = f"{mn} → {mx}" if key == "day" else f"{fmt_ts(mn)} → {fmt_ts(mx)}"
            print(f"{t:<16}{(dev or '*'):<14}{n:>10}  {extent}")

    con.close()

    # cache.json
    print("\ncache.json :", cache)
    if os.path.exists(cache):
        try:
            with open(cache) as f:
                c = json.load(f)
            daily = c.get("daily", [])
            sleeps = c.get("sleepSessions", [])
            print(f"  updatedAt      : {c.get('updatedAt')}")
            print(f"  daily          : {len(daily)} jours")
            print(f"  sleepSessions  : {len(sleeps)}")
            print(f"  hrSamples      : {len(c.get('hrSamples', []))}")
            # alerte sessions sommeil anormalement longues
            for s in sleeps:
                st, en = s.get("startTs"), s.get("endTs")
                if st and en and (en - st) > 18 * 3600:
                    h = (en - st) / 3600
                    print(f"  ⚠️  session sommeil {h:.1f}h — bug segmentation (DIAGNOSIS §P3)")
        except (json.JSONDecodeError, OSError) as e:
            print(f"  ⚠️  cache illisible: {e}")
    else:
        print("  (absent — UI affichera 0 jusqu'au premier compute)")

    if os.path.exists(conf):
        try:
            with open(conf) as f:
                cf = json.load(f)
            print(f"\nconfiguration.json : deviceID={cf.get('deviceID')!r} serverURL={cf.get('serverURL')!r}")
        except (json.JSONDecodeError, OSError):
            pass


if __name__ == "__main__":
    main()
