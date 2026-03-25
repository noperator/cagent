"""Membrane mitmproxy L7 filter addon.

Reads allow rules from /etc/membrane/allow.json (or MEMBRANE_ALLOW_FILE
env var) at startup and enforces http rules on intercepted requests.

Only URL entries with an explicit http array are enforced. Everything
else passes through.
"""

import json
import os

from mitmproxy import http as mhttp


def _load_rules():
    allow_file = os.environ.get("MEMBRANE_ALLOW_FILE", "/etc/membrane/allow.json")
    with open(allow_file) as f:
        rules = json.load(f)

    # Build map of host → list of (url_path, http_rules)
    # Only URL entries with http rules are enforced.
    enforced = {}
    for rule in rules:
        if rule.get("type") != "url":
            continue
        http_rules = rule.get("http")
        if not http_rules:
            continue
        host = rule.get("host", "").lower()
        url_path = rule.get("path", "") or "/"
        if host not in enforced:
            enforced[host] = []
        enforced[host].append((url_path, http_rules))
    return enforced


ENFORCED = _load_rules()


def _effective_path(url_path, rule_path):
    """Resolve rule_path against url_path.
    Absolute paths (starting with /) are used as-is.
    Relative paths are prepended with url_path.
    """
    if rule_path.startswith("/"):
        return rule_path
    return url_path.rstrip("/") + "/" + rule_path


def _matches_rule(url_path, rule, method, path):
    """Return True if the request matches this http rule."""
    # Method check
    methods = rule.get("methods")
    if methods and method.upper() not in [m.upper() for m in methods]:
        return False

    # Path check
    paths = rule.get("paths")
    if paths:
        for p in paths:
            if path.startswith(_effective_path(url_path, p["path"])):
                return True
        return False

    # No path constraint — check url_path as prefix
    if not path.startswith(url_path):
        return False

    return True


def request(flow: mhttp.HTTPFlow) -> None:
    host = flow.request.pretty_host.lower()

    if host not in ENFORCED:
        return  # no http rules for this host — passthrough

    method = flow.request.method
    path = flow.request.path

    for url_path, http_rules in ENFORCED[host]:
        for rule in http_rules:
            if _matches_rule(url_path, rule, method, path):
                return  # matched — allow

    # No rule matched — block
    flow.response = mhttp.Response.make(
        403,
        b"",
        {"Content-Type": "text/plain"},
    )
