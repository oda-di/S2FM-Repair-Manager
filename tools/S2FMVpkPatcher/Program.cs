using SteamDatabase.ValvePak;

if (args.Length != 4)
{
    Console.Error.WriteLine("Usage: S2FMVpkPatcher <input.vpk> <entry-path> <replacement-file> <output.vpk>");
    return 2;
}

var inputPath = Path.GetFullPath(args[0]);
var entryPath = args[1].Replace('\\', '/');
var replacementPath = Path.GetFullPath(args[2]);
var outputPath = Path.GetFullPath(args[3]);
if (inputPath.Equals(outputPath, StringComparison.OrdinalIgnoreCase))
{
    Console.Error.WriteLine("Input and output VPK paths must be different.");
    return 2;
}

var temporaryOutput = outputPath + ".tmp-" + Guid.NewGuid().ToString("N");
try
{
    var replacement = File.ReadAllBytes(replacementPath);
    Dictionary<string, EntryInfo> originalEntries;

    using (var package = new Package())
    {
        package.Read(inputPath);
        originalEntries = Snapshot(package);
        var target = package.FindEntry(entryPath)
            ?? throw new InvalidDataException($"VPK entry not found: {entryPath}");
        if (!package.RemoveFile(target))
            throw new InvalidDataException($"Could not remove VPK entry: {entryPath}");
        package.AddFile(entryPath, replacement);
        package.Write(temporaryOutput);
    }

    using (var verification = new Package())
    {
        verification.Read(temporaryOutput);
        var outputEntries = Snapshot(verification);
        if (outputEntries.Count != originalEntries.Count)
            throw new InvalidDataException("VPK entry count changed unexpectedly.");

        foreach (var (path, original) in originalEntries)
        {
            if (!outputEntries.TryGetValue(path, out var current))
                throw new InvalidDataException($"VPK entry disappeared: {path}");
            if (!path.Equals(entryPath, StringComparison.OrdinalIgnoreCase) && current != original)
                throw new InvalidDataException($"Unrelated VPK entry changed: {path}");
        }

        var patched = verification.FindEntry(entryPath)
            ?? throw new InvalidDataException("Patched VPK entry is missing.");
        verification.ReadEntry(patched, out var patchedBytes, validateCrc: true);
        if (!patchedBytes.AsSpan().SequenceEqual(replacement))
            throw new InvalidDataException("Patched VPK entry does not match the replacement bytes.");
        verification.VerifyFileChecksums();
    }

    Directory.CreateDirectory(Path.GetDirectoryName(outputPath)!);
    File.Move(temporaryOutput, outputPath, overwrite: true);
    Console.WriteLine($"Patched VPK entry: {entryPath}");
    return 0;
}
catch (Exception exception)
{
    Console.Error.WriteLine(exception.Message);
    return 1;
}
finally
{
    if (File.Exists(temporaryOutput)) File.Delete(temporaryOutput);
}

static Dictionary<string, EntryInfo> Snapshot(Package package)
{
    var entries = new Dictionary<string, EntryInfo>(StringComparer.OrdinalIgnoreCase);
    var packageEntries = package.Entries ?? throw new InvalidDataException("VPK contains no entry tree.");
    foreach (var group in packageEntries)
    {
        if (group.Value is null) continue;
        foreach (var entry in group.Value)
        {
            if (entry is null) continue;
            var path = entry.GetFullPath();
            if (!entries.TryAdd(path, new EntryInfo(entry.CRC32, entry.TotalLength)))
                throw new InvalidDataException($"Duplicate VPK entry: {path}");
        }
    }
    return entries;
}

readonly record struct EntryInfo(uint Crc32, uint Length);
