#!/usr/bin/env python3
"""
scripts/detect_simulator.py
Detects the best available iPhone simulator UDID from `xcrun simctl list devices available -j`.
Prioritizes latest iOS runtimes and exits with status 1 if none found.
"""
import json
import subprocess
import sys


def detect_simulator_udid(simctl_output=None):
    try:
        if simctl_output is not None:
            output = simctl_output
        else:
            output = subprocess.check_output(
                ["xcrun", "simctl", "list", "devices", "available", "-j"],
                stderr=subprocess.PIPE
            ).decode("utf-8")
        data = json.loads(output)
    except Exception as exc:
        sys.stderr.write(f"Failed to execute xcrun simctl or parse output: {exc}\n")
        return None

    devices_by_runtime = data.get("devices", {})

    # Sort iOS runtimes in descending order (e.g. iOS 26.x before older ones)
    sorted_runtimes = sorted(
        [r for r in devices_by_runtime.keys() if "iOS" in r or "iPhoneOS" in r],
        reverse=True
    )

    found_udid = None
    found_name = None

    for runtime in sorted_runtimes:
        for dev in devices_by_runtime.get(runtime, []):
            if dev.get("isAvailable", False) and "iPhone" in dev.get("name", ""):
                found_udid = dev.get("udid")
                found_name = f"{dev.get('name')} ({runtime})"
                break
        if found_udid:
            break

    # Fallback across all available device runtimes
    if not found_udid:
        for runtime, devices in devices_by_runtime.items():
            for dev in devices:
                if dev.get("isAvailable", False) and "iPhone" in dev.get("name", ""):
                    found_udid = dev.get("udid")
                    found_name = f"{dev.get('name')} ({runtime})"
                    break
            if found_udid:
                break

    if found_udid:
        sys.stderr.write(f"Detected iPhone simulator: {found_name} [UDID: {found_udid}]\n")
        return found_udid
    else:
        sys.stderr.write("No available iPhone simulator found in simctl output.\n")
        return None


if __name__ == "__main__":
    raw_data = None
    if len(sys.argv) > 1 and sys.argv[1] == "--json-file" and len(sys.argv) > 2:
        with open(sys.argv[2], "r", encoding="utf-8") as f:
            raw_data = f.read()

    udid = detect_simulator_udid(simctl_output=raw_data)
    if udid:
        print(udid)
        sys.exit(0)
    else:
        sys.exit(1)
