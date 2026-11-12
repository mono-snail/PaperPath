#!/usr/bin/env python3
"""Reviewed foreground sequence; invoke once under guard.py run --slot ios26-phone."""
import os
from pathlib import Path
import subprocess
import sys

assert os.environ["CODEX_SIMULATOR_UDID"] == "2A313B9A-7363-4AE1-ADFB-2CDF0F680653"
capture = Path(__file__).with_name("RunExcellenceCapture.py")
for arguments in [
    ["phone-final-light-v2"],
    ["phone-final-dark", "--appearance", "dark"],
    ["phone-final-dark-zh-ax", "--appearance", "dark", "--chinese", "--large-text"],
]:
    subprocess.run([sys.executable, str(capture), *arguments], check=True)
