#!/usr/bin/env python3
"""Benchmark all Tabbit models on Chinese->English translation.

Fetches the model list, runs the same translation prompt against each model
**in parallel**, measures latency, scores the English output heuristically,
prints a ranked table, and recommends a fast + high-quality option.

Usage (from repo root):
    python test/test_chinese_translate_bench.py
    python test/test_chinese_translate_bench.py --workers 12
    python test/test_chinese_translate_bench.py --free-only --timeout 45
    python test/test_chinese_translate_bench.py --limit 5
"""

from __future__ import annotations

import argparse
import builtins
import json
import queue
import re
import sys
import threading
import time
from concurrent.futures import FIRST_COMPLETED, Future, ThreadPoolExecutor, wait
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tabbit_client import TabbitClient, build_chat_body  # noqa: E402

SOURCE_ZH = (
    "在人工智能快速发展的今天，如何在保证数据隐私的前提下提升模型推理速度，"
    "已成为企业部署大模型时最关注的问题之一。"
)

PROMPT = (
    "Translate the following Chinese text into natural, accurate English. "
    "Output ONLY the English translation, with no quotes, notes, or pinyin.\n\n"
    f"{SOURCE_ZH}"
)

EXPECTED_ANCHORS = [
    r"artificial intelligence|ai\b",
    r"rapid(?:ly)?\s+(?:develop|growth|advanc)|fast[- ]develop",
    r"data privacy|privacy of data|protect(?:ing)? data",
    r"inference speed|speed of (?:model )?inference|reasoning speed|"
    r"model inference|inference (?:latency|performance)",
    r"enterprise|compan(?:y|ies)|business(?:es)?|organization",
    r"deploy(?:ment|ing)?|roll(?:ing)? out",
    r"large (?:language )?model|llm|foundation model|big model",
    r"concern|focus|priority|critical|key (?:issue|question|challenge)",
]

REFERENCE_EN = (
    "In today's era of rapid AI development, how to improve model inference "
    "speed while ensuring data privacy has become one of the top concerns for "
    "enterprises deploying large models."
)


@dataclass
class ModelResult:
    name: str
    access: str
    status: str
    first_token_s: float | None = None
    total_s: float | None = None
    chars: int = 0
    quality: float = 0.0
    anchors_hit: int = 0
    anchors_total: int = len(EXPECTED_ANCHORS)
    leftover_zh: int = 0
    error: str = ""
    translation: str = ""
    notes: list[str] = field(default_factory=list)

    @property
    def speed_score(self) -> float:
        if self.status != "ok" or self.first_token_s is None:
            return 0.0
        ft = max(0.0, 50.0 * (1.0 - min(self.first_token_s, 8.0) / 8.0))
        tot = self.total_s or self.first_token_s
        tt = max(0.0, 50.0 * (1.0 - min(tot, 20.0) / 20.0))
        return round(ft + tt, 1)

    @property
    def combined(self) -> float:
        if self.status != "ok":
            return 0.0
        return round(0.65 * self.quality + 0.35 * self.speed_score, 1)


def _strip_thinking_noise(text: str) -> str:
    t = text.strip()
    m = re.fullmatch(r"```(?:\w+)?\s*([\s\S]*?)\s*```", t)
    if m:
        t = m.group(1).strip()
    parts = [p.strip() for p in re.split(r"\n\s*\n", t) if p.strip()]
    if len(parts) > 1:
        def eng_score(p: str) -> int:
            return sum(1 for c in p if ("a" <= c.lower() <= "z"))
        t = max(parts, key=eng_score)
    return t.strip().strip('"').strip("'")


def score_translation(text: str) -> tuple[float, int, int, list[str]]:
    notes: list[str] = []
    cleaned = _strip_thinking_noise(text)
    if not cleaned:
        return 0.0, 0, 0, ["empty output"]

    zh_chars = len(re.findall(r"[\u4e00-\u9fff]", cleaned))
    if zh_chars:
        notes.append(f"{zh_chars} Chinese chars left in output")

    hits = 0
    for pat in EXPECTED_ANCHORS:
        if re.search(pat, cleaned, flags=re.I):
            hits += 1
    cover = hits / len(EXPECTED_ANCHORS)

    words = len(re.findall(r"[A-Za-z]+(?:'[A-Za-z]+)?", cleaned))
    if words < 8:
        notes.append("too short")
        len_score = 0.2
    elif words > 80:
        notes.append("too verbose")
        len_score = 0.55
    elif 12 <= words <= 50:
        len_score = 1.0
    else:
        len_score = 0.8

    meta_pen = 0.0
    if re.search(
        r"\b(as an ai|i will translate|here is the translation|"
        r"sure[,!]?\s+here|translation:)\b",
        cleaned,
        re.I,
    ):
        notes.append("meta/chatty preamble")
        meta_pen = 0.15

    latin = len(re.findall(r"[A-Za-z]", cleaned))
    total_letters = max(1, latin + zh_chars)
    latin_ratio = latin / total_letters

    quality = 100.0 * (
        0.55 * cover
        + 0.20 * len_score
        + 0.15 * latin_ratio
        + 0.10 * (1.0 if zh_chars == 0 else max(0.0, 1.0 - zh_chars / 20.0))
    )
    quality = max(0.0, quality * (1.0 - meta_pen))
    return round(quality, 1), hits, zh_chars, notes


