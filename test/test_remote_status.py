import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('remote_status', Path(__file__).parents[1] / 'assets/remote_status.py')
status = importlib.util.module_from_spec(spec)
spec.loader.exec_module(status)


class StatusTests(unittest.TestCase):
    def test_cpu_delta_not_load_average_and_multiple_gpus(self):
        with patch.object(status, 'cpu_sample', side_effect=[(100, 70, 8), (200, 120, 8)]), \
                patch.object(status.time, 'sleep'), \
                patch.object(status, 'gpu_stats', return_value=[{'name': 'A'}, {'name': 'B'}]):
            result = status.resources()
        self.assertEqual(result['cpuPercent'], 50)
        self.assertEqual(result['cpuCores'], 8)
        self.assertEqual(len(result['gpus']), 2)

    def test_missing_metrics_do_not_become_zero(self):
        with patch.object(status, 'cpu_sample', side_effect=FileNotFoundError), \
                patch.object(status, 'gpu_stats', side_effect=subprocess.TimeoutExpired('gpu', 4)):
            result = status.resources()
        self.assertIsNone(result['cpuPercent'])
        self.assertIn('cpuError', result)
        self.assertIn('gpuError', result)

    def test_nvidia_csv_preserves_unsupported_metric_and_comma_in_name(self):
        with patch.object(status.shutil, 'which', return_value='/bin/nvidia-smi'), \
                patch.object(status.subprocess, 'run', return_value=subprocess.CompletedProcess(
                    [], 0, '"GPU, A", 25, 100, 1000\nGPU B, [N/A], 200, 2000\n')):
            result = status.gpu_stats()
        self.assertEqual(result[0]['name'], 'GPU, A')
        self.assertEqual(result[0]['usedPercent'], 25)
        self.assertIsNone(result[1]['usedPercent'])
        self.assertEqual(result[1]['memoryTotalMiB'], 2000)



if __name__ == '__main__':
    unittest.main()
