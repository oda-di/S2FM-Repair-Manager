using ValveKeyValue;
using ValveResourceFormat;
using ValveResourceFormat.ResourceTypes;

if (args.Length is < 2 or > 3 || (args.Length == 3 && args[2] is not ("2" or "3")))
{
    Console.Error.WriteLine("Usage: S2FMEntityPatcher <input.vents_c> <output.vents_c> [2|3]");
    return 2;
}

var inputPath = Path.GetFullPath(args[0]);
var outputPath = Path.GetFullPath(args[1]);
var targetMode = args.Length == 3 ? args[2] : "3";
if (inputPath.Equals(outputPath, StringComparison.OrdinalIgnoreCase))
{
    Console.Error.WriteLine("Input and output paths must be different.");
    return 2;
}

var temporaryOutput = outputPath + ".tmp-" + Guid.NewGuid().ToString("N");
try
{
    var patchResult = PatchEnvironmentLights(inputPath, temporaryOutput, targetMode);
    if (patchResult.MatchedCount == 0)
    {
        Console.Error.WriteLine("No light_environment entity with a directlight mode was found.");
        return 3;
    }

    VerifyOutput(temporaryOutput, patchResult.MatchedCount, targetMode);
    Directory.CreateDirectory(Path.GetDirectoryName(outputPath)!);
    File.Move(temporaryOutput, outputPath, overwrite: true);
    Console.WriteLine($"Normalized {patchResult.MatchedCount} light_environment entity(s) to directlight {targetMode} ({patchResult.ChangedCount} changed).");
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

static PatchResult PatchEnvironmentLights(string inputPath, string outputPath, string targetMode)
{
    using var resource = new Resource();
    resource.Read(inputPath);
    if (resource.DataBlock is not EntityLump lump)
        throw new InvalidDataException("Input is not a Source 2 entity lump.");

    var matchedCount = 0;
    var changedCount = 0;
    foreach (var record in lump.Data["m_entityKeyValues"].Values)
    {
        if (!record.ContainsKey("keyValues3Data")) continue;

        var values = record["keyValues3Data"]["values"];
        if (!values.ContainsKey("classname") ||
            values["classname"].ToString() != "light_environment" ||
            !values.ContainsKey("directlight")) continue;

        var mode = values["directlight"].ToString();
        matchedCount++;
        if (mode == targetMode) continue;
        if (mode is not ("1" or "2" or "3"))
            throw new InvalidDataException($"Unexpected light_environment directlight mode '{mode}'.");

        values["directlight"] = new KVObject(targetMode);
        changedCount++;
    }

    using var output = File.Create(outputPath);
    resource.Serialize(output);
    return new PatchResult(matchedCount, changedCount);
}

static void VerifyOutput(string outputPath, int expectedCount, string targetMode)
{
    using var resource = new Resource();
    resource.Read(outputPath);
    if (resource.DataBlock is not EntityLump lump)
        throw new InvalidDataException("Serialized output is not an entity lump.");

    var patchedCount = lump.Data["m_entityKeyValues"].Values.Count(record =>
        record.ContainsKey("keyValues3Data") &&
        record["keyValues3Data"]["values"].TryGetValue("classname", out var classname) &&
        classname.ToString() == "light_environment" &&
        record["keyValues3Data"]["values"].TryGetValue("directlight", out var directlight) &&
        directlight.ToString() == targetMode);
    if (patchedCount != expectedCount)
        throw new InvalidDataException("Serialized output failed verification.");
}

readonly record struct PatchResult(int MatchedCount, int ChangedCount);
