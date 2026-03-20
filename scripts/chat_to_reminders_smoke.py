#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import textwrap
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Minimal smoke helper: natural language -> backend assistant capture -> optional BridgeApp sync hint"
    )
    parser.add_argument("text", help="Natural language input, e.g. '明晚8点提醒我给张三发合同'")
    parser.add_argument("--backend", default=os.getenv("IOS_GTD_BACKEND", "http://127.0.0.1:8000"), help="Backend base URL")
    parser.add_argument("--timezone", default=os.getenv("IOS_GTD_TIMEZONE", "Asia/Shanghai"), help="Timezone for assistant capture")
    parser.add_argument("--source", default="chat_smoke", help="source field passed into assistant context")
    parser.add_argument("--source-ref", default="local-smoke", help="source_ref field passed into assistant context")
    parser.add_argument("--actor", default="chat_smoke", help="actor field passed into assistant context")
    parser.add_argument("--apply", action="store_true", help="Persist to backend (default: parse only)")
    parser.add_argument("--bridge-config", default=os.getenv("IOS_GTD_BRIDGE_CONFIG", str(Path.home() / "Library/Application Support/GTD/mac-sync-bridge/config.json")), help="Path to mac-sync-bridge config.json on Mac")
    parser.add_argument("--print-bridge-command", action="store_true", help="Print the exact BridgeApp once command after successful creation")
    parser.add_argument("--run-bridge-once", action="store_true", help="Try to run BridgeApp --once locally after successful creation")
    return parser.parse_args()


def post_json(url: str, payload: dict) -> dict:
    body = json.dumps(payload).encode("utf-8")
    req = Request(url, data=body, headers={"Content-Type": "application/json", "Accept": "application/json"}, method="POST")
    try:
        with urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except HTTPError as e:
        error_body = e.read().decode("utf-8", errors="replace")
        raise SystemExit(f"HTTP {e.code} calling {url}\n{error_body}") from e
    except URLError as e:
        raise SystemExit(f"Network error calling {url}: {e}") from e


def bridge_once_command(config_path: str) -> str:
    escaped = config_path.replace(" ", "\\ ")
    return f"cd mac-sync-bridge && swift run BridgeApp --config {escaped} --once"


def maybe_run_bridge_once(repo_root: Path, config_path: str) -> int:
    cmd = ["swift", "run", "BridgeApp", "--config", config_path, "--once"]
    return subprocess.call(cmd, cwd=repo_root / "mac-sync-bridge")


def main() -> int:
    args = parse_args()
    repo_root = Path(__file__).resolve().parents[1]
    backend = args.backend.rstrip("/")
    url = f"{backend}/api/assistant/capture"

    payload = {
        "input": args.text,
        "context": {
            "timezone": args.timezone,
            "source": args.source,
            "source_ref": args.source_ref,
            "actor": args.actor,
        },
        "apply": args.apply,
    }

    response = post_json(url, payload)
    print(json.dumps(response, ensure_ascii=False, indent=2))

    created = response.get("created")
    draft = response.get("draft") or {}
    needs_confirmation = bool(draft.get("needs_confirmation"))

    if not args.apply:
        print("\n[smoke] parse-only mode complete")
        return 0

    if needs_confirmation or not created:
        print("\n[smoke] backend did not create anything. If needs_confirmation=true, ask a clearer follow-up and retry.")
        return 0

    if args.print_bridge_command or not args.run_bridge_once:
        print("\n[next] Run this on your Mac to sync backend changes into Apple Reminders:")
        print(bridge_once_command(args.bridge_config))

    if args.run_bridge_once:
        print("\n[run] trying to execute BridgeApp --once locally...")
        exit_code = maybe_run_bridge_once(repo_root, args.bridge_config)
        print(f"[run] BridgeApp exited with code {exit_code}")
        return exit_code

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
