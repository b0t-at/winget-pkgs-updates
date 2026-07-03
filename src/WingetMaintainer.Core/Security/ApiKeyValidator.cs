using System.Security.Cryptography;
using System.Text;

namespace WingetMaintainer.Core.Security;

/// <summary>Constant-time API-key comparison for the Worker's internal API (decision D15/D-AUTH).</summary>
public static class ApiKeyValidator
{
    /// <summary>
    /// Returns true only when a non-empty expected key is configured and the provided key matches it.
    /// A missing configured key denies all access (fail closed).
    /// </summary>
    public static bool IsAuthorized(string? providedKey, string? expectedKey)
    {
        if (string.IsNullOrEmpty(expectedKey) || string.IsNullOrEmpty(providedKey))
        {
            return false;
        }

        return CryptographicOperations.FixedTimeEquals(
            Encoding.UTF8.GetBytes(providedKey),
            Encoding.UTF8.GetBytes(expectedKey));
    }
}
