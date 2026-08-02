"""EU Router (eurouter.ai) routing-rules fetch.

Shared by the Settings ``provider_routing.rule_name`` dropdown
(``web_server.py::get_eurouter_routing_rules``) and the model picker's
curated model list (``models.py::provider_model_ids``) — one HTTP call
implementation, two consumers, so the rule shape never drifts between them.
"""

from __future__ import annotations

import json
import urllib.request
from typing import Any, Dict, List, Optional, TypedDict


class EuRouterRoutingRule(TypedDict):
    id: str
    name: str
    enabled: bool
    model: str
    models: List[str]


def fetch_eurouter_routing_rules(
    api_key: str, *, timeout: float = 10.0
) -> Optional[List[EuRouterRoutingRule]]:
    """Fetch the user's saved routing rules from eurouter.ai.

    Returns ``None`` on any failure (no key, network error, auth failure,
    malformed response) so callers can fall back to their own default
    behaviour — an empty list would be indistinguishable from "this account
    genuinely has zero rules". Blocking call; run off the event loop.
    """
    if not api_key:
        return None

    request = urllib.request.Request(
        "https://api.eurouter.ai/api/v1/routing-rules",
        headers={"Accept": "application/json", "Authorization": f"Bearer {api_key}"},
    )

    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload: Dict[str, Any] = json.loads(response.read().decode("utf-8"))
    except Exception:
        return None

    rules: List[EuRouterRoutingRule] = []
    for rule in payload.get("data") or []:
        if not isinstance(rule, dict):
            continue
        name = str(rule.get("name") or "").strip()
        if not name:
            continue
        model = str(rule.get("model") or "").strip()
        extra_models = [
            str(m).strip() for m in (rule.get("models") or []) if str(m).strip()
        ]
        rules.append(
            {
                "id": str(rule.get("id") or ""),
                "name": name,
                "enabled": bool(rule.get("enabled", True)),
                "model": model,
                "models": extra_models,
            }
        )

    rules.sort(key=lambda item: item["name"].lower())
    return rules
