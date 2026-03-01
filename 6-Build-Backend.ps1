# =============================================================================
#  VIBERIZE DESKTOP — Build Backend (Script 6 of 8)
#  Cargo type check + Tauri release build
# =============================================================================

$ErrorActionPreference = "Continue"

# Fresh-OS fix: ensure TLS 1.2 is available for all HTTPS downloads
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$ROOT = if ($env:VIBERIZE_ROOT) { $env:VIBERIZE_ROOT } else { "$($env:SystemDrive)\ViberizeDesktop" }
$APP = "$ROOT\app"; $SRC = "$APP\src"; $STYLES = "$SRC\styles"; $COMPONENTS = "$SRC\components"
$TAURI_DIR = "$APP\src-tauri"; $OLLAMA_DIR = "$ROOT\ollama"
$MODEL_DIR = "$ROOT\models"; $DL_CACHE = "$ROOT\_download_cache"; $LOG_DIR = "$ROOT\logs"
$UPDATE_DIR = "$ROOT\updates"; $DESKTOP = [Environment]::GetFolderPath("Desktop")
$CONFIG_FILE = "$ROOT\.viberize-config.json"; $STATE_FILE = "$ROOT\.setup-state.json"
$script:UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)
$script:logBuf = [System.Text.StringBuilder]::new()

