#!/usr/bin/env python3
"""Validate sanitized transport snippets without requiring a live Xray node."""

from __future__ import annotations

import json
import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
TEMPLATES = ROOT / "docs" / "remnawave-transport-templates"


def load(name: str) -> dict:
    with (TEMPLATES / name).open(encoding="utf-8") as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        raise AssertionError(f"{name}: top level must be an object")
    return value


def no_secrets(value: object, location: str = "root") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            if key.lower() in {"password", "secretkey", "token", "uuid"}:
                raise AssertionError(f"{location}.{key}: secret-bearing field must not be included")
            no_secrets(child, f"{location}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            no_secrets(child, f"{location}[{index}]")
    elif isinstance(value, str):
        if re.search(r"(?i)(?:[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}|eyJ[A-Za-z0-9_-]{20,}\.)", value):
            raise AssertionError(f"{location}: UUID/JWT-like value found")
        if key_looks_sensitive(location) and not value.startswith("__"):
            raise AssertionError(f"{location}: sensitive value must be a placeholder")


def key_looks_sensitive(location: str) -> bool:
    return any(part in location.lower() for part in ("privatekey", "publickey", "shortid", ".id"))


def check_inbound(name: str, network: str, security: str) -> dict:
    value = load(name)
    stream = value["streamSettings"]
    assert stream["network"] == network, name
    assert stream["security"] == security, name
    no_secrets(value)
    return value


def main() -> int:
    tcp_tls = check_inbound("vless-tcp-tls-inbound.json", "raw", "tls")
    assert tcp_tls["settings"]["fallbacks"] == [{"dest": "127.0.0.1:8080"}]
    assert tcp_tls["streamSettings"]["tlsSettings"]["minVersion"] == "1.2"
    assert tcp_tls["streamSettings"]["tlsSettings"]["maxVersion"] == "1.3"

    for name in ("vless-tcp-reality-inbound.json", "vless-xhttp-reality-inbound.json"):
        network = "raw" if "tcp-" in name else "xhttp"
        inbound = check_inbound(name, network, "reality")
        reality = inbound["streamSettings"]["realitySettings"]
        assert reality["target"] == "127.0.0.1:9443"
        assert reality["xver"] == 0
        assert reality["privateKey"].startswith("__")
    xhttp_reality = load("vless-xhttp-reality-inbound.json")["streamSettings"]
    assert "mode" not in xhttp_reality["xhttpSettings"], "server must retain the core default mode behavior"

    xhttp_tls = check_inbound("vless-xhttp-tls-loopback-candidate.json", "xhttp", "tls")
    assert (xhttp_tls["listen"], xhttp_tls["port"]) == ("127.0.0.1", 8443)
    grpc_tls = check_inbound("vless-grpc-tls-loopback-candidate.json", "grpc", "tls")
    assert (grpc_tls["listen"], grpc_tls["port"]) == ("127.0.0.1", 8444)
    assert grpc_tls["streamSettings"]["tlsSettings"]["alpn"][0] == "h2"

    for mode in ("auto", "stream-one", "stream-up", "packet-up"):
        client = load(f"xhttp-client-{mode}.json")
        stream = client["streamSettings"]
        assert stream["network"] == "xhttp" and stream["security"] == "reality"
        assert stream["xhttpSettings"]["mode"] == mode
        assert "flow" not in stream["xhttpSettings"]
        no_secrets(client)

    for name in ("vless-tcp-tls-client.json", "vless-tcp-reality-client.json", "vless-xhttp-tls-client.json", "vless-grpc-tls-client.json"):
        no_secrets(load(name))

    print("transport templates: PASS (JSON and structural checks; Xray runtime/Happ not tested)")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, KeyError, OSError, json.JSONDecodeError) as error:
        print(f"transport templates: FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
