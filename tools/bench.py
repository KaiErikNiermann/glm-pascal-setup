#!/usr/bin/env python3
"""Measure prefill and decode throughput against a running llama-server.

METHODOLOGY WARNING -- read this before trusting any number you produce.

llama.cpp reuses the KV cache for the *leading common prefix* of consecutive
prompts. If your filler text is deterministic, each larger prompt is a byte-exact
prefix of the previous one, the server re-prefills almost nothing, and your
"prefill throughput" is measured on a handful of tokens. An earlier sweep on this
exact box reported 53 tok/s at 16k and a 5.6x degradation curve. It was wrong for
precisely this reason.

So: this script generates a distinct random prefix per prompt, and reports the
server's own `timings.cache_n`. If cache_n is not ~0 on a prefill measurement,
the number is invalid and the script says so.

Stdlib-only so it runs anywhere without a venv.
"""

from __future__ import annotations

import argparse
import json
import random
import statistics
import string
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any, Final

TIMEOUT: Final[int] = 900


@dataclass(frozen=True, slots=True)
class Sample:
    prompt_tokens: int
    cached_tokens: int
    prefill_tps: float
    decode_tps: float
    decoded: int

    @property
    def valid_prefill(self) -> bool:
        """A prefill number only means something if nothing was reused."""
        return self.cached_tokens <= max(8, self.prompt_tokens * 0.02)


def _filler(approx_tokens: int, rng: random.Random) -> str:
    """Distinct pseudo-text. ~0.75 words/token is close enough for sizing."""
    words = [
        "".join(rng.choices(string.ascii_lowercase, k=rng.randint(3, 9)))
        for _ in range(int(approx_tokens * 0.75))
    ]
    return " ".join(words)


def probe(base: str, model: str, prompt: str, max_tokens: int) -> Sample:
    body = json.dumps(
        {
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens,
            "temperature": 0,
            "cache_prompt": True,
        }
    ).encode()
    req = urllib.request.Request(
        f"{base}/v1/chat/completions",
        data=body,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        d: dict[str, Any] = json.loads(r.read())
    t = d.get("timings", {})
    return Sample(
        prompt_tokens=int(t.get("prompt_n", 0)),
        cached_tokens=int(t.get("cache_n", 0)),
        prefill_tps=float(t.get("prompt_per_second", 0.0)),
        decode_tps=float(t.get("predicted_per_second", 0.0)),
        decoded=int(t.get("predicted_n", 0)),
    )


def main() -> None:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument("--base", default="http://127.0.0.1:8080")
    p.add_argument("--model", default="glm-4.7-flash")
    p.add_argument("--sizes", default="512,2048,8192,16384", help="approx prompt sizes in tokens")
    p.add_argument("--max-tokens", type=int, default=64)
    p.add_argument("--seed", type=int, default=None, help="omit for fresh randomness (recommended)")
    p.add_argument("--repeat", type=int, default=1)
    args = p.parse_args()

    rng = random.Random(args.seed)
    sizes = [int(s) for s in args.sizes.split(",")]

    print(f"target  {args.base}  model={args.model}")
    print(f"{'prompt':>8} {'cached':>7} {'prefill':>11} {'decode':>10}  note")
    print("-" * 56)

    suspect = 0
    for size in sizes:
        pre: list[float] = []
        dec: list[float] = []
        last: Sample | None = None
        for _ in range(args.repeat):
            # A distinct random head per call is what stops the server reusing KV.
            prompt = f"{_filler(size, rng)}\n\nReply with the single word: ok"
            try:
                s = probe(args.base, args.model, prompt, args.max_tokens)
            except (urllib.error.URLError, TimeoutError) as e:
                print(f"{size:>8}  request failed: {e}")
                break
            pre.append(s.prefill_tps)
            dec.append(s.decode_tps)
            last = s
        if last is None:
            continue
        note = "" if last.valid_prefill else "<-- INVALID: KV was reused"
        if not last.valid_prefill:
            suspect += 1
        print(
            f"{last.prompt_tokens:>8} {last.cached_tokens:>7} "
            f"{statistics.mean(pre):>8.1f}t/s {statistics.mean(dec):>7.1f}t/s  {note}"
        )

    print()
    if suspect:
        print(f"{suspect} row(s) had cache reuse and are NOT valid prefill measurements.")
        print("Restart the server or vary the prompt head, then re-run.")
        sys.exit(1)
    print("All prefill measurements had a cold cache (cache_n ~ 0).")


if __name__ == "__main__":
    main()
