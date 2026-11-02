# Building S2FM Repair Manager from source

This repository contains the complete project-owned source for S2FM Repair
Manager 1.2.2, the two helper tools, PowerShell installers, and the DMX session
template. Generated executables, portable .NET runtimes, release archives, and
third-party binaries are intentionally excluded from Git.

## Requirements

- Windows 10/11 x64;
- .NET 10 SDK;
- Windows PowerShell 5.1 or PowerShell 7;
- ValveResourceFormat / Source2Viewer CLI 20.1;
- an LGPL shared Windows x64 build of FFmpeg.

Place the ValveResourceFormat 20.1 release files here:

```text
third_party/ValveResourceFormat/Source2Viewer-CLI.exe
third_party/ValveResourceFormat/libSkiaSharp.dll
third_party/ValveResourceFormat/spirv-cross.dll
third_party/ValveResourceFormat/LICENSE.txt
```

Place an extracted BtbN `ffmpeg-master-latest-win64-lgpl-shared` package anywhere
under `third_party/ffmpeg`. `Build-S2FMRelease.ps1` locates `ffmpeg.exe` recursively.

The dependency locations can also be passed explicitly:

```powershell
.\Build-S2FMRelease.ps1 -Version 1.2.2 `
  -ValveResourceFormatRoot "D:\deps\ValveResourceFormat" `
  -FfmpegRoot "D:\deps\ffmpeg"
```

The script builds the WinForms manager and both C# helper tools from source,
assembles the portable release, generates per-file checksums, and creates a ZIP
plus its SHA-256 sidecar under `release`.

## Source-only checks

These commands do not require the standalone third-party binaries:

```powershell
dotnet build .\app\S2FMRepairManager\S2FMRepairManager.csproj -c Release
dotnet build .\tools\S2FMEntityPatcher\S2FMEntityPatcher.csproj -c Release
dotnet build .\tools\S2FMVpkPatcher\S2FMVpkPatcher.csproj -c Release
```

To create the same source bundle intended for GitHub:

```powershell
.\Build-S2FMSourceArchive.ps1 -Version 1.2.2
```

## Dependency provenance

The binary release was validated with ValveResourceFormat 20.1 and FFmpeg
N-128142-g28fda48e0b-20261028. See `THIRD_PARTY_NOTICES.txt` for upstream links,
licenses, and the FFmpeg source revision. Third-party license texts must remain
in binary distributions.

The project itself currently has no repository license file. Choose and add the
intended project license before making a public GitHub repository if you want to
grant redistribution or modification rights.
