#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any
from urllib import error, request

DEFAULT_BACKEND = os.environ.get("IOS_GTD_BACKEND", "http://127.0.0.1:8000")
DEFAULT_TIMEZONE = os.environ.get("IOS_GTD_TIMEZONE", "Asia/Shanghai")
DEFAULT_SOURCE = os.environ.get("IOS_GTD_SOURCE", "feishu_chat")
DEFAULT_ACTOR = os.environ.get("IOS_GTD_ACTOR", "openclaw_feishu")


def build_payload(args: argparse.Namespace) -> dict[str, Any]:
    return {
        "input": args.text,
        "context": {
            "timezone": args.timezone,
            "source": args.source,
            "source_ref": args.source_ref,
            "actor": args.actor,
        },
        "apply": not args.dry_run,
    }


def post_json(url: str, payload: dict[str, Any], timeout: float) -> tuple[int, dict[str, Any]]:
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json; charset=utf-8"},
        method="POST",
    )
    try:
        with request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8")
            return resp.status, json.loads(body)
    except error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        try:
            parsed = json.loads(body)
        except json.JSONDecodeError:
            parsed = {"error": body}
        return exc.code, parsed


def summarize(payload: dict[str, Any]) -> dict[str, Any]:
    draft = payload.get("draft") or {}
    created = payload.get("created") or {}
    return {
        "applied": payload.get("applied"),
        "created": payload.get("created") is not None,
        "entity_type": created.get("entity_type"),
        "task_id": created.get("task_id"),
        "project_id": created.get("project_id"),
        "summary": draft.get("summary"),
        "bucket": draft.get("bucket"),
        "needs_confirmation": draft.get("needs_confirmation"),
        "questions": payload.get("questions") or [],
        "error_code": payload.get("error_code"),
        "raw": payload,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Capture a Feishu message into ios-gtd backend.")
    parser.add_argument("text", help="Message text, e.g. 提醒：明晚8点给张三发合同")
    parser.add_argument("--backend", default=DEFAULT_BACKEND, help="Backend base URL, default from IOS_GTD_BACKEND or http://127.0.0.1:8000")
    parser.add_argument("--timezone", default=DEFAULT_TIMEZONE, help="Timezone for parsing relative times")
    parser.add_argument("--source", default=DEFAULT_SOURCE, help="Source tag written into the task")
    parser.add_argument("--source-ref", default=None, help="Source reference, e.g. Feishu message_id")
    parser.add_argument("--actor", default=DEFAULT_ACTOR, help="Actor field for operation log")
    parser.add_argument("--dry-run", action="store_true", help="Parse only, do not persist")
    parser.add_argument("--timeout", type=float, default=10.0, help="HTTP timeout seconds")
    args = parser.parse_args()

    url = args.backend.rstrip("/") + "/api/assistant/capture"
    payload = build_payload(args)
    status, body = post_json(url, payload, timeout=args.timeout)
    result = summarize(body)
    result["http_status"] = status
    print(json.dumps(result, ensure_ascii=False, indent=2))
    if status >= 400:
        return 1
    return 0 if (args.dry_run or not result["needs_confirmation"]) else 2


if __name__ == "__main__":
    sys.exit(main())
