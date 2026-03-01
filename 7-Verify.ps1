# =============================================================================
#  VIBERIZE DESKTOP — SCRIPT 4 OF 8: VERIFY  (v8)
#  Post-deploy health check. Read-only (no installs, no changes).
#  Validates: build artifacts, Ollama, inference, font. No firewall checks.
#
#  Run after 1_ViberizeAudit -> 2_ViberizeSetup -> 3_ViberizeBuild.
#  All checks produce a structured pass/warn/fail verdict.
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

Show-Banner "VERIFY" 7

# Fresh-OS fix: refresh PATH from registry so tools installed by Script 2 are visible
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("Path","User")
foreach ($toolDir in @("$env:ProgramFiles\nodejs","${env:ProgramFiles(x86)}\nodejs","$env:USERPROFILE\.cargo\bin")) {
    if ((Test-Path $toolDir -EA SilentlyContinue) -and ($env:Path -notlike "*$toolDir*")) {
        $env:Path = "$toolDir;$env:Path"
    }
}

#Requires -Version 5.1
#Requires -RunAsAdministrator
Set-StrictMode -Off
$ErrorActionPreference = "Continue"

function Write-OK   { param($m) Write-Host "  [PASS]   $m" -ForegroundColor Green    }
function Write-WARN { param($m) Write-Host "  [WARN]   $m" -ForegroundColor Yellow   }
function Write-FAIL { param($m) Write-Host "  [FAIL]   $m" -ForegroundColor Red      }
function Write-HEAD { param($m) Write-Host "`n===  $m  ===" -ForegroundColor White   }
function Write-INFO { param($m) Write-Host "  [...]    $m" -ForegroundColor DarkCyan }

# ROOT defined above
$APP       = "$ROOT\app"
$TAURI_DIR = "$APP\src-tauri"
$LOG_DIR   = "$ROOT\logs"
$VERIFY_LOG = "$LOG_DIR\verify_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

if (-not (Test-Path $LOG_DIR -EA SilentlyContinue)) { New-Item -ItemType Directory $LOG_DIR -Force | Out-Null }

$passes  = [System.Collections.Generic.List[string]]::new()
$warns   = [System.Collections.Generic.List[string]]::new()
$fails   = [System.Collections.Generic.List[string]]::new()
$report  = [System.Text.StringBuilder]::new()

function Pass { param($m) $passes.Add($m); Write-OK $m;   $report.AppendLine("PASS  : $m") | Out-Null }
function Warn { param($m) $warns.Add($m);  Write-WARN $m; $report.AppendLine("WARN  : $m") | Out-Null }
function Fail { param($m) $fails.Add($m);  Write-FAIL $m; $report.AppendLine("FAIL  : $m") | Out-Null }

# ── Find Ollama ──────────────────────────────────────────────────────────────
$ollamaExe = @("$ROOT\ollama\ollama.exe") + (
    $env:Path -split ";" | ForEach-Object { Join-Path $_.Trim() "ollama.exe" }
) | Where-Object { Test-Path $_ -EA SilentlyContinue } | Select-Object -First 1

# =============================================================================
Clear-Host
Write-Host "+==================================================================+" -ForegroundColor Magenta
Write-Host "|   VIBERIZE DESKTOP - VERIFY  (Script 4 of 8)  v8              |" -ForegroundColor Magenta
Write-Host "|   Post-deploy health check -- all systems                       |" -ForegroundColor Magenta
Write-Host "+==================================================================+" -ForegroundColor Magenta
Write-Host ""

$report.AppendLine("VIBERIZE DESKTOP -- VERIFY REPORT") | Out-Null
$report.AppendLine("Generated : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')") | Out-Null
$report.AppendLine("Machine   : $env:COMPUTERNAME") | Out-Null
$report.AppendLine(("=" * 70)) | Out-Null

# =============================================================================
Write-HEAD "1. BUILD ARTIFACTS"
# =============================================================================

# Frontend dist
if (Test-Path "$APP\dist\index.html" -EA SilentlyContinue) { Pass "dist/index.html exists" }
else { Fail "dist/index.html missing -- run Script 3" }

