#!/usr/bin/env python3
"""Local debug helper for agent gateway proxy."""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request


def load_dotenv(path: str = ".env") -> None:
    if not os.path.exists(path):
        return
    with open(path, "r", encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            if key and key not in os.environ:
                os.environ[key] = value


def main() -> None:
    load_dotenv()
    payload = {
        "requestID": "test-1",
        "role": "user",
        "prompt": "Generate an image of a red apple",
        "modelId": "gemini-3-pro-image-preview",
        "timeoutMs": 30000,
        "sessionID": "sess-test",
        "senderAlias": "anon",
    }
    url = os.environ.get("AGENT_GATEWAY_URL", "http://127.0.0.1:8080/agent/run")
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req) as resp:
            print("STATUS", resp.status)
            print(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        print("HTTP ERROR", exc.code)
        try:
            print(exc.read().decode("utf-8"))
        except Exception:
            pass
    except Exception as exc:
        print("ERROR", exc)


if __name__ == "__main__":
    main()
