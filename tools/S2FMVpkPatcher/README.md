# S2FMVpkPatcher

Replaces exactly one entry in an addon copy of a Source 2 map VPK. The tool
verifies that the entry count and every unrelated entry's CRC/length are
unchanged, reads the replacement back, and validates all file CRCs.

Built with the MIT-licensed [ValvePak](https://github.com/ValveResourceFormat/ValvePak)
library.

Rebuild it with:

```powershell
dotnet publish .\S2FMVpkPatcher.csproj -c Release -r win-x64 --self-contained true `
  -p:PublishSingleFile=true -p:PublishTrimmed=true -p:TrimMode=link `
  -p:IncludeNativeLibrariesForSelfExtract=true `
  -p:EnableCompressionInSingleFile=true -o .\bin\Release\publish-win-x64
```
