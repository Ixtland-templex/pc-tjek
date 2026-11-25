# Opticon (Windows-program)

Den nye udgave af Opticon som et almindeligt Windows-program skrevet i C# (.NET 8, WPF).
Ingen PowerShell, og den installeres med en normal installer.

- Bygges automatisk af GitHub Actions (`.github/workflows/opticon-app.yml`) for både almindelige pc'er (x64) og Snapdragon/ARM (arm64).
- Installeren findes under **Actions → seneste kørsel → Artifacts**.
- Ny udgivelse: sæt versionen i `Opticon.csproj` og lav et tag `app-vX.Y.Z`. Så kommer installerne på siden **Releases**.
