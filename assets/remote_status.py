"""Read computer utilization without changing configuration."""
import csv
import io
import json
from pathlib import Path
import shutil
import subprocess
import time


def cpu_sample(path=Path('/proc/stat')):
    rows = path.read_text().splitlines()
    values = [int(value) for value in rows[0].split()[1:9]]
    return sum(values), values[3] + values[4], sum(
        1 for row in rows if row.startswith('cpu') and row[3:4].isdigit())


def number(value):
    try:
        result = float(value)
        return result if result >= 0 and result < float('inf') else None
    except (ValueError, TypeError):
        return None


def gpu_stats():
    if shutil.which('nvidia-smi'):
        result = subprocess.run([
            'nvidia-smi', '--query-gpu=name,utilization.gpu,memory.used,memory.total',
            '--format=csv,noheader,nounits'], capture_output=True, text=True,
            timeout=4, check=True)
        return [{'name': row[0].strip(), 'usedPercent': number(row[1]),
                 'memoryUsedMiB': number(row[2]), 'memoryTotalMiB': number(row[3])}
                for row in csv.reader(io.StringIO(result.stdout)) if len(row) == 4]
    devices = []
    for card in sorted(Path('/sys/class/drm').glob('card[0-9]*')):
        if not card.name[4:].isdigit():
            continue
        device = card / 'device'
        if not device.exists():
            continue
        busy = device / 'gpu_busy_percent'
        used, total = device / 'mem_info_vram_used', device / 'mem_info_vram_total'
        devices.append({'name': card.name,
                        'usedPercent': number(busy.read_text().strip()) if busy.exists() else None,
                        'memoryUsedMiB': number(used.read_text().strip()) / 1048576 if used.exists() else None,
                        'memoryTotalMiB': number(total.read_text().strip()) / 1048576 if total.exists() else None})
    return devices


def resources():
    result = {'cpuPercent': None, 'cpuCores': None, 'gpus': []}
    try:
        before = cpu_sample()
        time.sleep(0.25)
        after = cpu_sample()
        total, idle = after[0] - before[0], after[1] - before[1]
        result['cpuCores'] = after[2]
        if total > 0:
            result['cpuPercent'] = max(0, min(100, 100 * (total - idle) / total))
    except (OSError, ValueError, IndexError):
        result['cpuError'] = '此电脑暂无法读取 CPU 使用率'
    try:
        result['gpus'] = gpu_stats()
    except (OSError, ValueError, subprocess.SubprocessError):
        result['gpuError'] = '暂无法读取 GPU 状态'
    return result


if __name__ == '__main__':
    print(json.dumps(resources(), ensure_ascii=False))
