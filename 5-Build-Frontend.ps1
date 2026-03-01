# =============================================================================
#  VIBERIZE DESKTOP — Build Frontend (Script 5 of 8)
#  TypeScript check + Vite production build
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
function Test-FontInstalled { return (Test-Path "$APP\node_modules\@fontsource\inter" -EA SilentlyContinue) -or (Test-Path "$APP\node_modules\@fontsource-variable\inter" -EA SilentlyContinue) }


Show-Banner "BUILD FRONTEND" 5

# Fresh-OS fix: refresh PATH from registry so tools installed by Script 2 are visible
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("Path","User")
foreach ($toolDir in @("$env:ProgramFiles\nodejs","${env:ProgramFiles(x86)}\nodejs","$env:USERPROFILE\.cargo\bin")) {
    if ((Test-Path $toolDir -EA SilentlyContinue) -and ($env:Path -notlike "*$toolDir*")) {
        $env:Path = "$toolDir;$env:Path"
    }
}

# ── Resolve tool paths ──────────────────────────────────────────────────────
$npmExe = Get-NpmExe
if (-not $npmExe) { Die "npm not found — run Script 2 first" }

Write-HEAD "PHASE 1 -- ENVIRONMENT SETUP"
# =============================================================================

$env:OLLAMA_HOST     = "127.0.0.1:11434"
$env:OLLAMA_ORIGINS  = "tauri://localhost"
Write-OK "OLLAMA_HOST:     $env:OLLAMA_HOST (loopback only)"

# =============================================================================
Write-HEAD "PHASE 2 -- TYPESCRIPT TYPE CHECK"
# =============================================================================

if (-not $tscExe -or -not (Test-Path $tscExe -EA SilentlyContinue)) {
    $tscExe = "$APP\node_modules\.bin\tsc.cmd"
}

if (Test-Path $tscExe -EA SilentlyContinue) {
    Write-ACT "tsc --noEmit (timeout: 30s)..."
    $tscR = Run-Direct -Exe $tscExe -ArgList @("--noEmit") -WorkDir $APP -TimeoutSec 30 -Label "tsc"
    if ($tscR.TimedOut)         { Write-WARN "tsc timed out -- proceeding" }
    elseif ($tscR.ExitCode -eq 0) { Write-OK "TypeScript: no errors" }
    else {
        $tsOut = ($tscR.Stdout + $tscR.Stderr) -join "`n"
        if ($tsOut -match "error TS") {
            Write-WARN "TypeScript errors (build will confirm if blocking):"
            ($tscR.Stdout + $tscR.Stderr) | Where-Object { $_ -match "error TS" } |
                Select-Object -First 8 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow }
        }
    }
} else { Write-WARN "tsc not found -- TypeScript check skipped" }

# =============================================================================
Write-HEAD "PHASE 3 -- FRONTEND BUILD (Vite + Tailwind + Inter)"
# =============================================================================

$TIMEOUT_VITE_BUILD = if ($env:VIBERIZE_VITE_TIMEOUT) { [int]$env:VIBERIZE_VITE_TIMEOUT } else { 120 }

if (Test-FontInstalled) { Write-INFO "Font: @fontsource/inter (npm package)" }
else                     { Write-INFO "Font: system-font CSS fallback (offline mode)" }

Write-ACT "npm run build (timeout: ${TIMEOUT_VITE_BUILD}s)..."

$buildR = Run-Direct -Exe $npmExe -ArgList @("run","build") -WorkDir $APP `
    -TimeoutSec $TIMEOUT_VITE_BUILD -Label "npm run build"

$allOut = $buildR.Stdout + $buildR.Stderr
$allOut | Select-Object -Last 30 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

if ($buildR.TimedOut) { Die "Frontend build timed out after ${TIMEOUT_VITE_BUILD}s" }

# v8 FIX: dist/index.html is the PRIMARY success indicator.
# Node 24 + Vite 5.4 CJS deprecation warning can cause non-zero exit code
# even when the build succeeds ("The CJS build of Vite's Node API is deprecated").
# ExitCode and error-string checks are secondary — only fail if dist is missing.
$outStr = $allOut -join "`n"
$distExists = Test-Path "$APP\dist\index.html" -EA SilentlyContinue

$failed = $false
if (-not $distExists) {
    # dist missing — build genuinely failed
    $failed = $true
    LogLine "FAIL: dist/index.html not found after build"
} elseif ($buildR.ExitCode -ne 0) {
    # dist exists but exit code non-zero — check if it's just the CJS deprecation warning
    if ($outStr -match "CJS build of Vite.*deprecated") {
        Write-WARN "Vite CJS deprecation warning (exit code $($buildR.ExitCode)) -- build output OK, continuing"
        LogLine "WARN: Vite CJS deprecation (non-zero exit) but dist/index.html present"
    } elseif ($outStr -match "(SyntaxError|Cannot find module|ENOENT|Build failed)") {
        # Genuine error signatures in output despite dist existing (partial/corrupt build)
        $failed = $true
        LogLine "FAIL: Error signatures found in build output"
    } else {
        Write-WARN "npm run build exited $($buildR.ExitCode) but dist/index.html present -- continuing"
        LogLine "WARN: non-zero exit ($($buildR.ExitCode)) but dist present"
    }
}

if ($failed) {
    Write-FAIL "Frontend build FAILED"
    Write-Host ""
    Write-Host "  DIAGNOSIS:" -ForegroundColor Yellow
    if ($outStr -match "PostCSS")           { Write-Host "  - PostCSS error: check postcss.config.cjs and vite.config.ts css.postcss" -ForegroundColor Red }
    if ($outStr -match "tailwind")          { Write-Host "  - Tailwind: check tailwind.config.cjs" -ForegroundColor Red }
    if ($outStr -match "fontsource|outfit") { Write-Host "  - Font: @fontsource import in main.tsx but package missing -- re-run this script" -ForegroundColor Red }
    if ($outStr -match "Cannot find module") {
        $mm = [regex]::Match($outStr,"Cannot find module '([^']+)'")
        if ($mm.Success) { Write-Host "  - Missing module: $($mm.Groups[1].Value) -- run npm install in $APP" -ForegroundColor Red }
    }
    Write-Host ""
    LogLine "BUILD FAILED: $outStr"
    Save-Log "Build-Frontend"
    Write-Host ""
    Write-Host "  Press any key to exit..." -ForegroundColor DarkGray
    try { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") } catch { Start-Sleep 5 }
    exit 1
}

$distKB = try { [math]::Round((Get-ChildItem "$APP\dist" -Recurse | Measure-Object Length -Sum).Sum / 1KB, 0) } catch { 0 }
Write-OK "Frontend build PASSED (dist: $distKB KB)"

# =============================================================================

Set-StepComplete "build-frontend"
Save-Log "Build-Frontend"
Write-OK "Frontend built. Run Build-Backend.ps1 next."
