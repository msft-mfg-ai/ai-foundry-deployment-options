#!/usr/bin/env python3
"""Select a supported image deployment deterministically from discovery JSON."""

from __future__ import annotations

import argparse
import copy
import json
import re
import sys
from dataclasses import asdict, dataclass
from urllib.parse import urlparse, urlunparse


@dataclass(frozen=True)
class Profile:
    name: str
    pattern: re.Pattern[str]
    priority: int
    path: str
    endpoint_kind: str
    api_version: str = ""


PROFILES = (
    Profile(
        "openai-v1-gpt-image",
        re.compile(r"^gpt-image-[a-z0-9][a-z0-9.-]*$", re.I),
        10,
        "openai-v1/images/generations",
        "openai",
        "2025-04-01-preview",
    ),
    Profile(
        "mai-v1-image",
        re.compile(r"^mai-image-[a-z0-9][a-z0-9.-]*$", re.I),
        20,
        "mai-v1/images/generations",
        "services-ai",
    ),
)


def profile_for(model: str) -> Profile | None:
    return next((profile for profile in PROFILES if profile.pattern.fullmatch(model)), None)


def profile_endpoint(instance: dict, profile: Profile) -> str:
    endpoint = str(instance.get("endpoint", "")).strip()
    if instance.get("isApim") or not endpoint:
        return endpoint

    explicit_key = (
        "openAiEndpoint"
        if profile.endpoint_kind == "openai"
        else "aiServicesEndpoint"
    )
    explicit = str(instance.get(explicit_key, "")).strip()
    if explicit:
        return explicit.rstrip("/") + "/"

    parsed = urlparse(endpoint)
    hostname = parsed.hostname or ""
    marker = ".cognitiveservices."
    if marker not in hostname.casefold():
        raise ValueError(
            f"Cannot derive the {profile.endpoint_kind} image endpoint from '{endpoint}'. "
            f"Provide {explicit_key} in discovery data."
        )
    account, cloud_suffix = hostname.split(marker, 1)
    profile_host = (
        f"{account}.openai.{cloud_suffix}"
        if profile.endpoint_kind == "openai"
        else f"{account}.services.ai.{cloud_suffix}"
    )
    netloc = profile_host
    if parsed.port:
        netloc = f"{profile_host}:{parsed.port}"
    return urlunparse(
        (parsed.scheme, netloc, "/", "", "", "")
    )


def select(
    instances: list[dict],
    override: str = "",
    gateway_authentication_type: str = "ProjectManagedIdentity",
) -> dict:
    candidates: list[dict] = []
    compatible_models: set[str] = set()
    annotated_instances = copy.deepcopy(instances)
    for instance_index, instance in enumerate(annotated_instances):
        for deployment_index, deployment in enumerate(instance.get("deployments", [])):
            deployment_name = str(deployment.get("modelName", "")).strip()
            catalog_name = str(
                deployment.get("modelCatalogName") or deployment_name
            ).strip()
            profile = profile_for(catalog_name)
            if profile:
                compatible_models.add(deployment_name)
                if instance.get("isApim"):
                    continue
                endpoint = profile_endpoint(instance, profile)
                candidates.append(
                    {
                        "model": deployment_name,
                        "catalogModel": catalog_name,
                        "profile": profile.name,
                        "path": profile.path,
                        "apiVersion": profile.api_version,
                        "apiEndpoint": endpoint,
                        "instance": str(instance.get("name", "")),
                        "_deployment": deployment,
                        "_sort": (
                            profile.priority,
                            catalog_name.casefold(),
                            deployment_name.casefold(),
                            instance_index,
                            deployment_index,
                        ),
                    }
                )

    compatible = sorted(compatible_models, key=str.casefold)
    managed_identity_gateway = (
        gateway_authentication_type.casefold() == "projectmanagedidentity"
    )
    if managed_identity_gateway:
        for candidate in candidates:
            candidate["_deployment"]["apiProfile"] = candidate["profile"]
            candidate["_deployment"]["apiEndpoint"] = candidate["apiEndpoint"]
    if not managed_identity_gateway:
        selected = None
    elif override:
        matches = [candidate for candidate in candidates if candidate["model"].casefold() == override.casefold()]
        if not matches:
            raise ValueError(
                f"IMAGE_MODEL '{override}' is not a discovered compatible GPT Image or MAI Image deployment name"
            )
        selected = sorted(matches, key=lambda candidate: candidate["_sort"])[0]
    else:
        selected = sorted(candidates, key=lambda candidate: candidate["_sort"])[0] if candidates else None

    if selected:
        selected = {key: value for key, value in selected.items() if key != "_sort"}
        selected.pop("_deployment")
    return {
        "enabled": selected is not None,
        "disabledReason": (
            None
            if selected is not None
            else (
                "gateway authentication mode is not ProjectManagedIdentity"
                if not managed_identity_gateway
                else "no compatible image deployment was discovered"
            )
        ),
        "selected": selected,
        "compatibleModels": compatible,
        "instances": annotated_instances,
        "profiles": [asdict(profile) | {"pattern": profile.pattern.pattern} for profile in PROFILES],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--instances-json", required=True)
    parser.add_argument("--override", default="")
    parser.add_argument(
        "--gateway-authentication-type",
        default="ProjectManagedIdentity",
    )
    args = parser.parse_args()
    try:
        instances = json.loads(args.instances_json)
        if not isinstance(instances, list):
            raise ValueError("FOUNDRY_INSTANCES_JSON must be an array")
        print(
            json.dumps(
                select(
                    instances,
                    args.override.strip(),
                    args.gateway_authentication_type.strip(),
                ),
                separators=(",", ":"),
            )
        )
        return 0
    except (ValueError, json.JSONDecodeError) as exc:
        print(f"image model selection failed: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