def _run_one_worker(
    client: TabbitClient,
    model_name: str,
    access: str,
    timeout: float,
) -> ModelResult:
    result = ModelResult(name=model_name, access=access, status="error")
    body = build_chat_body(text=PROMPT, model=model_name)
    chunks: list[str] = []
    t0 = time.perf_counter()
    first_token_s: float | None = None
    server_error = ""
    deadline = t0 + timeout

    try:
        for etype, payload in client.chat_completion(
            body, timeout=(15.0, min(30.0, timeout))
        ):
            now = time.perf_counter()
            if now > deadline:
                raise TimeoutError(f"wall-clock timeout after {timeout:.0f}s")
            if etype == "message_chunk" and isinstance(payload, dict):
                piece = payload.get("content") or ""
                if piece:
                    if first_token_s is None:
                        first_token_s = now - t0
                    chunks.append(str(piece))
            elif etype == "error":
                if isinstance(payload, dict):
                    server_error = (
                        f"{payload.get('code', '?')}: "
                        f"{payload.get('message') or payload.get('error') or payload}"
                    )
                else:
                    server_error = str(payload)
            elif etype == "finish":
                if chunks:
                    break
        total_s = time.perf_counter() - t0
    except SystemExit as e:
        result.error = str(e).strip().splitlines()[0][:180]
        result.total_s = round(time.perf_counter() - t0, 2)
        return result
    except Exception as e:  # noqa: BLE001
        result.error = f"{type(e).__name__}: {e}"[:180]
        result.total_s = round(time.perf_counter() - t0, 2)
        text_partial = "".join(chunks).strip()
        if text_partial:
            quality, hits, zh_left, notes = score_translation(text_partial)
            result.status = "ok"
            result.first_token_s = round(first_token_s or result.total_s, 2)
            result.chars = len(text_partial)
            result.quality = quality
            result.anchors_hit = hits
            result.leftover_zh = zh_left
            result.translation = _strip_thinking_noise(text_partial)
            result.notes = notes + [f"ended with: {result.error[:80]}"]
            result.error = ""
        return result

    text = "".join(chunks).strip()
    if server_error and not text:
        result.status = "rejected"
        result.error = server_error[:180]
        result.total_s = round(total_s, 2)
        return result

    if not text:
        result.status = "empty"
        result.error = server_error or "no message_chunk content"
        result.total_s = round(total_s, 2)
        return result

    quality, hits, zh_left, notes = score_translation(text)
    result.status = "ok"
    result.first_token_s = round(first_token_s or total_s, 2)
    result.total_s = round(total_s, 2)
    result.chars = len(text)
    result.quality = quality
    result.anchors_hit = hits
    result.leftover_zh = zh_left
    result.translation = _strip_thinking_noise(text)
    result.notes = notes
    if server_error:
        result.notes.append(f"stream error note: {server_error[:80]}")
    return result


def run_one(model_name: str, access: str, timeout: float) -> ModelResult:
    """Hard wall-clock timeout around each model (SSE can hang past read timeout)."""
    hard = max(5.0, timeout + 5.0)
    t0 = time.perf_counter()
    q: queue.Queue[ModelResult | BaseException] = queue.Queue(maxsize=1)

    def _target() -> None:
        try:
            # Fresh client per model/thread — avoid sharing curl_cffi Session.
            client = TabbitClient.from_config()
            q.put(_run_one_worker(client, model_name, access, timeout))
        except BaseException as exc:  # noqa: BLE001
            q.put(exc)

    th = threading.Thread(target=_target, name=f"bench-{model_name}", daemon=True)
    th.start()
    th.join(timeout=hard)
    if th.is_alive():
        return ModelResult(
            name=model_name,
            access=access,
            status="timeout",
            total_s=round(time.perf_counter() - t0, 2),
            error=f"hard timeout after {hard:.0f}s (abandoned hung stream)",
        )
    try:
        item = q.get_nowait()
    except queue.Empty:
        return ModelResult(
            name=model_name,
            access=access,
            status="error",
            total_s=round(time.perf_counter() - t0, 2),
            error="worker finished without result",
        )
    if isinstance(item, BaseException):
        return ModelResult(
            name=model_name,
            access=access,
            status="error",
            total_s=round(time.perf_counter() - t0, 2),
            error=f"{type(item).__name__}: {item}"[:180],
        )
    return item


