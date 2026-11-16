#!/usr/bin/env python3
"""Fail closed when effective Compose database/admin/frontend ports are not loopback-only."""
import json
from pathlib import Path
import subprocess
import sys


def main():
    root = Path(__file__).resolve().parents[1]
    compose = sys.argv[1] if len(sys.argv) == 2 else "docker-compose.deploy.yml"
    if len(sys.argv) > 2:
        print("Usage: check-admin-ports.py [compose-file]", file=sys.stderr)
        return 1
    result = subprocess.run(
        ["docker", "compose", "-f", compose, "--profile", "admin", "config", "--format", "json"],
        cwd=root, capture_output=True, text=True, check=False,
    )
    # Rendered configuration and Docker diagnostics can contain private values.
    if result.returncode:
        print("Cannot render Compose configuration; check it privately before startup.", file=sys.stderr)
        return 1
    try:
        services = json.loads(result.stdout)["services"]
        names = ["db", "pgadmin"]
        if "frontend" in services:
            names.append("frontend")
        for name in names:
            ports = services[name].get("ports", [])
            if not ports or any(port.get("host_ip") not in ("127.0.0.1", "::1") for port in ports):
                print(f"Unsafe {name} host binding. Set its port to 127.0.0.1:PORT in .env "
                      "and check shell overrides. See docs/admin-port-migration.md.", file=sys.stderr)
                return 1
    except (ValueError, KeyError, TypeError, AttributeError):
        print("Cannot verify Compose database/admin/frontend port bindings; startup blocked.", file=sys.stderr)
        return 1
    print("Compose database/admin/frontend host bindings are loopback-only (where present).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