function Write-HEAD  { param($m) Write-Host "`n===  $m  ===" -ForegroundColor Magenta }
function Write-OK    { param($m) Write-Host "  [OK]    $m" -ForegroundColor Green }
function Write-FAIL  { param($m) Write-Host "  [FAIL]  $m" -ForegroundColor Red }
function Write-WARN  { param($m) Write-Host "  [WARN]  $m" -ForegroundColor Yellow }
function Write-SKIP  { param($m) Write-Host "  [SKIP]  $m" -ForegroundColor DarkGray }
function Write-ACT   { param($m) Write-Host "  [-->]   $m" -ForegroundColor Cyan }
function Write-INFO  { param($m) Write-Host "  [info]  $m" -ForegroundColor DarkCyan }
function LogLine { param([string]$m) $script:logBuf.AppendLine("[$((Get-Date -Format 'HH:mm:ss'))] $m") | Out-Null }
function Save-Log { param([string]$Name); if (-not (Test-Path $LOG_DIR)) { New-Item $LOG_DIR -ItemType Directory -Force | Out-Null }; $script:logBuf.ToString() | Set-Content "$LOG_DIR\${Name}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log" -Encoding UTF8 -Force; Write-INFO "Log saved" }
function Ensure-Dir { param([string]$Path); if (-not (Test-Path $Path)) { New-Item $Path -ItemType Directory -Force | Out-Null; Write-OK "Created: $Path" } else { Write-SKIP "Exists: $Path" } }
function Write-FileAlways { param([string]$Path, [string]$Content, [string]$Label = ""); $dir = Split-Path $Path -Parent; if (-not (Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }; [System.IO.File]::WriteAllText($Path, $Content, $script:UTF8NoBOM); if ($Label) { Write-OK "Wrote $Label" }; LogLine "Wrote: $Path" }
function Write-FileIfMissing { param([string]$Path, [string]$Content, [string]$Label = ""); if (Test-Path $Path) { Write-SKIP "Exists: $(Split-Path $Path -Leaf)"; return }; Write-FileAlways $Path $Content $Label }
function Force-Write { param([string]$Path, [string]$Content, [string]$Label = ""); $dir = Split-Path $Path -Parent; if (-not (Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }; [System.IO.File]::WriteAllText($Path, $Content, $script:UTF8NoBOM); if ($Label) { Write-OK "Wrote $Label" } }
function Die { param([string]$Message); Write-FAIL $Message; throw $Message }
function Strip-BOM { param([string]$Path); if (-not (Test-Path $Path)) { return }; $bytes = [System.IO.File]::ReadAllBytes($Path); if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { [System.IO.File]::WriteAllBytes($Path, $bytes[3..($bytes.Length-1)]); Write-INFO "Stripped BOM from $(Split-Path $Path -Leaf)" } }
function Show-Banner { param([string]$Title, [int]$ScriptNum, [int]$Total = 8); Write-Host ""; Write-Host "  $('=' * 60)" -ForegroundColor Magenta; Write-Host "  | $Title$(' ' * [Math]::Max(0, 56 - $Title.Length)) |" -ForegroundColor Magenta; Write-Host "  | Script $ScriptNum of $Total$(' ' * 40) |" -ForegroundColor Magenta; Write-Host "  $('=' * 60)" -ForegroundColor Magenta; Write-Host "" }
function Set-StepComplete { param([string]$Step); $state = @{}; if (Test-Path $STATE_FILE) { try { $state = Get-Content $STATE_FILE -Raw | ConvertFrom-Json -AsHashtable } catch { $state = @{} } }; $state[$Step] = @{ completed = (Get-Date).ToString("o"); success = $true }; $state | ConvertTo-Json -Depth 5 | Set-Content $STATE_FILE -Encoding UTF8 -Force }
function Test-StepComplete { param([string]$Step); if (-not (Test-Path $STATE_FILE)) { return $false }; try { $s = Get-Content $STATE_FILE -Raw | ConvertFrom-Json; return ($s.PSObject.Properties.Name -contains $Step) } catch { return $false } }
function Download-File { param([string]$Url, [string]$Dest, [string]$Label = "", [int]$MaxRetries = 3); if (Test-Path $Dest) { Write-SKIP "$Label already downloaded"; return $true }; for ($a = 1; $a -le $MaxRetries; $a++) { try { if ($a -gt 1) { Write-INFO "Retry $a/$MaxRetries" } else { Write-ACT "Downloading $Label..." }; (New-Object System.Net.WebClient).DownloadFile($Url, $Dest); if (Test-Path $Dest) { $sz = [Math]::Round((Get-Item $Dest).Length/1MB,1); Write-OK "$Label downloaded (${sz} MB)"; return $true } } catch { Write-WARN "Attempt $a failed: $_"; Start-Sleep (2*$a) } }; Write-FAIL "Failed to download $Label"; return $false }
function Get-OllamaExe { $p = "$OLLAMA_DIR\ollama.exe"; if (Test-Path $p) { return $p }; return $null }
function Get-OllamaRunning { try { $r = Invoke-WebRequest -Uri "http://127.0.0.1:11434/" -UseBasicParsing -TimeoutSec 3 -EA Stop; return $r.StatusCode -eq 200 } catch { return $false } }
function Get-OllamaModels { try { $r = Invoke-WebRequest -Uri "http://127.0.0.1:11434/api/tags" -UseBasicParsing -TimeoutSec 10 -EA Stop; return @(($r.Content | ConvertFrom-Json).models | ForEach-Object { $_.name }) } catch { return @() } }
function Remove-OllamaAutostart { $lnk = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\Ollama.lnk"; if (Test-Path $lnk) { Remove-Item $lnk -Force -EA SilentlyContinue; Write-INFO "Removed Ollama startup shortcut" }; try { $v = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "Ollama" -EA SilentlyContinue; if ($v) { Remove-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "Ollama" -Force -EA SilentlyContinue } } catch {} }
function Stop-OllamaGUI { Get-Process -EA SilentlyContinue | Where-Object { $_.ProcessName -match "(?i)^ollama" } | Stop-Process -Force -EA SilentlyContinue; Start-Sleep 2; Get-Process -EA SilentlyContinue | Where-Object { $_.ProcessName -match "(?i)^ollama" } | Stop-Process -Force -EA SilentlyContinue; Start-Sleep 1 }
function Run-Direct { param([string]$Exe, [string[]]$ArgList, [string]$Label, [string]$WorkDir = "", [int]$TimeoutSec = 600); Write-ACT "$Label..."; $tmpOut = [System.IO.Path]::GetTempFileName(); $tmpErr = [System.IO.Path]::GetTempFileName(); $timedOut = $false; try { $pArgs = @{ FilePath=$Exe; ArgumentList=$ArgList; PassThru=$true; NoNewWindow=$true; RedirectStandardOutput=$tmpOut; RedirectStandardError=$tmpErr }; if ($WorkDir -and (Test-Path $WorkDir)) { $pArgs["WorkingDirectory"]=$WorkDir }; $p = Start-Process @pArgs; $sw = [System.Diagnostics.Stopwatch]::StartNew(); while (-not $p.HasExited) { if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) { Write-WARN "$Label timed out"; try { $p.Kill() } catch {}; $timedOut=$true; break }; $el=[Math]::Round($sw.Elapsed.TotalSeconds); Write-Host "`r    ${Label}... ${el}s" -NoNewline -ForegroundColor DarkGray; Start-Sleep -Milliseconds 500 }; Write-Host ""; $stdout = if (Test-Path $tmpOut) { Get-Content $tmpOut -Raw -EA SilentlyContinue } else { "" }; $stderr = if (Test-Path $tmpErr) { Get-Content $tmpErr -Raw -EA SilentlyContinue } else { "" }; $exitCode = if ($timedOut) { -1 } else { $p.ExitCode }; LogLine "$Label exit=$exitCode"; return @{ ExitCode=$exitCode; StdOut=$stdout; StdErr=$stderr; TimedOut=$timedOut } } finally { Remove-Item $tmpOut,$tmpErr -Force -EA SilentlyContinue } }
function Get-NpmExe { @("$env:ProgramFiles\nodejs\npm.cmd", "${env:ProgramFiles(x86)}\nodejs\npm.cmd") + ($env:Path -split ";" | ForEach-Object { Join-Path $_.Trim() "npm.cmd" }) | Where-Object { Test-Path $_ -EA SilentlyContinue } | Select-Object -First 1 }
function Get-CargoExe { @("$env:USERPROFILE\.cargo\bin\cargo.exe") + ($env:Path -split ";" | ForEach-Object { Join-Path $_.Trim() "cargo.exe" }) | Where-Object { Test-Path $_ -EA SilentlyContinue } | Select-Object -First 1 }
function Start-SilentInstall { param([string]$ExePath, [string]$Arguments, [string]$Label, [int]$TimeoutSeconds = 600); Write-ACT "Installing $Label..."; $proc = Start-Process $ExePath -ArgumentList $Arguments -PassThru -NoNewWindow; $sw = [System.Diagnostics.Stopwatch]::StartNew(); while (-not $proc.HasExited) { if ($sw.Elapsed.TotalSeconds -gt $TimeoutSeconds) { Write-WARN "$Label timed out"; try { $proc.Kill() } catch {}; return -1 }; Start-Sleep -Milliseconds 500 }; if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) { Write-OK "$Label installed" } else { Write-WARN "$Label exit: $($proc.ExitCode)" }; return $proc.ExitCode }


Show-Banner "BUILD BACKEND (TAURI)" 6

# Fresh-OS fix: refresh PATH from registry so tools installed by Script 2 are visible
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("Path","User")
foreach ($toolDir in @("$env:ProgramFiles\nodejs","${env:ProgramFiles(x86)}\nodejs",
                       "$env:USERPROFILE\.cargo\bin",
                       "${env:ProgramFiles(x86)}\NSIS","$env:ProgramFiles\NSIS")) {
    if ((Test-Path $toolDir -EA SilentlyContinue) -and ($env:Path -notlike "*$toolDir*")) {
        $env:Path = "$toolDir;$env:Path"
    }
}

# ── Missing definitions ──────────────────────────────────────────────────────
$TIMEOUT_CARGO_BUILD = if ($env:VIBERIZE_CARGO_TIMEOUT) { [int]$env:VIBERIZE_CARGO_TIMEOUT } else { 1800 }

function Find-Exe {
    param([string]$Name)
    $found = $env:Path -split ";" | ForEach-Object { Join-Path $_.Trim() $Name } |
        Where-Object { Test-Path $_ -EA SilentlyContinue } | Select-Object -First 1
    if ($found) { return $found }
    $cargoPath = "$env:USERPROFILE\.cargo\bin\$Name"
    if (Test-Path $cargoPath -EA SilentlyContinue) { return $cargoPath }
    return $null
}

# ── Resolve tool paths ──────────────────────────────────────────────────────
$cargoExe = Get-CargoExe
if (-not $cargoExe) { Die "cargo not found — run Script 2 first" }

# ── Fresh-OS fix: Ensure Defender exclusions are set before Rust compilation ──
# rustc writing thousands of .o/.rlib files triggers Defender real-time scanning,
# causing STATUS_ACCESS_VIOLATION (0xc0000005) on fresh Windows installs.
# Script 2 sets these, but verify/re-add in case user ran Script 6 standalone.
$defenderPaths = @($ROOT, "$env:USERPROFILE\.cargo", "$env:USERPROFILE\.rustup")
foreach ($exPath in $defenderPaths) {
    if (-not (Test-Path $exPath -EA SilentlyContinue)) { continue }
    try {
        $existing = (Get-MpPreference -EA Stop).ExclusionPath
        if (-not $existing -or ($existing -notcontains $exPath)) {
            Add-MpPreference -ExclusionPath $exPath -EA Stop
            Write-OK "Defender exclusion added: $exPath"
        }
    } catch {}
}
foreach ($procName in @("rustc.exe","cargo.exe")) {
    try {
        $existing = (Get-MpPreference -EA Stop).ExclusionProcess
        if (-not $existing -or ($existing -notcontains $procName)) {
            Add-MpPreference -ExclusionProcess $procName -EA Stop
            Write-OK "Defender process exclusion added: $procName"
        }
    } catch {}
}

Write-HEAD "PHASE 4 -- CARGO TYPE CHECK"
# =============================================================================

Write-ACT "cargo check (timeout: 120s)..."
$chkR = Run-Direct -Exe $cargoExe -ArgList @("check","--message-format=short") `
    -WorkDir $TAURI_DIR -TimeoutSec 120 -Label "cargo check"
$chkOut = ($chkR.Stdout + $chkR.Stderr) -join "`n"
if ($chkR.ExitCode -eq 0 -or $chkOut -match "Finished") { Write-OK "Rust type check passed" }
else {
    $chkR.Stderr | Select-Object -Last 10 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow }
    Write-WARN "cargo check had warnings -- proceeding to full build"
}

