#!/usr/bin/env python3
"""
export_advice_fixtures.py — Generate parity fixtures for AdviceEngine.compute().

Port of advice.py compute_advice() — produces compute_advice.json covering all
branches: cold_start, red_recovery, yellow_recovery, green_recovery, earlier_bedtime.

Output: Packages/LoopStrapEngine/Tests/LoopStrapEngineTests/Resources/fixtures/advice/compute_advice.json

Usage:
    python3 scripts/export_advice_fixtures.py
"""

import json
import os
import datetime
from typing import Optional

# ---------------------------------------------------------------------------
# Tunable constants — mirrors advice.py [ASSUMED] tunable section
# ---------------------------------------------------------------------------
SLEEP_DEBT_WINDOW_NIGHTS = 5
SLEEP_DEBT_THRESHOLD_MIN = 90.0
EARLIER_BEDTIME_OFFSET_MIN = 20.0
EFFORT_TARGET_YELLOW_FACTOR = 0.7
EFFORT_TARGET_RED_CEILING = 4.0
EFFORT_TARGET_TREND_WINDOW_DAYS = 3

# Independence note: _CONFIDENCE_MAP duplicated from recovery.py intentionally.
_CONFIDENCE_MAP = {"low": "low", "medium": "medium", "high": "high"}


# ---------------------------------------------------------------------------
# Helper — serialise params to the same structure AdviceEngine.swift produces
# ---------------------------------------------------------------------------
def _params_json(params: dict) -> str:
    """Compact JSON, keys sorted (matches JSONSerialization .sortedKeys)."""
    return json.dumps(params, sort_keys=True, separators=(",", ":"))


# ---------------------------------------------------------------------------
# Port of advice.py sub-functions
# ---------------------------------------------------------------------------
def bedtime_offset_minutes(ts: float) -> float:
    """Offset in minutes from noon UTC, wrapped to (-720, 720]."""
    dt = datetime.datetime.utcfromtimestamp(ts)
    minutes_since_midnight = dt.hour * 60 + dt.minute + dt.second / 60.0
    offset = minutes_since_midnight - 12.0 * 60.0
    if offset <= -720.0:
        offset += 1440.0
    elif offset > 720.0:
        offset -= 1440.0
    return offset


def _primary_advice(recovery: dict) -> tuple:
    score = recovery.get("score")
    band = recovery.get("band")
    confidence = recovery.get("confidence", "low")
    conf = _CONFIDENCE_MAP.get(confidence, confidence)
    if score is None or band is None:
        return "RECOVERY_CALIBRATING", {}, conf
    params = {"score": float(score)}
    if band == "red":
        return "REST_RED_RECOVERY", params, conf
    elif band == "yellow":
        return "MODERATE_YELLOW_RECOVERY", params, conf
    else:
        return "NORMAL_TRAINING_GREEN_RECOVERY", params, conf


def _compute_sleep_debt(sleep_history: list, duration_baseline: Optional[dict]) -> Optional[float]:
    if duration_baseline is None or not duration_baseline.get("usable", False):
        return None
    window = SLEEP_DEBT_WINDOW_NIGHTS
    valid = [v for v in sleep_history[-window:] if v is not None]
    if len(valid) < window:
        return None
    expected = duration_baseline["baseline"] * window
    actual = sum(valid)
    return max(0.0, expected - actual)


def _sleep_debt_advice(debt_min: Optional[float], duration_baseline: Optional[dict]) -> Optional[dict]:
    if debt_min is None or debt_min < SLEEP_DEBT_THRESHOLD_MIN:
        return None
    usable = duration_baseline and duration_baseline.get("usable", False)
    conf = _CONFIDENCE_MAP.get("high" if usable else "medium", "medium")
    params = {
        "debt_min": debt_min,
        "window_nights": float(SLEEP_DEBT_WINDOW_NIGHTS)
    }
    return {"code": "SLEEP_DEBT", "params_json": _params_json(params), "confidence": conf}


def _earlier_bedtime_advice(
    tonight_bedtime_offset: Optional[float],
    bedtime_baseline: Optional[dict],
    debt_min: Optional[float]
) -> Optional[dict]:
    if tonight_bedtime_offset is None:
        return None
    if bedtime_baseline is None or not bedtime_baseline.get("usable", False):
        return None
    if debt_min is None or debt_min <= 0:
        return None
    drift = tonight_bedtime_offset - bedtime_baseline["baseline"]
    if drift <= EARLIER_BEDTIME_OFFSET_MIN:
        return None
    params = {
        "baseline_offset_min": bedtime_baseline["baseline"],
        "debt_min": debt_min,
        "drift_min": drift,
        "tonight_offset_min": tonight_bedtime_offset,
    }
    conf = _CONFIDENCE_MAP.get("high" if bedtime_baseline.get("usable") else "medium", "medium")
    return {"code": "EARLIER_BEDTIME", "params_json": _params_json(params), "confidence": conf}


