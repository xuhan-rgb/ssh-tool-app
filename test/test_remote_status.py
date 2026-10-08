import importlib.util
from pathlib import Path
import subprocess
import tempfile
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

    def test_nvidia_failure_falls_back_to_drm(self):
        with patch.object(status.shutil, 'which', return_value='/bin/nvidia-smi'), \
                patch.object(status.subprocess, 'run', side_effect=subprocess.CalledProcessError(9, 'nvidia-smi')), \
                patch.object(status, 'drm_stats', return_value=[{'name': 'card2', 'memoryUsedMiB': None}]) as fallback:
            result = status.gpu_stats()
        fallback.assert_called_once()
        self.assertEqual(result[0]['name'], 'card2')

    def test_drm_memory_reports_used_and_total_independently(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            device = root / 'card0' / 'device'
            device.mkdir(parents=True)
            (device / 'mem_info_vram_used').write_text('104857600')
            (device / 'mem_info_vram_total').write_text('1048576000')
            result = status.drm_stats(root)[0]
            self.assertEqual(result['memoryUsedMiB'], 100)
            self.assertEqual(result['memoryTotalMiB'], 1000)
            (device / 'mem_info_vram_used').write_text('N/A')
            result = status.drm_stats(root)[0]
            self.assertIsNone(result['memoryUsedMiB'])
            self.assertEqual(result['memoryTotalMiB'], 1000)



if __name__ == '__main__':
    unittest.main()