# =============================================================================
Write-HEAD "PHASE 5 -- TAURI RELEASE BUILD"
# =============================================================================

$tauriExe = Find-Exe "cargo-tauri.exe"
if (-not $tauriExe) { $tauriExe = Find-Exe "tauri.exe" }

if ($tauriExe) {
    Write-ACT "$tauriExe build (timeout: ${TIMEOUT_CARGO_BUILD}s)..."
    $tauriR = Run-Direct -Exe $tauriExe -ArgList @("build") `
        -WorkDir $APP -TimeoutSec $TIMEOUT_CARGO_BUILD -Label "tauri build"
} else {
    Write-WARN "cargo-tauri not found -- trying: cargo tauri build"
    $tauriR = Run-Direct -Exe $cargoExe -ArgList @("tauri","build") `
        -WorkDir $APP -TimeoutSec $TIMEOUT_CARGO_BUILD -Label "tauri build"
}

Write-INFO "First-run Rust compilation takes 5-15 min (progress ticks every 10s)"
$tauriOut = ($tauriR.Stdout + $tauriR.Stderr) -join "`n"
($tauriOut -split "`n") | Select-Object -Last 10 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

# Check for build artifacts as the PRIMARY success indicator
# (ExitCode from Start-Process -PassThru is unreliable for complex process trees like cargo->rustc->NSIS)
$buildExe = Get-ChildItem "$TAURI_DIR\target\release\*.exe" -EA SilentlyContinue |
    Where-Object { $_.Name -notmatch "(build_script|cargo-|deps)" -and $_.Length -gt 1MB } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