def run_all_parallel(
    rows: list[tuple[str, str]],
    timeout: float,
    workers: int,
) -> list[ModelResult]:
    """Fire all model requests concurrently and collect results as they finish."""
    n = len(rows)
    workers = max(1, min(workers, n))
    print(f"[i] Parallel workers: {workers}", flush=True)

    results: list[ModelResult] = []
    done_count = 0
    lock = threading.Lock()
    t_all = time.perf_counter()
    access_by_name = {name: access for name, access in rows}

    def _job(name: str, access: str) -> ModelResult:
        nonlocal done_count
        r = run_one(name, access, timeout=timeout)
        with lock:
            done_count += 1
            i = done_count
            if r.status == "ok":
                print(
                    f"[{i}/{n}] {name}: ok  TTFT={r.first_token_s:.2f}s  "
                    f"total={r.total_s:.2f}s  Q={r.quality}  "
                    f":: {r.translation[:80]}",
                    flush=True,
                )
            else:
                print(
                    f"[{i}/{n}] {name}: {r.status}  {r.error[:100]}",
                    flush=True,
                )
        return r

    with ThreadPoolExecutor(max_workers=workers, thread_name_prefix="model") as pool:
        futures: dict[Future[ModelResult], str] = {
            pool.submit(_job, name, access): name for name, access in rows
        }
        overall = timeout + 30.0
        pending = set(futures)
        while pending:
            finished, pending = wait(
                pending, timeout=overall, return_when=FIRST_COMPLETED
            )
            if not finished:
                for fut in list(pending):
                    name = futures[fut]
                    results.append(ModelResult(
                        name=name,
                        access=access_by_name[name],
                        status="timeout",
                        total_s=round(time.perf_counter() - t_all, 2),
                        error="overall bench wait expired",
                    ))
                    fut.cancel()
                break
            for fut in finished:
                name = futures[fut]
                try:
                    results.append(fut.result())
                except Exception as e:  # noqa: BLE001
                    results.append(ModelResult(
                        name=name,
                        access=access_by_name[name],
                        status="error",
                        error=f"{type(e).__name__}: {e}"[:180],
                    ))

    print(
        f"[i] Parallel bench finished in {time.perf_counter() - t_all:.1f}s",
        flush=True,
    )
    return results


def _pad(s: str, n: int) -> str:
    s = s if len(s) <= n else s[: n - 1] + "…"
    return s.ljust(n)


def print_table(results: list[ModelResult]) -> None:
    headers = (
        f"{_pad('MODEL', 22)} {_pad('ACCESS', 14)} {_pad('STAT', 8)} "
        f"{'TTFT':>6} {'TOTAL':>6} {'Q':>5} {'SPD':>5} {'COM':>5}  PREVIEW"
    )
    print(headers)
    print("-" * len(headers) + "-" * 40)
    for r in results:
        ttft = f"{r.first_token_s:.2f}" if r.first_token_s is not None else "-"
        total = f"{r.total_s:.2f}" if r.total_s is not None else "-"
        if r.status == "ok":
            preview = r.translation.replace("\n", " ")
        else:
            preview = r.error.replace("\n", " ")
        print(
            f"{_pad(r.name, 22)} {_pad(r.access, 14)} {_pad(r.status, 8)} "
            f"{ttft:>6} {total:>6} {r.quality:>5.1f} {r.speed_score:>5.1f} "
            f"{r.combined:>5.1f}  {preview[:70]}"
        )


