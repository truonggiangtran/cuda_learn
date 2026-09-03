#!/usr/bin/env python3
"""Capture CUDA benchmark data and store comparable metrics in SQLite."""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import math
import os
import pathlib
import re
import shlex
import sqlite3
import subprocess
import sys
from typing import Iterable, Sequence


SCHEMA = """
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS benchmark_runs (
    id INTEGER PRIMARY KEY,
    recorded_at TEXT NOT NULL,
    label TEXT NOT NULL,
    status TEXT NOT NULL,
    git_commit TEXT,
    git_dirty INTEGER,
    command TEXT NOT NULL,
    report_path TEXT,
    benchmark_scope TEXT,
    gpu_name TEXT,
    compute_capability TEXT,
    driver_version TEXT,
    runtime_version TEXT,
    notes TEXT,
    metadata_json TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS measurements (
    id INTEGER PRIMARY KEY,
    run_id INTEGER NOT NULL REFERENCES benchmark_runs(id) ON DELETE CASCADE,
    source TEXT NOT NULL,
    scope TEXT NOT NULL,
    subject TEXT NOT NULL,
    metric TEXT NOT NULL,
    value REAL NOT NULL,
    unit TEXT NOT NULL,
    aggregation TEXT NOT NULL,
    sample_count INTEGER,
    metadata_json TEXT NOT NULL DEFAULT '{}',
    UNIQUE(run_id, source, scope, subject, metric, aggregation)
);

CREATE INDEX IF NOT EXISTS measurements_lookup
ON measurements(scope, subject, metric, aggregation, run_id);
"""

TIME_TO_NS = {
    "ns": 1.0,
    "us": 1_000.0,
    "µs": 1_000.0,
    "ms": 1_000_000.0,
    "s": 1_000_000_000.0,
}

SIZE_TO_BYTES = {
    "b": 1.0,
    "byte": 1.0,
    "bytes": 1.0,
    "kb": 1_000.0,
    "mb": 1_000_000.0,
    "gb": 1_000_000_000.0,
    "kib": 1_024.0,
    "mib": 1_048_576.0,
    "gib": 1_073_741_824.0,
}


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def capture_identity(
    database: pathlib.Path,
    label: str | None,
    report: str | None,
    *,
    now: dt.datetime | None = None,
) -> tuple[str, pathlib.Path]:
    timestamp = now or dt.datetime.now(dt.timezone.utc)
    generated_label = timestamp.strftime("capture-%Y%m%dT%H%M%SZ")
    resolved_label = label or generated_label
    resolved_report = (
        pathlib.Path(report)
        if report
        else database.parent / f"{generated_label}.nsys-rep"
    )
    return resolved_label, resolved_report


def connect_database(path: pathlib.Path) -> sqlite3.Connection:
    path.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(path)
    connection.execute("PRAGMA foreign_keys = ON")
    connection.executescript(SCHEMA)
    return connection


def canonical_header(header: str) -> str:
    header = re.sub(r"\s*\([^)]*\)\s*$", "", header.strip())
    return re.sub(r"[^a-z0-9]+", "", header.lower())


def header_unit(header: str) -> str | None:
    match = re.search(r"\(([^)]+)\)\s*$", header.strip())
    return match.group(1).strip() if match else None


def normalized_row(row: dict[str, str]) -> dict[str, tuple[str, str]]:
    return {
        canonical_header(header): (header, value)
        for header, value in row.items()
        if header is not None and value is not None
    }


def parse_number(value: str | None) -> float | None:
    if value is None:
        return None
    cleaned = value.strip().replace(",", "").replace("%", "")
    if not cleaned or cleaned.lower() in {"n/a", "nan", "inf", "-inf"}:
        return None
    try:
        parsed = float(cleaned)
    except ValueError:
        return None
    return parsed if math.isfinite(parsed) else None


def convert_time_to_ns(value: float, unit: str | None) -> float:
    normalized = (unit or "ns").lower()
    if normalized not in TIME_TO_NS:
        raise ValueError(f"Unsupported time unit: {unit}")
    return value * TIME_TO_NS[normalized]


