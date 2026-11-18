#!/usr/bin/env python3
"""Prints the UDID of the simulator the iOS CI job runs on, and says which it picked on stderr.

The newest released iOS runtime installed (never a beta: release builds look like 24B8117, betas end in a
letter, like 24B91016s), and on it an iPhone 17 Pro. Runtimes made for one device model only (such as
iOS-27-2-iPhone19-4) are skipped. If no iPhone 17 Pro exists on that runtime (GitHub-hosted images for pull
requests), the first iPhone on it is used instead.
"""
import json
import re
import subprocess
import sys

def simctl(*args):
    return json.loads(subprocess.check_output(["xcrun", "simctl", "list", "-j", *args]))

released = [
    r for r in simctl("runtimes")["runtimes"]
    if r.get("isAvailable") and r.get("platform") == "iOS"
    and re.fullmatch(r"\d+[A-Z]\d+", r.get("buildversion", ""))
    and re.fullmatch(r"com\.apple\.CoreSimulator\.SimRuntime\.iOS-[\d-]+", r["identifier"])
]
if not released:
    sys.exit("No released iOS simulator runtime is installed")
runtime = max(released, key=lambda r: [int(p) for p in r["version"].split(".")])
devices = [d for d in simctl("devices", "available")["devices"].get(runtime["identifier"], []) if "iPhone" in d["name"]]
device = next((d for d in devices if d["name"] == "iPhone 17 Pro"), devices[0] if devices else None)
if device is None:
    sys.exit(f"No iPhone simulator on {runtime['name']}")
print(f"Simulator: {device['name']} on {runtime['name']} ({runtime['buildversion']})", file=sys.stderr)
print(device["udid"])