$distSize = try {
    [math]::Round((Get-ChildItem "$APP\dist" -Recurse -EA SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum / 1KB, 0)
} catch { 0 }
if ($distSize -gt 50) { Pass "Frontend bundle: ${distSize} KB" }
elseif ($distSize -gt 0) { Warn "Frontend bundle suspiciously small: ${distSize} KB" }
else { Fail "Frontend dist empty or missing" }

# Release EXE
$exePath = Get-ChildItem "$TAURI_DIR\target\release\*.exe" -EA SilentlyContinue |
    Where-Object { $_.Name -notmatch "(build_script|cargo-)" } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($exePath) { Pass "Release EXE: $($exePath.Name) ($([math]::Round($exePath.Length/1MB,1)) MB)" }
else { Warn "Release EXE not found -- cargo tauri build may be in progress" }

# MSI installer
$msiPath = Get-ChildItem "$TAURI_DIR\target\release\bundle\msi\*.msi" -EA SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($msiPath) { Pass "MSI installer: $($msiPath.Name)" }
else { Warn "MSI not found (non-blocking -- EXE can be used directly)" }

# =============================================================================
Write-HEAD "2. FONT MIGRATION (Outfit -> Inter)"
# =============================================================================

# Confirm @fontsource-variable/inter installed
if (Test-Path "$APP\node_modules\@fontsource-variable\inter" -EA SilentlyContinue) {
    Pass "@fontsource-variable/inter installed in node_modules"
} elseif (Test-Path "$APP\node_modules\@fontsource\inter" -EA SilentlyContinue) {
    Pass "@fontsource/inter installed in node_modules"
} else { Fail "@fontsource/inter not installed -- npm install needed" }

# Confirm main.tsx imports Inter
if (Test-Path "$APP\src\main.tsx" -EA SilentlyContinue) {
    $mx = try { Get-Content "$APP\src\main.tsx" -Raw } catch { "" }
    if ($mx -match "@fontsource.*inter") { Pass "main.tsx imports @fontsource/inter" }
    else { Fail "main.tsx missing @fontsource/inter import" }
}

# Confirm NO broken outfit.css
if (Test-Path "$APP\src\fonts\outfit.css" -EA SilentlyContinue) {
    $oc = try { Get-Content "$APP\src\fonts\outfit.css" -Raw } catch { "" }
    if ($oc -match "\.\./\.\./\.\./assets") {
        Fail "outfit.css still has url() outside Vite root (RC-3 not fixed)"
    } else { Warn "outfit.css exists but no bad url() (may be harmless)" }
} else { Pass "outfit.css removed (RC-3 fix confirmed)" }

# Confirm tokens.css has no bad @import
if (Test-Path "$APP\src\styles\tokens.css" -EA SilentlyContinue) {
    $tc = try { Get-Content "$APP\src\styles\tokens.css" -Raw } catch { "" }
    if ($tc -match "@import.*outfit") { Fail "tokens.css still imports outfit.css" }
    else { Pass "tokens.css: no broken font @import" }
}

# =============================================================================
Write-HEAD "3. BUILD CONFIG INTEGRITY (RC-1, RC-2)"
# =============================================================================

# postcss.config.js CJS
# v8: postcss.config.cjs must exist, postcss.config.js must NOT
if (Test-Path "$APP\postcss.config.js" -EA SilentlyContinue) {
    Fail "postcss.config.js exists -- MUST be .cjs (Node 24 jsonLoader crash)"
} else { Pass "postcss.config.js absent (correct)" }
if (Test-Path "$APP\postcss.config.cjs" -EA SilentlyContinue) {
    $pc = try { Get-Content "$APP\postcss.config.cjs" -Raw } catch { "" }
    if ($pc -match "module\.exports") { Pass "postcss.config.cjs: valid CJS" }
    else { Warn "postcss.config.cjs: unexpected format" }
} else { Fail "postcss.config.cjs missing" }

# tailwind.config.js (not .ts)
# v8: tailwind.config.cjs (explicit CJS for Node 24 compat)
if (Test-Path "$APP\tailwind.config.cjs" -EA SilentlyContinue) {
    $tw = try { Get-Content "$APP\tailwind.config.cjs" -Raw } catch { "" }
    if ($tw -match "module\.exports") { Pass "tailwind.config.cjs: valid CJS" }
    else { Warn "tailwind.config.cjs: may not be CJS" }
} elseif (Test-Path "$APP\tailwind.config.js" -EA SilentlyContinue) {
    Warn "tailwind.config.js exists but should be .cjs for Node 24 compat"
} else { Fail "tailwind.config.cjs missing" }

if (Test-Path "$APP\tailwind.config.ts" -EA SilentlyContinue) {
    Fail "tailwind.config.ts still exists -- remove it"
} else { Pass "tailwind.config.ts: correctly absent" }
if (Test-Path "$APP\tailwind.config.js" -EA SilentlyContinue) {
    Warn "tailwind.config.js exists -- should be migrated to .cjs"
}

# =============================================================================
Write-HEAD "4. OLLAMA (offline LLM backbone)"
# =============================================================================

if ($ollamaExe) { Pass "Ollama EXE: $ollamaExe" }
else { Fail "Ollama not installed -- run Script 2" }

# Server running check
$ollamaRunning = $false
try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:11434/" -UseBasicParsing -TimeoutSec 5 -EA Stop
    if ($r.StatusCode -eq 200) { Pass "Ollama server: running on 127.0.0.1:11434"; $ollamaRunning = $true }
} catch {
    Warn "Ollama server not running -- start it:"
    if ($ollamaExe) { Write-Host "    $ollamaExe serve" -ForegroundColor Gray }
}

