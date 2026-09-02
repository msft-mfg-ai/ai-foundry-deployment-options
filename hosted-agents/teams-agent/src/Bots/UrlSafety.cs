using System.Net;
using System.Net.Sockets;

namespace AgentChat.Bots;

/// <summary>
/// Validates user-supplied URLs before the server fetches them.
/// Blocks SSRF surfaces: non-HTTPS, IMDS, loopback, link-local, private RFC1918 ranges.
/// </summary>
public static class UrlSafety
{
    public static bool TryValidatePublicHttpsUrl(string raw, out Uri uri, out string reason)
    {
        uri = null!;
        reason = "";

        if (!Uri.TryCreate(raw, UriKind.Absolute, out var parsed))
        {
            reason = "not a valid absolute URL.";
            return false;
        }

        // Allow only HTTPS — we don't want to leak data over plaintext.
        if (parsed.Scheme != Uri.UriSchemeHttps)
        {
            reason = "only `https://` URLs are allowed.";
            return false;
        }

        // Block IMDS explicitly (most common SSRF target on Azure).
        if (string.Equals(parsed.Host, "169.254.169.254", StringComparison.OrdinalIgnoreCase))
        {
            reason = "Azure metadata endpoint blocked.";
            return false;
        }

        // Block obviously private literal hosts.
        if (string.Equals(parsed.Host, "localhost", StringComparison.OrdinalIgnoreCase))
        {
            reason = "localhost is not allowed.";
            return false;
        }

        // If host is a literal IP, classify it. Hostnames will still resolve
        // to IPs at HttpClient time; the http handler itself is one more
        // safety net but ideally an egress firewall rule guards against this.
        if (IPAddress.TryParse(parsed.Host, out var ip) && IsPrivateOrReserved(ip))
        {
            reason = $"private/reserved IP {ip} not allowed.";
            return false;
        }

        uri = parsed;
        return true;
    }

    private static bool IsPrivateOrReserved(IPAddress ip)
    {
        if (IPAddress.IsLoopback(ip)) return true;

        if (ip.AddressFamily == AddressFamily.InterNetwork)
        {
            var b = ip.GetAddressBytes();
            // 10.0.0.0/8
            if (b[0] == 10) return true;
            // 172.16.0.0/12
            if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true;
            // 192.168.0.0/16
            if (b[0] == 192 && b[1] == 168) return true;
            // 169.254.0.0/16 (link-local + Azure IMDS adjacent)
            if (b[0] == 169 && b[1] == 254) return true;
            // 100.64.0.0/10 (CGNAT)
            if (b[0] == 100 && b[1] >= 64 && b[1] <= 127) return true;
            // 0.0.0.0/8
            if (b[0] == 0) return true;
        }
        else if (ip.AddressFamily == AddressFamily.InterNetworkV6)
        {
            // IPv6 link-local (fe80::/10) and unique-local (fc00::/7).
            if (ip.IsIPv6LinkLocal || ip.IsIPv6SiteLocal) return true;
            var b = ip.GetAddressBytes();
            if ((b[0] & 0xFE) == 0xFC) return true; // fc00::/7
            // IPv4-mapped → re-check the IPv4 piece.
            if (ip.IsIPv4MappedToIPv6 && IsPrivateOrReserved(ip.MapToIPv4())) return true;
        }
        return false;
    }
}
