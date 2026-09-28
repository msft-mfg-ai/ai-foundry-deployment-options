import ipaddress
from pathlib import Path
import sys
import unittest


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from custom_dns import (
    CustomDnsError,
    find_free_subnet,
    flatten_azure_record_set,
    normalize_record,
)


class NetworkSelectionTests(unittest.TestCase):
    def test_finds_first_free_aci_subnet(self):
        vnet = [ipaddress.ip_network("10.0.0.0/16")]
        used = [ipaddress.ip_network("10.0.0.0/24")]

        self.assertEqual(
            find_free_subnet(vnet, used),
            ipaddress.ip_network("10.0.1.0/24"),
        )


class RecordTests(unittest.TestCase):
    def test_flattens_multi_value_azure_a_record_set(self):
        records = flatten_azure_record_set(
            "privatelink.services.ai.azure.com",
            {
                "type": "Microsoft.Network/privateDnsZones/A",
                "fqdn": "foundry.privatelink.services.ai.azure.com.",
                "ttl": 10,
                "aRecords": [
                    {"ipv4Address": "10.0.1.4"},
                    {"ipv4Address": "10.0.1.5"},
                ],
            },
        )

        self.assertTrue(records[0]["overwrite"])
        self.assertFalse(records[1]["overwrite"])
        self.assertEqual(records[1]["parameters"]["ipAddress"], "10.0.1.5")

    def test_normalizes_relative_a_record(self):
        self.assertEqual(
            normalize_record(
                {
                    "zone": "Example.COM.",
                    "name": "foundry",
                    "type": "a",
                    "value": "10.0.1.4",
                }
            ),
            {
                "zone": "example.com",
                "name": "foundry.example.com",
                "type": "A",
                "value": "10.0.1.4",
                "ttl": 300,
            },
        )

    def test_normalizes_relative_cname_target(self):
        record = normalize_record(
            {
                "zone": "example.com",
                "name": "alias",
                "type": "CNAME",
                "value": "foundry",
                "ttl": 60,
            }
        )

        self.assertEqual(record["value"], "foundry.example.com")

    def test_rejects_record_outside_zone(self):
        with self.assertRaises(CustomDnsError):
            normalize_record(
                {
                    "zone": "example.com",
                    "name": "host.other.example",
                    "type": "A",
                    "value": "10.0.1.4",
                }
            )


if __name__ == "__main__":
    unittest.main()
