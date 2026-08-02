"""Tests for EU Router provider registration and routing-rule model curation."""

from __future__ import annotations

from hermes_cli.eurouter_routing import fetch_eurouter_routing_rules
from hermes_cli.models import provider_model_ids
from hermes_cli.providers import ALIASES, HERMES_OVERLAYS, _LABEL_OVERRIDES


class TestEuRouterOverlay:
    def test_overlay_exists(self):
        assert "eurouter" in HERMES_OVERLAYS
        overlay = HERMES_OVERLAYS["eurouter"]
        assert overlay.transport == "openai_chat"
        assert overlay.is_aggregator
        assert overlay.extra_env_vars == ("EUROUTER_API_KEY",)
        assert overlay.base_url_override == "https://api.eurouter.ai/api/v1"

    def test_aliases_resolve(self):
        assert ALIASES["eu-router"] == "eurouter"
        assert ALIASES["eur"] == "eurouter"

    def test_label_override(self):
        assert _LABEL_OVERRIDES["eurouter"] == "EU Router"


class TestFetchEuRouterRoutingRules:
    def test_no_api_key_returns_none(self):
        assert fetch_eurouter_routing_rules("") is None

    def test_parses_rules_and_skips_unnamed(self, monkeypatch):
        class _Resp:
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def read(self):
                import json

                return json.dumps(
                    {
                        "data": [
                            {
                                "id": "r2",
                                "name": "EU Compliance 2",
                                "enabled": True,
                                "model": "glm-5.2",
                                "models": ["glm-5.1"],
                            },
                            {
                                "id": "r1",
                                "name": "EU Compliance",
                                "enabled": True,
                                "model": "deepseek-v4-flash",
                                "models": None,
                            },
                            # No name — must be skipped.
                            {"id": "r3", "name": "", "enabled": True, "model": "x"},
                        ]
                    }
                ).encode("utf-8")

        monkeypatch.setattr(
            "urllib.request.urlopen", lambda *a, **kw: _Resp()
        )

        rules = fetch_eurouter_routing_rules("eur_test_key")

        assert rules is not None
        assert [r["name"] for r in rules] == ["EU Compliance", "EU Compliance 2"]
        assert rules[1]["model"] == "glm-5.2"
        assert rules[1]["models"] == ["glm-5.1"]
        assert rules[0]["models"] == []

    def test_network_error_returns_none(self, monkeypatch):
        def _raise(*a, **kw):
            raise OSError("network down")

        monkeypatch.setattr("urllib.request.urlopen", _raise)

        assert fetch_eurouter_routing_rules("eur_test_key") is None


class TestEuRouterCuratedModelList:
    def test_curates_from_enabled_rules_only(self, monkeypatch):
        monkeypatch.setattr(
            "hermes_cli.auth.resolve_api_key_provider_credentials",
            lambda provider_id: {"api_key": "eur_test_key"},
        )
        monkeypatch.setattr(
            "hermes_cli.eurouter_routing.fetch_eurouter_routing_rules",
            lambda api_key, **kw: [
                {"id": "1", "name": "A", "enabled": True, "model": "deepseek-v4-flash", "models": []},
                {"id": "2", "name": "B", "enabled": True, "model": "glm-5.2", "models": ["glm-5.1"]},
                {"id": "3", "name": "Disabled", "enabled": False, "model": "should-not-appear", "models": []},
            ],
        )

        assert provider_model_ids("eurouter") == [
            "deepseek-v4-flash",
            "glm-5.2",
            "glm-5.1",
        ]

    def test_falls_back_to_generic_path_when_rules_unavailable(self, monkeypatch):
        # No API key at all: the eurouter branch skips the rules fetch
        # entirely (no network call), and the generic profile-based path
        # below it also skips its own live fetch for the same reason,
        # landing on the profile's static fallback_models — no network I/O
        # anywhere in this test.
        monkeypatch.setattr(
            "hermes_cli.auth.resolve_api_key_provider_credentials",
            lambda provider_id: {"api_key": ""},
        )

        from providers import get_provider_profile

        profile = get_provider_profile("eurouter")
        assert profile is not None
        models = provider_model_ids("eurouter")
        assert models == list(profile.fallback_models)