def recommend(results: list[ModelResult]) -> None:
    ok = [r for r in results if r.status == "ok"]
    print("\n=== Review ===")
    print(f"Source ZH: {SOURCE_ZH}")
    print(f"Reference: {REFERENCE_EN}")
    print(
        f"Models tested: {len(results)} | succeeded: {len(ok)} | "
        f"failed/rejected: {len(results) - len(ok)}"
    )

    if not ok:
        print("\nNo successful translations. Re-check cookies / premium signature.")
        return

    best_quality = max(ok, key=lambda r: (r.quality, -(r.total_s or 999)))
    best_speed = min(ok, key=lambda r: (r.first_token_s or 999, r.total_s or 999))
    good = [r for r in ok if r.quality >= 70] or [
        r for r in ok if r.quality >= 55
    ] or ok
    balanced = max(good, key=lambda r: r.combined)
    free_ok = [r for r in good if "premium" not in (r.access or "")]
    pick = balanced
    if free_ok:
        free_best = max(free_ok, key=lambda r: r.combined)
        if free_best.combined >= balanced.combined - 8:
            pick = free_best

    print("\nTop by quality:")
    for r in sorted(ok, key=lambda x: (-x.quality, x.total_s or 999))[:5]:
        print(
            f"  - {r.name:22} Q={r.quality:5.1f}  "
            f"TTFT={r.first_token_s:.2f}s  total={r.total_s:.2f}s  "
            f"anchors={r.anchors_hit}/{r.anchors_total}"
        )

    print("\nTop by speed (first token):")
    for r in sorted(ok, key=lambda x: (x.first_token_s or 999, x.total_s or 999))[:5]:
        print(
            f"  - {r.name:22} TTFT={r.first_token_s:.2f}s  "
            f"total={r.total_s:.2f}s  Q={r.quality:5.1f}"
        )

    print("\nTop balanced (0.65*quality + 0.35*speed):")
    for r in sorted(ok, key=lambda x: -x.combined)[:5]:
        print(
            f"  - {r.name:22} COM={r.combined:5.1f}  "
            f"Q={r.quality:5.1f}  SPD={r.speed_score:5.1f}  "
            f"access={r.access}"
        )

    print("\n--- Recommendation ---")
    print(f"Best overall pick: {pick.name}")
    print(f"  access     : {pick.access}")
    print(
        f"  quality    : {pick.quality}/100  "
        f"(anchors {pick.anchors_hit}/{pick.anchors_total})"
    )
    print(f"  first token: {pick.first_token_s:.2f}s")
    print(f"  total time : {pick.total_s:.2f}s")
    print(f"  combined   : {pick.combined}")
    if pick.notes:
        print(f"  notes      : {', '.join(pick.notes)}")
    print(f"  output     : {pick.translation}")
    print()
    print(
        f"Fastest OK   : {best_speed.name} "
        f"(TTFT {best_speed.first_token_s:.2f}s, Q={best_speed.quality})"
    )
    print(
        f"Highest Q    : {best_quality.name} "
        f"(Q={best_quality.quality}, TTFT {best_quality.first_token_s:.2f}s)"
    )
    print()
    print("Use it with:")
    print(
        f'  python tabbit_client.py chat -m "{pick.name}" '
        f'"Translate to English: {SOURCE_ZH[:24]}..."'
    )


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--free-only", action="store_true",
                    help="Skip premium_only models")
    ap.add_argument("--timeout", type=float, default=60.0,
                    help="Per-model hard timeout seconds (default 60)")
    ap.add_argument("--limit", type=int, default=0,
                    help="Only test first N models (0 = all)")
    ap.add_argument("--workers", type=int, default=0,
                    help="Parallel workers (default: all models at once)")
    ap.add_argument("--json-out", default="",
                    help="Optional path to write full JSON results")
    ap.add_argument("--model", action="append", default=[],
                    help="Only test this display_name (repeatable)")
    args = ap.parse_args()

    _orig_print = builtins.print

    def _quiet_config_print(*a: Any, **k: Any) -> None:
        if a and isinstance(a[0], str) and a[0].startswith("[+] Loaded"):
            return
        if a and isinstance(a[0], str) and a[0].startswith("    (Tip:"):
            return
        _orig_print(*a, **k)

    client = TabbitClient.from_config()
    print("[i] Fetching model list ...")
    data = client.get_models(scene="chat", with_moa=False)
    models = data.get("models") or []
    if not models:
        print("[!] No models returned")
        return 1

    rows: list[tuple[str, str]] = []
    for m in models:
        name = m.get("display_name") or m.get("name") or ""
        access = m.get("model_access_type") or "?"
        if not name:
            continue
        if args.free_only and access == "premium_only":
            continue
        if args.model and name not in args.model:
            continue
        rows.append((name, access))

    if args.limit and args.limit > 0:
        rows = rows[: args.limit]

    workers = args.workers if args.workers > 0 else len(rows)
    print(f"[i] Testing {len(rows)} models on Chinese translation (parallel)")
    print(f"[i] Prompt source: {SOURCE_ZH}")
    print()

    builtins.print = _quiet_config_print  # type: ignore[assignment]
    try:
        results = run_all_parallel(rows, timeout=args.timeout, workers=workers)
    finally:
        builtins.print = _orig_print  # type: ignore[assignment]

    ranked = sorted(
        results,
        key=lambda r: (
            0 if r.status == "ok" else 1,
            -r.combined,
            r.total_s if r.total_s is not None else 1e9,
            r.name,
        ),
    )

    print("\n=== Results (ranked) ===")
    print_table(ranked)
    recommend(ranked)

    out = args.json_out or str(ROOT / "test" / "chinese_translate_bench.json")
    payload = {
        "source_zh": SOURCE_ZH,
        "reference_en": REFERENCE_EN,
        "prompt": PROMPT,
        "workers": workers,
        "timeout": args.timeout,
        "results": [asdict(r) for r in ranked],
    }
    Path(out).write_text(
        json.dumps(payload, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(f"\n[+] Full results JSON -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
