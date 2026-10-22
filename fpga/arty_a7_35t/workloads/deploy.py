#!/usr/bin/env python3
"""Deploy the workload using the existing reset-safe retained-UART uploader."""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'triangulator'))
from deploy import main

if __name__ == '__main__':
    if '--binary' not in sys.argv:
        sys.argv += ['--binary', str(HERE.parent / 'build/workloads/workloads')]
    if '--destination' not in sys.argv:
        sys.argv += ['--destination', '/tmp/workloads']
    main()
