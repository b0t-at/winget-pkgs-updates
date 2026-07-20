using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace WingetMaintainer.Core.Manifests;

/// <summary>Result of hashing a manifest directory.</summary>
public sealed record ManifestHashResult(string ManifestHash, IReadOnlyList<string> InstallerHashes);

/// <summary>
/// Computes a stable fingerprint of a winget manifest directory and extracts installer hashes.
/// Ported from <c>Get-ManifestHash.ps1</c>: sort <c>*.yaml</c> by name, concatenate raw contents,
/// SHA-256 the UTF-8 bytes (hex, uppercase), and collect distinct <c>InstallerSha256</c> values.
/// </summary>
public static partial class ManifestHasher
{
    [GeneratedRegex(
        @"InstallerSha256\s*:\s*([A-Fa-f0-9]{64})",
        RegexOptions.None,
        matchTimeoutMilliseconds: 2000
    )]
    private static partial Regex InstallerSha256Regex();

    public static ManifestHashResult ComputeFromDirectory(string manifestPath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(manifestPath);

        if (!Directory.Exists(manifestPath))
        {
            throw new DirectoryNotFoundException($"Manifest path not found: {manifestPath}");
        }

        List<string> files = Directory
            .GetFiles(manifestPath, "*.yaml", SearchOption.TopDirectoryOnly)
            .OrderBy(Path.GetFileName, StringComparer.OrdinalIgnoreCase)
            .ToList();

        if (files.Count == 0)
        {
            throw new InvalidOperationException(
                $"No YAML files found in manifest path: {manifestPath}"
            );
        }

        StringBuilder combined = new();
        List<string> installerHashes = [];

        foreach (string file in files)
        {
            string content = File.ReadAllText(file);
            combined.Append(content);

            foreach (Match match in InstallerSha256Regex().Matches(content))
            {
                string hash = match.Groups[1].Value.ToUpperInvariant();
                if (!installerHashes.Contains(hash))
                {
                    installerHashes.Add(hash);
                }
            }
        }

        byte[] hashBytes = SHA256.HashData(Encoding.UTF8.GetBytes(combined.ToString()));
        string manifestHash = Convert.ToHexString(hashBytes);

        return new ManifestHashResult(manifestHash, installerHashes);
    }
}
