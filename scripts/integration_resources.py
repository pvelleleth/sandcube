#!/usr/bin/env python3
"""Phase 5 uses the Phase 4 real crash harness plus kernel/network checks.
Requires a dedicated SANDCUBE_CONTAINERD instance whose
snapshotter is on XFS/prjquota. See docs/resources-networking.md for setup.
"""
import os
import runpy
from pathlib import Path
os.environ['SANDCUBE_PHASE5'] = '1'
runpy.run_path(str(Path(__file__).with_name('integration_reliability.py')), run_name='__main__')
