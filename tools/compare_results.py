#!/usr/bin/env python3
"""
tools/compare_results.py
Compare two benchmark result JSON files and emit results/delta.json

Usage:
    python3 tools/compare_results.py results/baseline.json results/bolt.json
    python3 tools/compare_results.py results/baseline.json results/bolt.json --print
"""
import json
import sys
import os
from datetime import datetime, timezone


def load(path: str) -> dict:
    with open(path) as fh:
        return json.load(fh)


def percent_delta(baseline: float, optimised: float) -> float | None:
    if baseline == 0 or baseline is None or optimised is None:
        return None
    return round((optimised - baseline) / baseline * 100.0, 2)


def main() -> None:
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    flags = [a for a in sys.argv[1:] if a.startswith('--')]
    print_flag = '--print' in flags

    if len(args) < 2:
        print(f'Usage: {sys.argv[0]} <baseline.json> <bolt.json> [--print]',
              file=sys.stderr)
        sys.exit(1)

    baseline_path = args[0]
    bolt_path = args[1]

    for p in (baseline_path, bolt_path):
        if not os.path.exists(p):
            print(f'ERROR: file not found: {p}', file=sys.stderr)
            sys.exit(1)

    baseline = load(baseline_path)
    bolt = load(bolt_path)

    # Compute metric deltas
    all_events = set(baseline.get('metrics', {}).keys()) | \
                 set(bolt.get('metrics', {}).keys())

    metric_deltas = {}
    for event in sorted(all_events):
        b_val = baseline.get('metrics', {}).get(event)
        o_val = bolt.get('metrics', {}).get(event)
        metric_deltas[event] = {
            'baseline': b_val,
            'bolt':     o_val,
            'delta_pct': percent_delta(b_val, o_val),
        }

    # Wall-clock delta
    b_time = baseline.get('wall_time_s')
    o_time = bolt.get('wall_time_s')

    delta = {
        'generated':        datetime.now(timezone.utc).isoformat(),
        'baseline_label':   baseline.get('label', 'baseline'),
        'bolt_label':       bolt.get('label', 'bolt'),
        'baseline_binary':  baseline.get('binary', ''),
        'bolt_binary':      bolt.get('binary', ''),
        'wall_time_baseline_s': b_time,
        'wall_time_bolt_s':     o_time,
        'wall_time_delta_pct':  percent_delta(b_time, o_time),
        'metrics':              metric_deltas,
    }

    # Write delta.json
    results_dir = os.path.dirname(baseline_path)
    output_path = os.path.join(results_dir, 'delta.json')
    with open(output_path, 'w') as fh:
        json.dump(delta, fh, indent=2)
        fh.write('\n')

    print(f'[compare] Written: {output_path}')

    # Human-readable summary
    if print_flag:
        print()
        print('=== Delta Table (BOLT vs baseline) ===')
        wt_pct = delta['wall_time_delta_pct']
        wt_str = f'{wt_pct:+.1f}%' if wt_pct is not None else 'n/a'
        print(f'  {"Wall-clock time":<30} {wt_str}')
        for event, vals in metric_deltas.items():
            pct = vals['delta_pct']
            pct_str = f'{pct:+.1f}%' if pct is not None else 'n/a'
            print(f'  {event:<30} {pct_str}')

        print()
        if wt_pct is not None and wt_pct < -1.0:
            print(f'  VERDICT: FASTER by {-wt_pct:.1f}% wall-clock time')
        elif wt_pct is not None and wt_pct > 1.0:
            print(f'  VERDICT: SLOWER by {wt_pct:.1f}% — check profile quality')
        else:
            print('  VERDICT: NO SIGNIFICANT CHANGE (within ±1%)')


if __name__ == '__main__':
    main()
