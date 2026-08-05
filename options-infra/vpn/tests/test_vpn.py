import ipaddress
import sys
from pathlib import Path
import unittest


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from vpn import find_free_subnet, find_priority_base, find_tunnel_network


class NetworkSelectionTests(unittest.TestCase):
    def test_finds_first_free_vpn_subnet(self):
        vnet = [ipaddress.ip_network("10.0.0.0/24")]
        used = [ipaddress.ip_network("10.0.0.0/27")]

        self.assertEqual(
            find_free_subnet(vnet, used),
            ipaddress.ip_network("10.0.0.32/27"),
        )

    def test_skips_overlapping_tunnel_network(self):
        blocked = [ipaddress.ip_network("10.99.0.0/23")]

        self.assertEqual(
            find_tunnel_network(blocked),
            ipaddress.ip_network("10.99.2.0/24"),
        )

    def test_priority_selection_ignores_managed_rule_names(self):
        rules = [
            {"name": "AllowNestedInbound", "direction": "Inbound", "priority": 2000},
            {"name": "ExistingInbound", "direction": "Inbound", "priority": 2010},
            {"name": "ExistingOutbound", "direction": "Outbound", "priority": 2020},
        ]

        self.assertEqual(find_priority_base(rules), 2020)


if __name__ == "__main__":
    unittest.main()