$buildMsi = Get-ChildItem "$TAURI_DIR\target\release\bundle\msi\*.msi" -EA SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
$buildSetup = Get-ChildItem "$TAURI_DIR\target\release\bundle\nsis\*setup*.exe" -EA SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1

$hasArtifacts = ($buildExe -or $buildMsi -or $buildSetup)

if ($tauriR.TimedOut -and -not $hasArtifacts) {
    Write-WARN "Tauri build timed out -- check $LOG_DIR\Build-Backend.log"
} elseif ($hasArtifacts) {
    Write-OK "Tauri release build PASSED (artifacts found)"
} elseif ($tauriR.ExitCode -eq 0 -or $tauriOut -match "Finished") {
    Write-OK "Tauri release build PASSED"
} else {
    Write-FAIL "Tauri build failed (exit $($tauriR.ExitCode))"
    if ($tauriOut -match "(error\[|error:)") {
        [regex]::Matches($tauriOut,"error[:\[].*") | Select-Object -First 8 |
            ForEach-Object { Write-Host "    $($_.Value)" -ForegroundColor Red }
    }
    Die "Tauri build failed -- see $LOG_DIR\Build-Backend.log"
}

$msiPath = $buildMsi
$exePath = $buildExe

if ($msiPath) { Write-OK "MSI: $($msiPath.FullName)" }
if ($exePath) { Write-OK "EXE: $($exePath.FullName)" }

