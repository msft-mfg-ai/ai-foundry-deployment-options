import ipaddress
import sys
from pathlib import Path
import unittest


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from vpn import find_free_subnet, find_tunnel_network, wireguard_profile_name


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

    def test_profile_name_follows_vnet_resource_group(self):
        self.assertEqual(
            wireguard_profile_name("rg-foundry (private)"),
            "rg-foundry--private-",
        )


if __name__ == "__main__":
    unittest.main()
