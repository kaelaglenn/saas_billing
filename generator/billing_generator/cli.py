"""Generate raw billing data and its answer key: simulate -> validate -> truth -> messiness -> write."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import pandas as pd
import yaml

from . import messiness
from .frames import build_raw
from .simulate import Simulator
from .truth import build_truth
from .validate import integrity_checks, target_checks

DEFAULT_CONFIG = Path(__file__).resolve().parents[1] / "config.yaml"


def load_config(path: Path = DEFAULT_CONFIG, **overrides) -> dict:
    cfg = yaml.safe_load(Path(path).read_text())
    cfg.update({k: v for k, v in overrides.items() if v is not None})
    return cfg


def generate(cfg: dict) -> dict:
    """Run the full pipeline in memory. Returns raw (messy), clean raw, truth, and check results."""
    sim = Simulator(cfg).run()
    clean = build_raw(sim)
    truth = build_truth(sim)
    checks = integrity_checks(sim, clean) + target_checks(sim, truth["monthly_summary"])
    raw, anomalies = messiness.inject(clean, cfg)
    truth["seeded_anomalies"] = pd.DataFrame(anomalies + sim.notes)
    return {"sim": sim, "clean": clean, "raw": raw, "truth": truth, "checks": checks}


def write(tables: dict[str, pd.DataFrame], directory: Path, csv: bool = True):
    directory.mkdir(parents=True, exist_ok=True)
    for name, frame in tables.items():
        frame.to_parquet(directory / f"{name}.parquet", index=False)
        if csv:
            frame.to_csv(directory / f"{name}.csv", index=False)


def print_report(result: dict):
    summary = result["truth"]["monthly_summary"].copy()
    summary["total_mrr"] = (summary["total_mrr_cents"] / 100).map("${:,.0f}".format)
    cols = ["month", "trial_starts", "conversions", "reactivations", "churn_cancelled", "churn_lapsed",
            "ending_active_subscriptions", "logo_churn_rate", "total_mrr"]
    print(summary[cols].to_string(index=False))
    print()
    for name, frame in result["raw"].items():
        print(f"  raw/{name:<22} {len(frame):>9,} rows")
    print()
    for c in result["checks"]:
        status = "PASS" if c.passed else ("FAIL" if c.hard else "WARN")
        print(f"  [{status}] {c.name}: {c.detail}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--seed", type=int)
    parser.add_argument("--scale", type=float)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--no-csv", action="store_true", help="write Parquet only")
    args = parser.parse_args(argv)

    cfg = load_config(args.config, seed=args.seed, scale=args.scale)
    result = generate(cfg)
    print_report(result)
    if any(c.hard and not c.passed for c in result["checks"]):
        print("\nIntegrity checks failed; nothing written.", file=sys.stderr)
        return 1
    out = args.output_dir or Path(cfg["output_dir"])
    write(result["raw"], out / "raw", csv=not args.no_csv)
    write(result["truth"], out / "truth", csv=not args.no_csv)
    print(f"\nWrote {out / 'raw'} and {out / 'truth'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