def _effort_target_advice(
    recovery: dict,
    strain_baseline: Optional[dict],
    recent_strain_history: list
) -> dict:
    usable = strain_baseline is not None and strain_baseline.get("usable", False)
    baseline = strain_baseline["baseline"] if usable else None
    band = recovery.get("band")
    target_strain = None
    if baseline is not None and band is not None:
        if band == "red":
            target_strain = min(EFFORT_TARGET_RED_CEILING, baseline)
        elif band == "yellow":
            target_strain = baseline * EFFORT_TARGET_YELLOW_FACTOR
        else:
            target_strain = baseline

    recent_overload = False
    if baseline is not None:
        window = EFFORT_TARGET_TREND_WINDOW_DAYS
        recent = [v for v in recent_strain_history[-window:] if v is not None]
        recent_overload = any(v > baseline for v in recent)

    params: dict = {"recent_overload": recent_overload}
    if target_strain is not None:
        params["target_strain"] = target_strain
    if baseline is not None:
        params["strain_baseline"] = baseline

    conf = _CONFIDENCE_MAP.get("high" if usable else "medium", "low")
    if strain_baseline is None:
        conf = "low"
    return {"code": "EFFORT_TARGET", "params_json": _params_json(params), "confidence": conf}


def compute_advice(
    recovery: dict,
    sleep_history: list,
    duration_baseline: Optional[dict] = None,
    bedtime_baseline: Optional[dict] = None,
    tonight_bedtime_offset: Optional[float] = None,
    strain_baseline: Optional[dict] = None,
    recent_strain_history: Optional[list] = None
) -> dict:
    """Port of advice.py compute_advice() — returns structured dict for fixture serialisation."""
    if recent_strain_history is None:
        recent_strain_history = []

    primary_code, primary_params, primary_conf = _primary_advice(recovery)
    debt_min = _compute_sleep_debt(sleep_history, duration_baseline)

    secondary = []
    s = _sleep_debt_advice(debt_min, duration_baseline)
    if s:
        secondary.append(s)
    e = _earlier_bedtime_advice(tonight_bedtime_offset, bedtime_baseline, debt_min)
    if e:
        secondary.append(e)
    secondary.append(_effort_target_advice(recovery, strain_baseline, recent_strain_history))

    return {
        "primary_code":       primary_code,
        "primary_params":     primary_params,
        "primary_confidence": primary_conf,
        "secondary":          secondary,
    }


# ---------------------------------------------------------------------------
# Fixture cases
# ---------------------------------------------------------------------------

def _make_baseline(baseline: float, spread: float, n_valid: int, status: str) -> dict:
    return {
        "baseline":            baseline,
        "spread":              spread,
        "n_valid":             n_valid,
        "nights_since_update": 0,
        "status":              status,
        "usable":              status in ("provisional", "trusted"),
    }


CASES = []

# ── cold_start ──────────────────────────────────────────────────────────────
recovery_cold = {"score": None, "band": None, "confidence": "low"}
result_cold = compute_advice(
    recovery=recovery_cold,
    sleep_history=[None, None, None, None, None],
)
CASES.append({
    "name": "cold_start",
    "inputs": {
        "recovery":               recovery_cold,
        "sleep_history":          [None, None, None, None, None],
        "duration_baseline":      None,
        "bedtime_baseline":       None,
        "tonight_bedtime_offset": None,
        "strain_baseline":        None,
        "recent_strain_history":  [],
    },
    "expected": result_cold,
})

# ── red_recovery (with sleep debt) ──────────────────────────────────────────
dur_baseline_red = _make_baseline(baseline=480.0, spread=30.0, n_valid=30, status="trusted")
# Each night 60–90 min short → 5 night deficit > 90 min threshold
sleep_hist_red = [420.0, 400.0, 410.0, 390.0, 380.0]   # 5 nights, 200 min deficit
strain_bl_red = _make_baseline(baseline=10.0, spread=2.0, n_valid=20, status="trusted")
recovery_red = {"score": 25.0, "band": "red", "confidence": "high"}
result_red = compute_advice(
    recovery=recovery_red,
    sleep_history=sleep_hist_red,
    duration_baseline=dur_baseline_red,
    strain_baseline=strain_bl_red,
    recent_strain_history=[9.0, 11.0, 12.0],
)
CASES.append({
    "name": "red_recovery",
    "inputs": {
        "recovery":               recovery_red,
        "sleep_history":          sleep_hist_red,
        "duration_baseline":      dur_baseline_red,
        "bedtime_baseline":       None,
        "tonight_bedtime_offset": None,
        "strain_baseline":        strain_bl_red,
        "recent_strain_history":  [9.0, 11.0, 12.0],
    },
    "expected": result_red,
})

