#!/usr/bin/env python3
"""
scripts/validate_ci.py
Comprehensive static schema and best-practice validator for MediaLite GitHub Actions CI workflow.
"""
import sys
import os

try:
    import yaml
except ImportError:
    # If invoked in an environment where PyYAML is only in system Python
    if os.path.exists("/usr/bin/python3") and sys.executable != "/usr/bin/python3":
        import subprocess
        result = subprocess.run(["/usr/bin/python3", __file__] + sys.argv[1:])
        sys.exit(result.returncode)
    else:
        raise


def validate_ci_file(file_path):
    if not os.path.exists(file_path):
        return [f"Workflow file does not exist: {file_path}"]

    with open(file_path, "r", encoding="utf-8") as f:
        content = f.read()

    try:
        data = yaml.safe_load(content)
    except yaml.YAMLError as e:
        return [f"YAML Syntax Error: {e}"]

    errors = []

    # 1. Top-level keys
    if data.get("name") != "CI":
        errors.append(f"Workflow name must be 'CI', got: {data.get('name')}")

    # 2. Trigger verification
    on_data = data.get("on")
    if not on_data:
        errors.append("Missing 'on' triggers block")
    else:
        for trig in ["push", "pull_request"]:
            if trig not in on_data:
                errors.append(f"Missing '{trig}' trigger")
            else:
                branches = on_data[trig].get("branches", [])
                for b in ["main", "master", "develop"]:
                    if b not in branches:
                        errors.append(f"Trigger '{trig}' missing branch '{b}'")
        if "workflow_dispatch" not in on_data:
            errors.append("Missing 'workflow_dispatch' trigger")

    # 3. Concurrency check
    concurrency = data.get("concurrency")
    if not concurrency:
        errors.append("Missing 'concurrency' block")
    else:
        if concurrency.get("cancel-in-progress") is not True:
            errors.append("concurrency.cancel-in-progress must be True")
        if not concurrency.get("group"):
            errors.append("concurrency.group must be specified")

    # 4. Permissions check
    permissions = data.get("permissions")
    if not permissions or permissions.get("contents") != "read":
        errors.append("permissions.contents must be 'read'")

    # 5. Job checks
    jobs = data.get("jobs", {})
    if not jobs:
        errors.append("No jobs found in workflow")
    for job_id, job in jobs.items():
        if job.get("runs-on") != "macos-26":
            errors.append(f"Job '{job_id}' must run on 'macos-26', got: {job.get('runs-on')}")
        if not job.get("timeout-minutes") or job.get("timeout-minutes") > 60:
            errors.append(f"Job '{job_id}' must have a safe timeout-minutes (<= 60)")

        steps = job.get("steps", [])
        uses_list = [s.get("uses", "") for s in steps]

        if not any("actions/checkout@v4" in u for u in uses_list):
            errors.append("Missing 'actions/checkout@v4' step")

        upload_steps = [s for s in steps if "actions/upload-artifact@v4" in s.get("uses", "")]
        if len(upload_steps) < 2:
            errors.append(f"Expected at least 2 upload-artifact steps, found {len(upload_steps)}")

        xcresult_uploads = [
            s for s in upload_steps
            if "xcresult" in s.get("name", "").lower() or "xcresult" in str(s.get("with", {}).get("path", ""))
        ]
        if not xcresult_uploads:
            errors.append("Missing .xcresult artifact upload step")
        else:
            for s in xcresult_uploads:
                if s.get("if") != "always()":
                    errors.append(f"Artifact upload '{s.get('name')}' must have 'if: always()'")
                if s.get("with", {}).get("retention-days") != 14:
                    errors.append(f"Artifact upload '{s.get('name')}' retention-days must be 14")

        release_uploads = [
            s for s in upload_steps
            if "release" in s.get("name", "").lower() or "xcarchive" in str(s.get("with", {}).get("path", ""))
        ]
        if not release_uploads:
            errors.append("Missing release artifact upload step")
        else:
            for s in release_uploads:
                if s.get("if") != "success()":
                    errors.append(f"Release upload '{s.get('name')}' must have 'if: success()'")
                if s.get("with", {}).get("retention-days") != 30:
                    errors.append(f"Release upload '{s.get('name')}' retention-days must be 30")

    return errors

if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else ".github/workflows/ci.yml"
    errs = validate_ci_file(path)
    if errs:
        print(f"Validation FAILED ({len(errs)} errors):")
        for e in errs:
            print(f"  - {e}")
        sys.exit(1)
    else:
        print(f"Validation PASSED: {path} is valid and meets all standards.")
        sys.exit(0)
