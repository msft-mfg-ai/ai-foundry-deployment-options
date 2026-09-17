import importlib.util
import pathlib
import sys
import unittest


SCRIPT = pathlib.Path(__file__).parents[1] / "select-image-model.py"
SPEC = importlib.util.spec_from_file_location("select_image_model", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class SelectImageModelTests(unittest.TestCase):
    def test_selects_supported_model_deterministically(self):
        result = MODULE.select(
            [
                {
                    "name": "west",
                    "endpoint": "https://west.cognitiveservices.azure.com/",
                    "deployments": [
                        {"modelName": "text-image-embedding"},
                        {
                            "modelName": "creative-mai",
                            "modelCatalogName": "MAI-Image-2.5",
                        },
                        {"modelName": "gpt-image-1"},
                    ],
                }
            ]
        )
        self.assertTrue(result["enabled"])
        self.assertEqual("gpt-image-1", result["selected"]["model"])
        self.assertEqual("openai-v1-gpt-image", result["selected"]["profile"])
        self.assertEqual(
            "openai-v1/images/generations", result["selected"]["path"]
        )
        self.assertEqual(
            "2025-04-01-preview", result["selected"]["apiVersion"]
        )
        self.assertEqual(
            "https://west.openai.azure.com/",
            result["selected"]["apiEndpoint"],
        )
        self.assertEqual(
            "openai-v1-gpt-image",
            result["instances"][0]["deployments"][2]["apiProfile"],
        )
        self.assertEqual(
            "https://west.services.ai.azure.com/",
            result["instances"][0]["deployments"][1]["apiEndpoint"],
        )

    def test_explicit_override_is_case_insensitive(self):
        result = MODULE.select(
            [
                {
                    "name": "east",
                    "endpoint": "https://east.cognitiveservices.azure.com/",
                    "deployments": [
                        {"modelName": "gpt-image-1"},
                        {
                            "modelName": "mai-prod",
                            "modelCatalogName": "MAI-Image-2.6-Flash",
                        },
                    ],
                }
            ],
            "mai-prod",
        )
        self.assertEqual("mai-prod", result["selected"]["model"])
        self.assertEqual("MAI-Image-2.6-Flash", result["selected"]["catalogModel"])
        self.assertEqual("mai-v1-image", result["selected"]["profile"])
        self.assertEqual("mai-v1/images/generations", result["selected"]["path"])
        self.assertEqual(
            "https://east.services.ai.azure.com/",
            result["selected"]["apiEndpoint"],
        )
        self.assertEqual(
            "mai-v1-image",
            result["instances"][0]["deployments"][1]["apiProfile"],
        )

    def test_no_compatible_model_disables_feature(self):
        result = MODULE.select(
            [
                {
                    "name": "east",
                    "endpoint": "https://east.cognitiveservices.azure.com/",
                    "deployments": [{"modelName": "gpt-5.4"}],
                }
            ]
        )
        self.assertFalse(result["enabled"])
        self.assertIsNone(result["selected"])
        self.assertEqual([], result["compatibleModels"])

    def test_rejects_incompatible_override(self):
        with self.assertRaisesRegex(ValueError, "not a discovered compatible"):
            MODULE.select(
                [
                    {
                        "name": "east",
                        "endpoint": "https://east.cognitiveservices.azure.com/",
                        "deployments": [{"modelName": "gpt-5.4"}],
                    }
                ],
                "gpt-5.4",
            )

    def test_api_key_gateway_disables_selection_and_route_annotation(self):
        result = MODULE.select(
            [
                {
                    "name": "east",
                    "endpoint": "https://east.cognitiveservices.azure.com/",
                    "deployments": [
                        {
                            "modelName": "image-prod",
                            "modelCatalogName": "gpt-image-1",
                        }
                    ],
                }
            ],
            "image-prod",
            "ApiKey",
        )

        self.assertFalse(result["enabled"])
        self.assertEqual(
            "gateway authentication mode is not ProjectManagedIdentity",
            result["disabledReason"],
        )
        self.assertNotIn(
            "apiProfile",
            result["instances"][0]["deployments"][0],
        )

    def test_explicit_profile_endpoints_support_nonstandard_cloud_hosts(self):
        result = MODULE.select(
            [
                {
                    "name": "sovereign",
                    "endpoint": "https://unused.invalid/",
                    "openAiEndpoint": "https://image.openai.example/",
                    "aiServicesEndpoint": "https://image.services.ai.example/",
                    "deployments": [
                        {
                            "modelName": "gpt-image",
                            "modelCatalogName": "gpt-image-2",
                        },
                        {
                            "modelName": "mai-image",
                            "modelCatalogName": "MAI-Image-2.6",
                        },
                    ],
                }
            ],
            "mai-image",
        )

        self.assertEqual(
            "https://image.services.ai.example/",
            result["selected"]["apiEndpoint"],
        )

    def test_chained_apim_image_is_excluded_from_direct_profile_routing(self):
        result = MODULE.select(
            [
                {
                    "name": "downstream",
                    "endpoint": "https://gateway.example/",
                    "isApim": True,
                    "deployments": [
                        {
                            "modelName": "image-prod",
                            "modelCatalogName": "gpt-image-2",
                        }
                    ],
                }
            ]
        )

        self.assertFalse(result["enabled"])
        self.assertEqual(["image-prod"], result["compatibleModels"])
        self.assertNotIn(
            "apiProfile",
            result["instances"][0]["deployments"][0],
        )


if __name__ == "__main__":
    unittest.main()