# ── yellow_recovery ─────────────────────────────────────────────────────────
dur_baseline_yellow = _make_baseline(baseline=450.0, spread=20.0, n_valid=15, status="provisional")
sleep_hist_yellow = [445.0, 460.0, 455.0, 440.0, 448.0]  # minimal debt < threshold
strain_bl_yellow = _make_baseline(baseline=12.0, spread=1.5, n_valid=20, status="trusted")
recovery_yellow = {"score": 55.0, "band": "yellow", "confidence": "medium"}
result_yellow = compute_advice(
    recovery=recovery_yellow,
    sleep_history=sleep_hist_yellow,
    duration_baseline=dur_baseline_yellow,
    strain_baseline=strain_bl_yellow,
    recent_strain_history=[10.0, 11.0, 11.5],
)
CASES.append({
    "name": "yellow_recovery",
    "inputs": {
        "recovery":               recovery_yellow,
        "sleep_history":          sleep_hist_yellow,
        "duration_baseline":      dur_baseline_yellow,
        "bedtime_baseline":       None,
        "tonight_bedtime_offset": None,
        "strain_baseline":        strain_bl_yellow,
        "recent_strain_history":  [10.0, 11.0, 11.5],
    },
    "expected": result_yellow,
})

# ── green_recovery (with effort target) ─────────────────────────────────────
dur_baseline_green = _make_baseline(baseline=480.0, spread=25.0, n_valid=30, status="trusted")
sleep_hist_green = [480.0, 490.0, 475.0, 485.0, 480.0]  # adequate sleep — no debt
strain_bl_green = _make_baseline(baseline=14.0, spread=2.0, n_valid=25, status="trusted")
recovery_green = {"score": 82.0, "band": "green", "confidence": "high"}
result_green = compute_advice(
    recovery=recovery_green,
    sleep_history=sleep_hist_green,
    duration_baseline=dur_baseline_green,
    strain_baseline=strain_bl_green,
    recent_strain_history=[12.0, 13.0, 14.0],
)
CASES.append({
    "name": "green_recovery",
    "inputs": {
        "recovery":               recovery_green,
        "sleep_history":          sleep_hist_green,
        "duration_baseline":      dur_baseline_green,
        "bedtime_baseline":       None,
        "tonight_bedtime_offset": None,
        "strain_baseline":        strain_bl_green,
        "recent_strain_history":  [12.0, 13.0, 14.0],
    },
    "expected": result_green,
})

# ── earlier_bedtime ──────────────────────────────────────────────────────────
# Tonight bedtime is significantly later than baseline (drift > 20 min)
# and there is sleep debt → EARLIER_BEDTIME secondary emitted.
dur_baseline_ebt = _make_baseline(baseline=480.0, spread=30.0, n_valid=30, status="trusted")
# 5 nights with significant deficit (480 baseline, 5 nights short → 200 min debt)
sleep_hist_ebt = [420.0, 440.0, 430.0, 425.0, 435.0]
# Bedtime baseline = -60 min from noon = 23:00 UTC
bedtime_bl = _make_baseline(baseline=-60.0, spread=10.0, n_valid=20, status="trusted")
# Tonight bedtime offset = -60 + 40 = -20 min from noon, i.e. 23:40 UTC  (drift = 40 min > 20)
tonight_offset = -20.0
recovery_ebt = {"score": 45.0, "band": "yellow", "confidence": "medium"}
strain_bl_ebt = _make_baseline(baseline=10.0, spread=2.0, n_valid=20, status="trusted")
result_ebt = compute_advice(
    recovery=recovery_ebt,
    sleep_history=sleep_hist_ebt,
    duration_baseline=dur_baseline_ebt,
    bedtime_baseline=bedtime_bl,
    tonight_bedtime_offset=tonight_offset,
    strain_baseline=strain_bl_ebt,
    recent_strain_history=[9.0, 10.0, 10.5],
)
CASES.append({
    "name": "earlier_bedtime",
    "inputs": {
        "recovery":               recovery_ebt,
        "sleep_history":          sleep_hist_ebt,
        "duration_baseline":      dur_baseline_ebt,
        "bedtime_baseline":       bedtime_bl,
        "tonight_bedtime_offset": tonight_offset,
        "strain_baseline":        strain_bl_ebt,
        "recent_strain_history":  [9.0, 10.0, 10.5],
    },
    "expected": result_ebt,
})

# ---------------------------------------------------------------------------
# Write fixture file
# ---------------------------------------------------------------------------

FIXTURE = {
    "module":          "advice",
    "function":        "compute_advice",
    "oracle_git_sha":  "standalone-07-01",
    "oracle_versions": {},
    "exported_at":     datetime.datetime.utcnow().isoformat() + "Z",
    "cases":           CASES,
}

OUT_DIR = os.path.join(
    os.path.dirname(__file__),
    "..",
    "Packages",
    "LoopStrapEngine",
    "Tests",
    "LoopStrapEngineTests",
    "Resources",
    "fixtures",
    "advice",
)
OUT_PATH = os.path.join(OUT_DIR, "compute_advice.json")

os.makedirs(OUT_DIR, exist_ok=True)

with open(OUT_PATH, "w", encoding="utf-8") as f:
    json.dump(FIXTURE, f, indent=2)

print(f"Wrote {len(CASES)} cases → {os.path.normpath(OUT_PATH)}")
for c in CASES:
    print(f"  [{c['name']}] primary_code={c['expected']['primary_code']}, "
          f"secondary=[{', '.join(s['code'] for s in c['expected']['secondary'])}]")
