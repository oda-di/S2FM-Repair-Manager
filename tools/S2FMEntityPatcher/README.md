# S2FMEntityPatcher

This small helper patches a compiled Source 2 entity lump without rebuilding the
map. It normalizes supported `light_environment.directlight` values (`1`, `2`, or
`3`) to the requested runtime mode (`3` for stationary or `2` for fully dynamic),
then reads the output back for verification. Fully dynamic mode is used for maps
containing a `skybox_reference`, so the main world and 3D skybox receive the same
sun path.

The release executable is published from this source with .NET 10 and
[ValveResourceFormat 20.0.6980](https://github.com/ValveResourceFormat/ValveResourceFormat),
which is MIT-licensed. Rebuild it with:

```powershell
dotnet publish .\S2FMEntityPatcher.csproj -c Release -r win-x64 --self-contained true `
  -p:PublishTrimmed=true -p:TrimMode=link -p:IncludeNativeLibrariesForSelfExtract=true `
  -p:EnableCompressionInSingleFile=true -o .\bin\Release\publish-win-x64
```