def convert_size_to_bytes(value: float, unit: str | None) -> float:
    normalized = (unit or "KiB").lower()
    if normalized not in SIZE_TO_BYTES:
        raise ValueError(f"Unsupported size unit: {unit}")
    return value * SIZE_TO_BYTES[normalized]


def extract_csv_rows(output: str, required_headers: set[str]) -> list[dict[str, str]]:
    lines = output.splitlines()
    for index, line in enumerate(lines):
        try:
            cells = next(csv.reader([line]))
        except csv.Error:
            continue
        headers = {canonical_header(cell) for cell in cells}
        if required_headers.issubset(headers):
            reader = csv.DictReader(lines[index:])
            return [
                row
                for row in reader
                if row and any((value or "").strip() for value in row.values())
            ]
    raise ValueError(
        "Could not find CSV header containing: " + ", ".join(sorted(required_headers))
    )


def run_process(command: Sequence[str], *, echo: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(command, text=True, capture_output=True, check=False)
    if echo and result.stdout:
        print(result.stdout, end="")
    if echo and result.stderr:
        print(result.stderr, end="", file=sys.stderr)
    if result.returncode != 0:
        rendered = " ".join(shlex.quote(item) for item in command)
        raise RuntimeError(f"Command failed ({result.returncode}): {rendered}")
    return result


def git_metadata() -> tuple[str | None, int | None]:
    try:
        commit = run_process(["git", "rev-parse", "HEAD"], echo=False).stdout.strip()
        status = run_process(["git", "status", "--porcelain"], echo=False).stdout
        return commit, int(bool(status.strip()))
    except (FileNotFoundError, RuntimeError):
        return None, None


def create_run(
    connection: sqlite3.Connection,
    *,
    label: str,
    status: str,
    command: Sequence[str],
    report_path: str | None,
    notes: str | None,
    commit_override: str | None,
    payload: dict | None,
) -> int:
    commit, dirty = git_metadata()
    commit = commit_override or commit
    payload = payload or {}
    cursor = connection.execute(
        """
        INSERT INTO benchmark_runs(
            recorded_at, label, status, git_commit, git_dirty, command,
            report_path, benchmark_scope, gpu_name, compute_capability,
            driver_version, runtime_version, notes, metadata_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            utc_now(),
            label,
            status,
            commit,
            dirty,
            json.dumps(list(command)),
            report_path,
            payload.get("scope"),
            payload.get("gpu_name"),
            payload.get("compute_capability"),
            str(payload.get("driver_version")) if payload.get("driver_version") is not None else None,
            str(payload.get("runtime_version")) if payload.get("runtime_version") is not None else None,
            notes,
            json.dumps(payload, sort_keys=True),
        ),
    )
    return int(cursor.lastrowid)


def add_measurement(
    connection: sqlite3.Connection,
    *,
    run_id: int,
    source: str,
    scope: str,
    subject: str,
    metric: str,
    value: float | int | None,
    unit: str,
    aggregation: str,
    sample_count: int | None = None,
    metadata: dict | None = None,
) -> None:
    if value is None:
        return
    connection.execute(
        """
        INSERT INTO measurements(
            run_id, source, scope, subject, metric, value, unit,
            aggregation, sample_count, metadata_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(run_id, source, scope, subject, metric, aggregation)
        DO UPDATE SET
            value = excluded.value,
            unit = excluded.unit,
            sample_count = excluded.sample_count,
            metadata_json = excluded.metadata_json
        """,
        (
            run_id,
            source,
            scope,
            subject,
            metric,
            float(value),
            unit,
            aggregation,
            sample_count,
            json.dumps(metadata or {}, sort_keys=True),
        ),
    )


def parse_benchmark_payload(output: str) -> dict:
    prefix = "BENCHMARK_JSON="
    for line in reversed(output.splitlines()):
        if line.startswith(prefix):
            payload = json.loads(line[len(prefix) :])
            if payload.get("schema_version") != 1:
                raise ValueError("Unsupported benchmark JSON schema")
            return payload
    raise ValueError("Benchmark command did not emit BENCHMARK_JSON")


def import_application_payload(
    connection: sqlite3.Connection, run_id: int, payload: dict
) -> None:
    subject = payload["scope"]
    iterations = int(payload["measured_iterations"])
    for key, aggregation in (
        ("mean_ms", "mean"),
        ("median_ms", "median"),
        ("p95_ms", "p95"),
        ("min_ms", "min"),
        ("max_ms", "max"),
        ("stddev_ms", "stddev"),
    ):
        add_measurement(
            connection,
            run_id=run_id,
            source="benchmark",
            scope="application",
            subject=subject,
            metric="duration",
            value=payload[key],
            unit="ms",
            aggregation=aggregation,
            sample_count=iterations,
        )

    for metric, key, unit in (
        ("throughput", "throughput_fps", "frame/s"),
        ("input_bytes", "input_bytes", "B"),
        ("output_bytes", "output_bytes", "B"),
        ("deterministic", "deterministic", "bool"),
        ("warmup_iterations", "warmup_iterations", "count"),
        ("measured_iterations", "measured_iterations", "count"),
    ):
        add_measurement(
            connection,
            run_id=run_id,
            source="benchmark",
            scope="application",
            subject=subject,
            metric=metric,
            value=int(payload[key]) if isinstance(payload[key], bool) else payload[key],
            unit=unit,
            aggregation="value",
            sample_count=iterations,
        )

    for metric, key, unit in (
        ("sm_count", "sm_count", "count"),
        ("global_memory", "global_memory_bytes", "B"),
    ):
        add_measurement(
            connection,
            run_id=run_id,
            source="benchmark",
            scope="device",
            subject=payload["gpu_name"],
            metric=metric,
            value=payload[key],
            unit=unit,
            aggregation="value",
        )


def row_value(row: dict[str, tuple[str, str]], key: str) -> tuple[float | None, str | None]:
    item = row.get(key)
    if item is None:
        return None, None
    header, value = item
    return parse_number(value), header_unit(header)


def row_text(row: dict[str, tuple[str, str]], *keys: str) -> str:
    for key in keys:
        if key in row:
            return row[key][1].strip()
    raise ValueError(f"Missing text column: {keys}")


def row_metadata(row: dict[str, tuple[str, str]], excluded: set[str]) -> dict[str, str]:
    return {
        original: value
        for key, (original, value) in row.items()
        if key not in excluded and value.strip()
    }


def import_timing_summary(
    connection: sqlite3.Connection,
    run_id: int,
    output: str,
    *,
    scope: str,
    name_keys: tuple[str, ...],
    count_keys: tuple[str, ...],
) -> None:
    rows = extract_csv_rows(output, {"totaltime", canonical_header(name_keys[0])})
    for raw_row in rows:
        row = normalized_row(raw_row)
        try:
            subject = row_text(row, *name_keys)
        except ValueError:
            continue
        count = None
        for count_key in count_keys:
            count_value, _ = row_value(row, count_key)
            if count_value is not None:
                count = int(count_value)
                break

        metadata = row_metadata(
            row,
            {
                "time",
                "totaltime",
                "avg",
                "med",
                "min",
                "max",
                "stddev",
                *name_keys,
                *count_keys,
            },
        )
        grid = row.get("gridxyz")
        block = row.get("blockxyz")
        if grid or block:
            subject = (
                f"{subject} [grid={grid[1] if grid else '?'}, "
                f"block={block[1] if block else '?'}]"
            )

        share, _ = row_value(row, "time")
        add_measurement(
            connection,
            run_id=run_id,
            source="nsys",
            scope=scope,
            subject=subject,
            metric="time_share",
            value=share,
            unit="%",
            aggregation="total",
            sample_count=count,
            metadata=metadata,
        )
        for key, aggregation in (
            ("totaltime", "total"),
            ("avg", "mean"),
            ("med", "median"),
            ("min", "min"),
            ("max", "max"),
            ("stddev", "stddev"),
        ):
            value, unit = row_value(row, key)
            add_measurement(
                connection,
                run_id=run_id,
                source="nsys",
                scope=scope,
                subject=subject,
                metric="duration",
                value=convert_time_to_ns(value, unit) if value is not None else None,
                unit="ns",
                aggregation=aggregation,
                sample_count=count,
                metadata=metadata,
            )
        add_measurement(
            connection,
            run_id=run_id,
            source="nsys",
            scope=scope,
            subject=subject,
            metric="invocations",
            value=count,
            unit="count",
            aggregation="total",
            sample_count=count,
            metadata=metadata,
        )


def import_memory_sizes(
    connection: sqlite3.Connection, run_id: int, output: str
) -> None:
    rows = extract_csv_rows(output, {"total", "operation"})
    for raw_row in rows:
        row = normalized_row(raw_row)
        try:
            subject = row_text(row, "operation", "name")
        except ValueError:
            continue
        count_value, _ = row_value(row, "count")
        if count_value is None:
            count_value, _ = row_value(row, "operations")
        count = int(count_value) if count_value is not None else None
        for key, aggregation in (
            ("total", "total"),
            ("avg", "mean"),
            ("med", "median"),
            ("min", "min"),
            ("max", "max"),
            ("stddev", "stddev"),
        ):
            value, unit = row_value(row, key)
            add_measurement(
                connection,
                run_id=run_id,
                source="nsys",
                scope="memory_operation",
                subject=subject,
                metric="bytes",
                value=convert_size_to_bytes(value, unit) if value is not None else None,
                unit="B",
                aggregation=aggregation,
                sample_count=count,
            )


def import_kernel_execution(
    connection: sqlite3.Connection, run_id: int, output: str
) -> None:
    rows = extract_csv_rows(output, {"tavg", "kernelname"})
    phase_metrics = {
        "t": "launch_to_completion_duration",
        "a": "api_duration",
        "q": "queue_duration",
        "k": "kernel_duration",
    }
    statistic_suffixes = {
        "avg": "mean",
        "med": "median",
        "min": "min",
        "max": "max",
        "stddev": "stddev",
    }
    for raw_row in rows:
        row = normalized_row(raw_row)
        try:
            subject = row_text(row, "kernelname")
        except ValueError:
            continue
        count_value, _ = row_value(row, "count")
        count = int(count_value) if count_value is not None else None
        metadata = row_metadata(
            row,
            {
                "count",
                "qcount",
                "kernelname",
                *{
                    f"{prefix}{suffix}"
                    for prefix in phase_metrics
                    for suffix in statistic_suffixes
                },
            },
        )
        for prefix, metric in phase_metrics.items():
            for suffix, aggregation in statistic_suffixes.items():
                value, unit = row_value(row, f"{prefix}{suffix}")
                add_measurement(
                    connection,
                    run_id=run_id,
                    source="nsys",
                    scope="kernel_launch",
                    subject=subject,
                    metric=metric,
                    value=convert_time_to_ns(value, unit) if value is not None else None,
                    unit="ns",
                    aggregation=aggregation,
                    sample_count=count,
                    metadata=metadata,
                )
        for key, metric in (("count", "invocations"), ("qcount", "queued_invocations")):
            value, _ = row_value(row, key)
            add_measurement(
                connection,
                run_id=run_id,
                source="nsys",
                scope="kernel_launch",
                subject=subject,
                metric=metric,
                value=value,
                unit="count",
                aggregation="total",
                sample_count=count,
                metadata=metadata,
            )


def run_nsys_stats(nsys: str, report: pathlib.Path, report_name: str) -> str:
    result = run_process(
        [nsys, "stats", "--report", report_name, "--format", "csv", str(report)],
        echo=False,
    )
    return result.stdout


def scalar_sum(
    connection: sqlite3.Connection,
    run_id: int,
    *,
    scope: str,
    metric: str,
    aggregation: str,
) -> float:
    value = connection.execute(
        """
        SELECT COALESCE(SUM(value), 0)
        FROM measurements
        WHERE run_id = ? AND source = 'nsys' AND scope = ?
          AND metric = ? AND aggregation = ?
        """,
        (run_id, scope, metric, aggregation),
    ).fetchone()[0]
    return float(value)


def add_derived_metrics(connection: sqlite3.Connection, run_id: int) -> None:
    kernel_ns = scalar_sum(
        connection, run_id, scope="kernel", metric="duration", aggregation="total"
    )
    memory_ns = scalar_sum(
        connection,
        run_id,
        scope="memory_operation",
        metric="duration",
        aggregation="total",
    )
    api_ns = scalar_sum(
        connection, run_id, scope="cuda_api", metric="duration", aggregation="total"
    )
    gpu_activity_ns = kernel_ns + memory_ns

    for metric, value, unit in (
        ("kernel_time", kernel_ns, "ns"),
        ("memory_operation_time", memory_ns, "ns"),
        ("api_time", api_ns, "ns"),
        ("gpu_activity_sum", gpu_activity_ns, "ns"),
        (
            "kernel_share_of_gpu_activity",
            100.0 * kernel_ns / gpu_activity_ns if gpu_activity_ns else None,
            "%",
        ),
        (
            "memory_share_of_gpu_activity",
            100.0 * memory_ns / gpu_activity_ns if gpu_activity_ns else None,
            "%",
        ),
    ):
        add_measurement(
            connection,
            run_id=run_id,
            source="derived",
            scope="gpu",
            subject="all",
            metric=metric,
            value=value,
            unit=unit,
            aggregation="total",
        )

    memory_rows = connection.execute(
        """
        SELECT sizes.subject, sizes.value, times.value
        FROM measurements AS sizes
        JOIN measurements AS times
          ON times.run_id = sizes.run_id
         AND times.scope = sizes.scope
         AND times.subject = sizes.subject
         AND times.aggregation = sizes.aggregation
        WHERE sizes.run_id = ?
          AND sizes.source = 'nsys'
          AND sizes.scope = 'memory_operation'
          AND sizes.metric = 'bytes'
          AND sizes.aggregation = 'total'
          AND times.metric = 'duration'
        """,
        (run_id,),
    ).fetchall()
    total_bytes = 0.0
    total_time_ns = 0.0
    for subject, byte_count, duration_ns in memory_rows:
        total_bytes += float(byte_count)
        total_time_ns += float(duration_ns)
        add_measurement(
            connection,
            run_id=run_id,
            source="derived",
            scope="transfer",
            subject=subject,
            metric="effective_bandwidth",
            value=float(byte_count) / float(duration_ns) if duration_ns else None,
            unit="GB/s",
            aggregation="total",
        )
    add_measurement(
        connection,
        run_id=run_id,
        source="derived",
        scope="transfer",
        subject="all",
        metric="effective_bandwidth",
        value=total_bytes / total_time_ns if total_time_ns else None,
        unit="GB/s",
        aggregation="total",
    )


def import_nsys_report(
    connection: sqlite3.Connection,
    run_id: int,
    report: pathlib.Path,
    *,
    nsys: str,
) -> None:
    import_timing_summary(
        connection,
        run_id,
        run_nsys_stats(nsys, report, "cuda_gpu_kern_sum"),
        scope="kernel",
        name_keys=("name", "operation"),
        count_keys=("instances", "count"),
    )
    import_timing_summary(
        connection,
        run_id,
        run_nsys_stats(nsys, report, "cuda_api_sum"),
        scope="cuda_api",
        name_keys=("name",),
        count_keys=("numcalls", "count"),
    )
    import_timing_summary(
        connection,
        run_id,
        run_nsys_stats(nsys, report, "cuda_gpu_mem_time_sum"),
        scope="memory_operation",
        name_keys=("operation", "name"),
        count_keys=("count", "operations"),
    )
    import_memory_sizes(
        connection,
        run_id,
        run_nsys_stats(nsys, report, "cuda_gpu_mem_size_sum"),
    )
    import_kernel_execution(
        connection,
        run_id,
        run_nsys_stats(nsys, report, "cuda_kern_exec_sum"),
    )
    add_derived_metrics(connection, run_id)


def nsys_output_base(report: pathlib.Path) -> pathlib.Path:
    text = str(report)
    suffix = ".nsys-rep"
    return pathlib.Path(text[: -len(suffix)] if text.endswith(suffix) else text)


def print_run_summary(connection: sqlite3.Connection, run_id: int) -> None:
    run = connection.execute(
        "SELECT label, status, gpu_name FROM benchmark_runs WHERE id = ?", (run_id,)
    ).fetchone()
    print(f"\nStored run {run_id}: {run[0]} [{run[1]}] GPU={run[2] or 'unknown'}")
    rows = connection.execute(
        """
        SELECT scope, subject, metric, aggregation, value, unit
        FROM measurements
        WHERE run_id = ? AND (
            (scope = 'application' AND metric IN ('duration', 'throughput')) OR
            (scope = 'gpu' AND subject = 'all') OR
            (scope = 'transfer' AND metric = 'effective_bandwidth')
        )
        ORDER BY scope, subject, metric, aggregation
        """,
        (run_id,),
    ).fetchall()
    for scope, subject, metric, aggregation, value, unit in rows:
        print(
            f"  {scope}/{subject}: {metric}.{aggregation}="
            f"{value:.6g} {unit}"
        )


def capture_command(args: argparse.Namespace) -> int:
    command = list(args.command)
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        raise ValueError("A benchmark command is required after --")

    unprofiled = run_process(command)
    payload = parse_benchmark_payload(unprofiled.stdout)
    database = pathlib.Path(args.db)
    label, report = capture_identity(database, args.label, args.report)

    with connect_database(database) as connection:
        run_id = create_run(
            connection,
            label=label,
            status="capturing",
            command=command,
            report_path=str(report),
            notes=args.notes,
            commit_override=args.commit,
            payload=payload,
        )
        import_application_payload(connection, run_id, payload)
        connection.commit()

        if args.skip_profile:
            final_status = (
                "complete-unprofiled"
                if payload.get("deterministic", False)
                else "complete-unprofiled-nondeterministic"
            )
            connection.execute(
                "UPDATE benchmark_runs SET status = ? WHERE id = ?",
                (final_status, run_id),
            )
        else:
            output_base = nsys_output_base(report)
            output_base.parent.mkdir(parents=True, exist_ok=True)
            profile_command = [
                args.nsys,
                "profile",
                "--trace=cuda,nvtx",
                "--sample=none",
                "--cpuctxsw=none",
                "--force-overwrite=true",
                f"--output={output_base}",
                *command,
            ]
            try:
                run_process(profile_command)
                import_nsys_report(connection, run_id, report, nsys=args.nsys)
                final_status = (
                    "complete"
                    if payload.get("deterministic", False)
                    else "complete-nondeterministic"
                )
                connection.execute(
                    "UPDATE benchmark_runs SET status = ? WHERE id = ?",
                    (final_status, run_id),
                )
            except Exception:
                connection.execute(
                    "UPDATE benchmark_runs SET status = 'partial' WHERE id = ?",
                    (run_id,),
                )
                connection.commit()
                raise
        connection.commit()
        print_run_summary(connection, run_id)
        return run_id


def import_nsys_command(args: argparse.Namespace) -> int:
    report = pathlib.Path(args.report)
    with connect_database(pathlib.Path(args.db)) as connection:
        run_id = create_run(
            connection,
            label=args.label,
            status="importing",
            command=[],
            report_path=str(report),
            notes=args.notes,
            commit_override=args.commit,
            payload=None,
        )
        try:
            import_nsys_report(connection, run_id, report, nsys=args.nsys)
            connection.execute(
                "UPDATE benchmark_runs SET status = 'complete-profile-only' WHERE id = ?",
                (run_id,),
            )
        except Exception:
            connection.execute(
                "UPDATE benchmark_runs SET status = 'failed' WHERE id = ?", (run_id,)
            )
            connection.commit()
            raise
        connection.commit()
        print_run_summary(connection, run_id)
        return run_id


def import_ncu_output(
    connection: sqlite3.Connection, run_id: int, output: str
) -> int:
    rows = extract_csv_rows(output, {"metricname", "metricvalue"})
    imported = 0
    for raw_row in rows:
        row = normalized_row(raw_row)
        metric_name = row_text(row, "metricname")
        metric_value, _ = row_value(row, "metricvalue")
        if metric_value is None:
            continue
        kernel_name = row_text(row, "kernelname") if "kernelname" in row else "unknown"
        launch_id = row.get("id")
        subject = f"{kernel_name} [launch={launch_id[1]}]" if launch_id else kernel_name
        unit = row_text(row, "metricunit") if "metricunit" in row else "value"
        metadata = {
            original: value
            for key, (original, value) in row.items()
            if key not in {"metricname", "metricvalue", "metricunit"}
        }
        add_measurement(
            connection,
            run_id=run_id,
            source="ncu",
            scope="kernel",
            subject=subject,
            metric=metric_name,
            value=metric_value,
            unit=unit,
            aggregation="raw",
            sample_count=1,
            metadata=metadata,
        )
        imported += 1
    return imported


def import_ncu_command(args: argparse.Namespace) -> None:
    result = run_process(
        [args.ncu, "--import", args.report, "--csv", "--page", "raw"], echo=False
    )
    with connect_database(pathlib.Path(args.db)) as connection:
        exists = connection.execute(
            "SELECT 1 FROM benchmark_runs WHERE id = ?", (args.run_id,)
        ).fetchone()
        if not exists:
            raise ValueError(f"Run {args.run_id} does not exist")
        imported = import_ncu_output(connection, args.run_id, result.stdout)
        connection.commit()
    print(f"Imported {imported} numeric NCU metrics into run {args.run_id}")


def metric_for_run(
    connection: sqlite3.Connection,
    run_id: int,
    *,
    source: str,
    scope: str,
    subject: str,
    metric: str,
    aggregation: str,
) -> float | None:
    row = connection.execute(
        """
        SELECT value FROM measurements
        WHERE run_id = ? AND source = ? AND scope = ? AND subject = ?
          AND metric = ? AND aggregation = ?
        """,
        (run_id, source, scope, subject, metric, aggregation),
    ).fetchone()
    return float(row[0]) if row else None


def format_optional(value: float | None, divisor: float = 1.0) -> str:
    return "-" if value is None else f"{value / divisor:.3f}"


def compare_command(args: argparse.Namespace) -> None:
    with connect_database(pathlib.Path(args.db)) as connection:
        runs = connection.execute(
            """
            SELECT id, recorded_at, label, status, gpu_name
            FROM benchmark_runs
            ORDER BY id DESC
            LIMIT ?
            """,
            (args.limit,),
        ).fetchall()
        if not runs:
            print("No benchmark runs stored")
            return
        runs.reverse()
        print(
            "ID  Label                 App median  FPS       Kernels   Copies    BW        Status"
        )
        print(
            "--  --------------------  ----------  --------  --------  --------  --------  ---------------------"
        )
        for run_id, _, label, status, _ in runs:
            scope = "image_processing_end_to_end"
            app_median = metric_for_run(
                connection,
                run_id,
                source="benchmark",
                scope="application",
                subject=scope,
                metric="duration",
                aggregation="median",
            )
            fps = metric_for_run(
                connection,
                run_id,
                source="benchmark",
                scope="application",
                subject=scope,
                metric="throughput",
                aggregation="value",
            )
            kernel_ns = metric_for_run(
                connection,
                run_id,
                source="derived",
                scope="gpu",
                subject="all",
                metric="kernel_time",
                aggregation="total",
            )
            copy_ns = metric_for_run(
                connection,
                run_id,
                source="derived",
                scope="gpu",
                subject="all",
                metric="memory_operation_time",
                aggregation="total",
            )
            bandwidth = metric_for_run(
                connection,
                run_id,
                source="derived",
                scope="transfer",
                subject="all",
                metric="effective_bandwidth",
                aggregation="total",
            )
            print(
                f"{run_id:<3} {label[:20]:<20}  "
                f"{format_optional(app_median):>8} ms  "
                f"{format_optional(fps):>8}  "
                f"{format_optional(kernel_ns, 1_000_000):>6} ms  "
                f"{format_optional(copy_ns, 1_000_000):>6} ms  "
                f"{format_optional(bandwidth):>6} GB/s  "
                f"{status}"
            )


def list_command(args: argparse.Namespace) -> None:
    with connect_database(pathlib.Path(args.db)) as connection:
        rows = connection.execute(
            """
            SELECT id, recorded_at, label, status, gpu_name, git_commit
            FROM benchmark_runs ORDER BY id DESC LIMIT ?
            """,
            (args.limit,),
        ).fetchall()
    for run_id, recorded_at, label, status, gpu_name, commit in rows:
        print(
            f"{run_id}: {recorded_at} {label} [{status}] "
            f"GPU={gpu_name or '-'} commit={(commit or '-')[:12]}"
        )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="subcommand", required=True)

    capture = subparsers.add_parser(
        "capture", help="Run benchmark, capture NSYS report, and store metrics"
    )
    capture.add_argument("--db", default="reports/cuda-benchmarks.sqlite")
    capture.add_argument(
        "--report", help="NSYS output path; defaults to a timestamped report"
    )
    capture.add_argument(
        "--label", help="Run label; defaults to the capture timestamp"
    )
    capture.add_argument("--notes")
    capture.add_argument("--commit")
    capture.add_argument("--nsys", default="nsys")
    capture.add_argument("--skip-profile", action="store_true")
    capture.add_argument("command", nargs=argparse.REMAINDER)
    capture.set_defaults(handler=capture_command)

    import_nsys = subparsers.add_parser(
        "import-nsys", help="Import an existing NSYS report into a new run"
    )
    import_nsys.add_argument("--db", default="reports/cuda-benchmarks.sqlite")
    import_nsys.add_argument("--report", required=True)
    import_nsys.add_argument("--label", required=True)
    import_nsys.add_argument("--notes")
    import_nsys.add_argument("--commit")
    import_nsys.add_argument("--nsys", default="nsys")
    import_nsys.set_defaults(handler=import_nsys_command)

    import_ncu = subparsers.add_parser(
        "import-ncu", help="Attach numeric NCU raw metrics to an existing run"
    )
    import_ncu.add_argument("--db", default="reports/cuda-benchmarks.sqlite")
    import_ncu.add_argument("--report", required=True)
    import_ncu.add_argument("--run-id", type=int, required=True)
    import_ncu.add_argument("--ncu", default="ncu")
    import_ncu.set_defaults(handler=import_ncu_command)

    compare = subparsers.add_parser("compare", help="Compare recent benchmark runs")
    compare.add_argument("--db", default="reports/cuda-benchmarks.sqlite")
    compare.add_argument("--limit", type=int, default=10)
    compare.set_defaults(handler=compare_command)

    list_runs = subparsers.add_parser("list", help="List stored benchmark runs")
    list_runs.add_argument("--db", default="reports/cuda-benchmarks.sqlite")
    list_runs.add_argument("--limit", type=int, default=20)
    list_runs.set_defaults(handler=list_command)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        result = args.handler(args)
        return int(result) if isinstance(result, int) and result < 0 else 0
    except (OSError, RuntimeError, ValueError, sqlite3.Error, json.JSONDecodeError) as error:
        print(f"cuda_bench: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