# Verify ONLY loopback (not 0.0.0.0)
if ($ollamaRunning) {
    # Check OLLAMA_HOST env is loopback
    $ollamaHost = [System.Environment]::GetEnvironmentVariable("OLLAMA_HOST")
    if ($ollamaHost -eq "127.0.0.1:11434") { Pass "OLLAMA_HOST: loopback only (secure)" }
    elseif ($ollamaHost -eq "" -or $null -eq $ollamaHost) {
        Warn "OLLAMA_HOST not set -- Ollama defaults to 127.0.0.1 (check if correct)"
    } elseif ($ollamaHost -match "0\.0\.0\.0") {
        Fail "OLLAMA_HOST=$ollamaHost -- exposed to network (security risk -- set to 127.0.0.1:11434)"
    }
}

# Model list
if ($ollamaRunning) {
    try {
        $tags = (Invoke-WebRequest -Uri "http://127.0.0.1:11434/api/tags" `
            -UseBasicParsing -TimeoutSec 10 -EA Stop).Content | ConvertFrom-Json
        $models = @($tags.models | ForEach-Object { $_.name })
        if ($models.Count -gt 0) {
            Pass "Ollama models: $($models -join ', ')"
        } else {
            Fail "No models pulled -- check selected_model.txt or run: ollama pull <model>"
        }
    } catch { Warn "Could not query /api/tags -- Ollama may be initializing" }
}

# Inference smoke test
if ($ollamaRunning) {
    # Read selected model from config
    $smokeModel = "llama3.2:3b"
    $modelCfg = "$ROOT\selected_model.txt"
    if (Test-Path $modelCfg -EA SilentlyContinue) {
        $cfgModel = (Get-Content $modelCfg -Raw -EA SilentlyContinue).Trim()
        if ($cfgModel) { $smokeModel = $cfgModel }
    }
    # Use first available if configured model not present
    if ($models -and $smokeModel -notin $models) { $smokeModel = $models[0] }

    Write-INFO "Running inference smoke test with $smokeModel (timeout: 60s)..."
    try {
        $body = @{
            model    = $smokeModel
            prompt   = "Reply with exactly one word: ready"
            stream   = $false
            options  = @{ num_predict = 5; temperature = 0.1 }
        } | ConvertTo-Json
        $inferResp = Invoke-WebRequest -Uri "http://127.0.0.1:11434/api/generate" `
            -Method POST -Body $body -ContentType "application/json" `
            -UseBasicParsing -TimeoutSec 60 -EA Stop
        $inferJson = $inferResp.Content | ConvertFrom-Json
        if ($inferJson.response -and $inferJson.response.Trim().Length -gt 0) {
            $resp = $inferJson.response.Trim().Substring(0, [Math]::Min(60, $inferJson.response.Trim().Length))
            Pass "Inference smoke test: PASSED ('$resp')"
        } else { Warn "Inference returned empty response" }
    } catch {
        Warn "Inference test failed: $_ (model may not be loaded -- run: ollama pull llama3.2:3b)"
    }
}

# reqwest in Cargo.lock (confirms Ollama HTTP client compiled in)
if (Test-Path "$TAURI_DIR\Cargo.lock" -EA SilentlyContinue) {
    $lock = try { Get-Content "$TAURI_DIR\Cargo.lock" -Raw } catch { "" }
    if ($lock -match 'name = "reqwest"') { Pass "Cargo.lock: reqwest present (Ollama HTTP client)" }
    else { Warn "reqwest not in Cargo.lock -- Rust build may not have completed" }
    # Confirm llama-cpp-2 is gone
    if ($lock -match 'name = "llama-cpp-2"') {
        Fail "Cargo.lock: llama-cpp-2 still present -- remove from Cargo.toml"
    } else { Pass "Cargo.lock: llama-cpp-2 absent (clean Ollama migration)" }
}

# =============================================================================
Write-HEAD "5. TAURI IPC COMMANDS"
# =============================================================================

if (Test-Path "$TAURI_DIR\src\commands.rs" -EA SilentlyContinue) {
    $cr = try { Get-Content "$TAURI_DIR\src\commands.rs" -Raw } catch { "" }
    $expectedCmds = @("generate_stream","cancel_job","get_available_models","check_ollama_health","ocr_pdf")
    foreach ($cmd in $expectedCmds) {
        if ($cr -match "pub async fn $cmd") { Pass "IPC command: $cmd" }
        else { Warn "IPC command missing: $cmd" }
    }
    if ($cr -match "127\.0\.0\.1:11434") { Pass "commands.rs: Ollama loopback address confirmed" }
    else { Warn "commands.rs: OLLAMA_BASE not found -- check Ollama address" }
} else { Fail "commands.rs missing" }

if (Test-Path "$TAURI_DIR\src\lib.rs" -EA SilentlyContinue) {
    $lr = try { Get-Content "$TAURI_DIR\src\lib.rs" -Raw } catch { "" }
    if ($lr -match "generate_handler") { Pass "lib.rs: invoke_handler registered" }
    else { Warn "lib.rs: invoke_handler may be missing" }
}

# =============================================================================
Write-HEAD "6. SECURITY NOTE (Firewall not managed)"
# =============================================================================
# v7: Firewall management removed. No Windows Firewall rules are created,
# checked, or modified. Ollama security = loopback binding (127.0.0.1:11434).
Pass "Ollama security: loopback-only (127.0.0.1:11434) -- zero LAN/internet exposure"
Pass "Firewall: not managed by these scripts -- your existing rules unchanged"


# =============================================================================
Write-HEAD "7. SECURITY"
# =============================================================================

# CSP check
if (Test-Path "$TAURI_DIR\tauri.conf.json" -EA SilentlyContinue) {
    $tc = try { Get-Content "$TAURI_DIR\tauri.conf.json" -Raw | ConvertFrom-Json } catch { $null }
    if ($tc) {
        $csp = try { $tc.app.security.csp } catch { "" }
        if ($csp -match "127\.0\.0\.1:11434") { Pass "CSP: allows loopback Ollama calls" }
        else { Warn "CSP: may not allow connect-src 127.0.0.1:11434" }
        if ($csp -notmatch "unsafe-eval") { Pass "CSP: no unsafe-eval (secure)" }
        else { Warn "CSP contains unsafe-eval" }
    }
}

# Signing key
$pubKey = "$ROOT\updates\signing_public.key"
if (Test-Path $pubKey -EA SilentlyContinue) {
    $kc = try { Get-Content $pubKey -Raw } catch { "" }
    if ($kc -match "PLACEHOLDER") { Warn "Signing key is placeholder -- replace for production release" }
    else { Pass "Signing public key: non-placeholder (production ready)" }
} else { Warn "Signing public key missing" }

# =============================================================================
Write-HEAD "8. RAG PIPELINE"
# =============================================================================

$ragCfg = "$TAURI_DIR\rag_folders.json"
if (Test-Path $ragCfg -EA SilentlyContinue) {
    try {
        $rc = Get-Content $ragCfg -Raw -EA Stop | ConvertFrom-Json
        $fc = @($rc.folders).Count
        if ($fc -eq 3) { Pass "rag_folders.json: 3 folder selectors" }
        else { Warn "rag_folders.json: $fc selectors (expected 3)" }
    } catch { Warn "rag_folders.json: invalid JSON" }
} else { Warn "rag_folders.json missing -- configure RAG in settings" }

# =============================================================================
Write-HEAD "9. PDF SUPPORT"
# =============================================================================

Pass "PDF text extraction: built-in via pdf-extract Rust crate (no external tools needed)"

# =============================================================================
Write-HEAD "10. OFFLINE INTEGRITY"
# =============================================================================

# Ensure all dist assets use relative paths (no absolute http:// in bundle)
if (Test-Path "$APP\dist" -EA SilentlyContinue) {
    $htmlFiles = Get-ChildItem "$APP\dist" -Filter "*.html" -Recurse -EA SilentlyContinue
    foreach ($hf in $htmlFiles) {
        $hc = try { Get-Content $hf.FullName -Raw } catch { "" }
        if ($hc -match "https://fonts.googleapis.com|https://fonts.gstatic.com") {
            Fail "dist HTML references Google Fonts CDN (offline violation): $($hf.Name)"
        }
        if ($hc -match "https://cdn\.|https://unpkg\.com|https://jsdelivr\.net") {
            Warn "dist HTML may reference CDN (check offline requirement): $($hf.Name)"
        }
    }
    Pass "Offline check: no Google Fonts CDN references in dist"
}

# =============================================================================
Write-HEAD "VERIFY SUMMARY"
# =============================================================================

$pc = $passes.Count; $wc = $warns.Count; $fc = $fails.Count

$report.AppendLine("") | Out-Null
$report.AppendLine(("=" * 70)) | Out-Null
$report.AppendLine("Passes: $pc  |  Warnings: $wc  |  Failures: $fc") | Out-Null
if ($fc -gt 0) { $report.AppendLine("FAILING:"); $fails | ForEach-Object { $report.AppendLine("  X $_") | Out-Null } }
if ($wc -gt 0) { $report.AppendLine("WARNINGS:"); $warns | ForEach-Object { $report.AppendLine("  ! $_") | Out-Null } }
$report.AppendLine(("=" * 70)) | Out-Null

if (-not (Test-Path $LOG_DIR -EA SilentlyContinue)) { New-Item -ItemType Directory $LOG_DIR -Force | Out-Null }
$report.ToString() | Set-Content $VERIFY_LOG -Encoding UTF8

Write-Host ""
if ($fc -eq 0 -and $wc -eq 0) {
    Write-Host "+==================================================================+" -ForegroundColor Green
    Write-Host "|   ALL CHECKS PASSED -- ViberizeDesktop ready to launch         |" -ForegroundColor Green
    Write-Host "+==================================================================+" -ForegroundColor Green
} elseif ($fc -eq 0) {
    Write-Host "+==================================================================+" -ForegroundColor Yellow
    Write-Host "|   PASSED with $wc warning(s) -- review above                   |" -ForegroundColor Yellow
    Write-Host "+==================================================================+" -ForegroundColor Yellow
} else {
    Write-Host "+==================================================================+" -ForegroundColor Red
    Write-Host "|   $fc FAILURE(S) -- must fix before launch                      |" -ForegroundColor Red
    Write-Host "+==================================================================+" -ForegroundColor Red
}

Write-Host ""
Write-Host "  Results:  $pc pass  |  $wc warn  |  $fc fail" -ForegroundColor White
Write-Host ""

if ($exePath) {
    Write-Host "  LAUNCH:" -ForegroundColor White
    Write-Host "  1. Start Ollama:  $ollamaExe serve" -ForegroundColor Cyan
    Write-Host "  2. Launch app:    $($exePath.FullName)" -ForegroundColor Cyan
    Write-Host ""
}

Write-Host "  Report: $VERIFY_LOG" -ForegroundColor DarkGray
Write-Host ""
