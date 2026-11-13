#!/usr/bin/env python3
"""Prints one value from the resolved settings (Generated/creator.json), for
the shell scripts:  python3 tools/setting.py backend.namespace"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
with open(os.path.join(ROOT, "Generated", "creator.json"), encoding="utf-8") as f:
    node = json.load(f)
for key in sys.argv[1].split("."):
    node = node[key]
print(node)
