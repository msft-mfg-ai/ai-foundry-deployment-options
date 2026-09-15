import importlib.util
import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).parents[3]
OPTION = ROOT / "options-infra" / "foundry-teams-hosted"
SCRIPTS = ROOT / "options-infra" / "scripts"
SELECTOR_SPEC = importlib.util.spec_from_file_location(
    "teams_image_selector",
    SCRIPTS / "select-image-model.py",
)
SELECTOR = importlib.util.module_from_spec(SELECTOR_SPEC)
assert SELECTOR_SPEC.loader
sys.modules[SELECTOR_SPEC.name] = SELECTOR
SELECTOR_SPEC.loader.exec_module(SELECTOR)


class TeamsImageConfigurationTests(unittest.TestCase):
    def test_azure_yaml_wires_conditional_image_configuration_and_skill(self):
        yaml = (OPTION / "azure.yaml").read_text(encoding="utf-8")

        self.assertIn(
            "value: ${APIM_GATEWAY_URL}/${IMAGE_MODEL_PATH}",
            yaml,
        )
        self.assertIn("value: ${IMAGE_MODEL_RESOLVED}", yaml)
        self.assertIn("value: ${IMAGE_MODEL_PROFILE}", yaml)
        self.assertIn(
            "value: ${GATEWAY_AUTHENTICATION_TYPE}",
            yaml,
        )
        self.assertIn("- name: image-generation", yaml)
        self.assertIn(
            "../../hosted-agents/teams-agent/skills/image-generation",
            yaml,
        )

    def test_posix_and_powershell_persist_the_same_image_settings(self):
        posix = (
            SCRIPTS / "preprovision-list-foundry-models.sh"
        ).read_text(encoding="utf-8")
        powershell = (
            SCRIPTS / "preprovision-list-foundry-models.ps1"
        ).read_text(encoding="utf-8")

        for name in (
            "IMAGE_MODEL_RESOLVED",
            "IMAGE_MODEL_PROFILE",
            "IMAGE_MODEL_PATH",
            "IMAGE_MODEL_API_VERSION",
            "IMAGE_MODEL_DISCOVERY_JSON",
            "FOUNDRY_INSTANCES_JSON",
            "GATEWAY_AUTHENTICATION_TYPE",
        ):
            self.assertIn(f"azd env set {name}", posix)
            self.assertIn(f"Set-AzdEnv {name}", powershell)

    def test_gateway_keeps_gpt_and_mai_routes_distinct(self):
        setup = (
            ROOT / "options-infra" / "modules" / "apim" / "common-apim-setup.bicep"
        ).read_text(encoding="utf-8")
        backends = (
            ROOT
            / "options-infra"
            / "modules"
            / "apim"
            / "advanced"
            / "multi-foundry-backends.bicep"
        ).read_text(encoding="utf-8")
        policy = (
            ROOT / "options-infra" / "modules" / "apim" / "policy-per-model.xml"
        ).read_text(encoding="utf-8")

        self.assertIn("apiPath: 'openai-v1'", setup)
        self.assertIn("apiPath: 'mai-v1'", setup)
        self.assertIn(
            "gatewayAuthenticationType == 'ProjectManagedIdentity'",
            setup,
        )
        self.assertIn("dep.apiProfile == 'mai-v1-image'", backends)
        self.assertIn("endpoint: dep.?apiEndpoint ?? instance.endpoint", backends)
        self.assertLess(
            backends.index("url: dep.isApim"),
            backends.index("dep.apiProfile == 'mai-v1-image'"),
        )
        self.assertIn("/openai-v1/", policy)
        self.assertIn("/mai-v1/", policy)
        self.assertIn(
            '<rewrite-uri template="@(&quot;/mai/v1&quot; + context.Request.Url.Path)" />',
            policy,
        )
        self.assertIn(
            '&quot;/deployments/&quot; + System.Uri.EscapeDataString((string)context.Variables[&quot;requestedModel&quot;]) + &quot;/images/generations&quot;',
            policy,
        )
        self.assertIn(
            '<set-query-parameter name="api-version" exists-action="override">',
            policy,
        )
        self.assertIn("<value>2025-04-01-preview</value>", policy)

    def test_effective_direct_image_backend_urls_and_paths(self):
        gpt = SELECTOR.select(
            [
                {
                    "name": "foundry-with-models",
                    "endpoint": "https://foundry-with-models.cognitiveservices.azure.com/",
                    "deployments": [
                        {
                            "modelName": "gptimage2",
                            "modelCatalogName": "gpt-image-2",
                        }
                    ],
                }
            ]
        )["selected"]
        mai = SELECTOR.select(
            [
                {
                    "name": "foundry-west-us-pka",
                    "endpoint": "https://foundry-west-us-pka.cognitiveservices.azure.com/",
                    "deployments": [
                        {
                            "modelName": "mai-image",
                            "modelCatalogName": "MAI-Image-2.6",
                        }
                    ],
                }
            ]
        )["selected"]

        self.assertEqual(
            "https://foundry-with-models.openai.azure.com/openai"
            "/deployments/gptimage2/images/generations"
            "?api-version=2025-04-01-preview",
            f'{gpt["apiEndpoint"]}openai/deployments/{gpt["model"]}'
            f'/images/generations?api-version={gpt["apiVersion"]}',
        )
        self.assertEqual(
            "https://foundry-west-us-pka.services.ai.azure.com/"
            "mai/v1/images/generations",
            f'{mai["apiEndpoint"]}mai/v1/images/generations',
        )


if __name__ == "__main__":
    unittest.main()