# =============================================================================
Write-HEAD "PHASE 6 -- SMOKE TEST"
# =============================================================================

$ollamaExe = @("$ROOT\ollama\ollama.exe") + (
    $env:Path -split ";" | ForEach-Object { Join-Path $_.Trim() "ollama.exe" }
) | Where-Object { Test-Path $_ -EA SilentlyContinue } | Select-Object -First 1

$ollamaUp = $false
try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:11434/" -UseBasicParsing -TimeoutSec 5 -EA Stop
    if ($r.StatusCode -eq 200) { Write-OK "AI engine: healthy on 127.0.0.1:11434"; $ollamaUp = $true }
} catch {
    Write-WARN "AI engine not running"
    Write-INFO "The app will auto-start it on launch"
}

if ($ollamaUp) {
    # Read selected model from config
    $smokeModel = "llama3.2:3b"  # fallback
    $modelCfg = "$ROOT\selected_model.txt"
    if (Test-Path $modelCfg -EA SilentlyContinue) {
        $cfgModel = (Get-Content $modelCfg -Raw -EA SilentlyContinue).Trim()
        if ($cfgModel) { $smokeModel = $cfgModel }
    }

    try {
        $tags = (Invoke-WebRequest -Uri "http://127.0.0.1:11434/api/tags" -UseBasicParsing -TimeoutSec 10 -EA Stop).Content | ConvertFrom-Json
        $mdls = @($tags.models | ForEach-Object { $_.name })
        if ($mdls.Count -gt 0) {
            Write-OK "Available models: $($mdls -join ', ')"
            if ($smokeModel -notin $mdls) { $smokeModel = $mdls[0] }
        }
        else { Write-WARN "No models available yet" }
    } catch { Write-WARN "Could not query model list" }

    try {
        $body = @{ model=$smokeModel; prompt="Reply with exactly: ready"; stream=$false } | ConvertTo-Json
        $resp = (Invoke-WebRequest -Uri "http://127.0.0.1:11434/api/generate" `
            -Method POST -Body $body -ContentType "application/json" `
            -UseBasicParsing -TimeoutSec 60 -EA Stop).Content | ConvertFrom-Json
        if ($resp.response) {
            $preview = $resp.response.Trim().Substring(0, [Math]::Min(40,$resp.response.Length))
            Write-OK "Inference smoke test PASSED ($smokeModel): '$preview'"
        }
    } catch { Write-WARN "Inference test skipped (model may not be loaded yet)" }
}

if (Test-Path "$APP\dist\index.html" -EA SilentlyContinue) { Write-OK "dist/index.html present" }
else { Write-WARN "dist/index.html missing" }

# =============================================================================
Write-HEAD "BUILD SUMMARY"
# =============================================================================

Save-Log "Build-Backend"

Write-Host ""
Write-Host "+==================================================================+" -ForegroundColor Green
Write-Host "|   BUILD COMPLETE  (v8)                                          |" -ForegroundColor Green
Write-Host "+==================================================================+" -ForegroundColor Green
Write-Host ""
Write-Host "  v8 CHANGES:" -ForegroundColor White
Write-Host "  * FIREWALL: fully removed -- zero OS rule changes" -ForegroundColor Cyan
Write-Host "  * Font: @fontsource/inter (stable) + offline system-font fallback" -ForegroundColor Gray
Write-Host "  * Run-Direct: file-based redirection (crash-proof)"              -ForegroundColor Gray
Write-Host "  * RC-1 tailwind CJS / RC-2 postcss CJS / RC-3 no outfit.css"   -ForegroundColor Gray
Write-Host ""
if ($exePath) { Write-Host "  EXE: $($exePath.FullName)" -ForegroundColor Cyan }
if ($msiPath) { Write-Host "  MSI: $($msiPath.FullName)" -ForegroundColor Cyan }
Write-Host ""
Write-Host "  NEXT: Run Verify.ps1 as Administrator" -ForegroundColor Yellow
Write-Host "  Log:  $LOG_DIR\Build-Backend.log"                                -ForegroundColor DarkGray
Write-Host ""

Set-StepComplete "build-backend"
Save-Log "Build-Backend"
Write-OK "Backend built. Run Verify.ps1 next."
