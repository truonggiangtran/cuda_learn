#!/usr/bin/env python3

import pathlib
import tempfile
import unittest

import cuda_bench


class CudaBenchTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.database = pathlib.Path(self.temp_dir.name) / "bench.sqlite"
        self.connection = cuda_bench.connect_database(self.database)
        self.run_id = cuda_bench.create_run(
            self.connection,
            label="test",
            status="test",
            command=["cuda_benchmark"],
            report_path="test.nsys-rep",
            notes=None,
            commit_override="abc123",
            payload={"scope": "image_processing_end_to_end"},
        )

    def tearDown(self) -> None:
        self.connection.close()
        self.temp_dir.cleanup()

    def test_imports_nsys_timing_summary(self) -> None:
        output = """Processing report...\n\"Time (%)\",\"Total Time (ns)\",\"Instances\",\"Avg (ns)\",\"Med (ns)\",\"Min (ns)\",\"Max (ns)\",\"StdDev (ns)\",\"Name\"\n28.9,96708,2,48354,48000,47000,49708,1354,\"combine_rgb_kernel(unsigned char*, int)\"\n"""
        cuda_bench.import_timing_summary(
            self.connection,
            self.run_id,
            output,
            scope="kernel",
            name_keys=("name",),
            count_keys=("instances",),
        )
        row = self.connection.execute(
            """
            SELECT value, unit, sample_count FROM measurements
            WHERE run_id = ? AND scope = 'kernel' AND metric = 'duration'
              AND aggregation = 'mean'
            """,
            (self.run_id,),
        ).fetchone()
        self.assertEqual((48354.0, "ns", 2), row)

    def test_derives_transfer_bandwidth(self) -> None:
        time_output = """\"Time (%)\",\"Total Time (ns)\",\"Count\",\"Avg (ns)\",\"Med (ns)\",\"Min (ns)\",\"Max (ns)\",\"StdDev (ns)\",\"Operation\"\n100,2000000,2,1000000,1000000,900000,1100000,100000,\"[CUDA memcpy Device-to-Host]\"\n"""
        size_output = """\"Total (MiB)\",\"Count\",\"Avg (MiB)\",\"Med (MiB)\",\"Min (MiB)\",\"Max (MiB)\",\"StdDev (MiB)\",\"Operation\"\n20,2,10,10,10,10,0,\"[CUDA memcpy Device-to-Host]\"\n"""
        cuda_bench.import_timing_summary(
            self.connection,
            self.run_id,
            time_output,
            scope="memory_operation",
            name_keys=("operation",),
            count_keys=("count",),
        )
        cuda_bench.import_memory_sizes(self.connection, self.run_id, size_output)
        cuda_bench.add_derived_metrics(self.connection, self.run_id)
        bandwidth = self.connection.execute(
            """
            SELECT value FROM measurements
            WHERE run_id = ? AND source = 'derived' AND scope = 'transfer'
              AND subject = 'all' AND metric = 'effective_bandwidth'
            """,
            (self.run_id,),
        ).fetchone()[0]
        self.assertAlmostEqual(10.48576, bandwidth)

    def test_imports_application_payload(self) -> None:
        payload = {
            "scope": "image_processing_end_to_end",
            "measured_iterations": 20,
            "warmup_iterations": 5,
            "mean_ms": 4.0,
            "median_ms": 3.9,
            "p95_ms": 4.4,
            "min_ms": 3.7,
            "max_ms": 4.6,
            "stddev_ms": 0.2,
            "throughput_fps": 250.0,
            "input_bytes": 100,
            "output_bytes": 200,
            "deterministic": True,
            "gpu_name": "Test GPU",
            "sm_count": 10,
            "global_memory_bytes": 1000,
        }
        cuda_bench.import_application_payload(self.connection, self.run_id, payload)
        values = self.connection.execute(
            """
            SELECT aggregation, value FROM measurements
            WHERE run_id = ? AND scope = 'application' AND metric = 'duration'
            ORDER BY aggregation
            """,
            (self.run_id,),
        ).fetchall()
        self.assertEqual(6, len(values))

    def test_imports_ncu_raw_metrics(self) -> None:
        output = """\"ID\",\"Process ID\",\"Kernel Name\",\"Section Name\",\"Metric Name\",\"Metric Unit\",\"Metric Value\"\n1,42,\"combine_rgb_kernel\",\"GPU Speed Of Light Throughput\",\"Memory Throughput\",\"%\",\"82.5\"\n1,42,\"combine_rgb_kernel\",\"GPU Speed Of Light Throughput\",\"non_numeric_metric\",\"text\",\"n/a\"\n"""
        imported = cuda_bench.import_ncu_output(
            self.connection, self.run_id, output
        )
        self.assertEqual(1, imported)
        row = self.connection.execute(
            """
            SELECT subject, metric, value, unit FROM measurements
            WHERE run_id = ? AND source = 'ncu'
            """,
            (self.run_id,),
        ).fetchone()
        self.assertEqual(
            ("combine_rgb_kernel [launch=1]", "Memory Throughput", 82.5, "%"),
            row,
        )


if __name__ == "__main__":
    unittest.main()
