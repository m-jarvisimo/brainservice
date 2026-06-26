# BrainService

BrainService is a small PowerShell utility for querying NetBrain TAF Lite output in two ways:

1. **Raw intent results** via `TAF/Lite/run` + `TAF/Lite/result` + `TAF/Lite/result/datas`
2. **ADT data** via `TAF/Lite/adt/data`

It reuses the same JSON config file for both scripts.

## Files

| File | Purpose |
|---|---|
| `Scripts/Invoke-BrainService-Raw.ps1` | Runs TAF Lite, waits for stable results, and writes raw intent evidence |
| `Scripts/Invoke-BrainService-AdtData.ps1` | Calls `TAF/Lite/adt/data` directly and returns the ADT dataset |
| `Config/brainservice.raw.config.json` | Runtime config file you edit locally |
| `Config/brainservice.raw.config.sample.json` | Sample config you can copy from |

## Configuration

Both scripts read the same config file by default:

```powershell
Config\brainservice.raw.config.json
```

### NetBrain settings

| Setting | Used by | Notes |
|---|---|---|
| `BaseUrl` | both | NetBrain base URL |
| `Username` / `Password` | both | Login credentials |
| `TenantId` / `DomainId` | both | Optional current-domain switch |
| `TafEndpoint` | both | ADT endpoint name/path passed to NetBrain |
| `TafPasskey` | both | Required for TAF Lite / ADT calls |
| `AdtColumns` | ADT script | Optional list of ADT columns to request |
| `IntentColumns` | raw script | Optional NI columns to execute |
| `MaxExecuteNIColumns` | raw script | Max NI columns NetBrain may execute in one run |
| `PollAttempts` | raw script | Poll limit |
| `PollSeconds` | raw script | Seconds between polls |
| `StablePolls` | raw script | Number of identical finished polls required before accepting the result |

## Running the raw intent viewer

```powershell
pwsh .\Scripts\Invoke-BrainService-Raw.ps1
```

Optional:

```powershell
pwsh .\Scripts\Invoke-BrainService-Raw.ps1 -ConfigPath .\Config\brainservice.raw.config.json -WriteJsonFile
```

## Running the ADT data reader

```powershell
pwsh .\Scripts\Invoke-BrainService-AdtData.ps1
```

Optional:

```powershell
pwsh .\Scripts\Invoke-BrainService-AdtData.ps1 -ConfigPath .\Config\brainservice.raw.config.json -WriteJsonFile
```

## Retrieving a custom variable

If your ADT has a custom variable/column such as `config_template`, add it to `AdtColumns`:

```json
"AdtColumns": ["config_template"]
```

If `AdtColumns` is empty, the ADT call asks NetBrain to return **all columns**.

## Output

If `WriteJsonFile` is enabled in the config, the scripts save JSON output under the configured output directory.

The ADT script writes files named like:

```text
brainservice-adt-YYYYMMDD-HHMMSS.json
```

The raw viewer writes files named like:

```text
brainservice-raw-YYYYMMDD-HHMMSS.json
```

## Notes

- The raw viewer uses `hasAlert` plus detailed status text to detect failures.
- The ADT script is the best place to look for custom ADT columns like `config_template`.
- Both scripts log out of NetBrain when finished.
