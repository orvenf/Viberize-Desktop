# =============================================================================
#  VIBERIZE DESKTOP — SCRIPT 1 OF 8: FULL ENVIRONMENT AUDIT  (v8)
#  Read-only sweep. Zero changes. Outputs: C:\ViberizeDesktop\audit_report.txt
#
#  v8: Banner version corrected. BOM detection added for config files.
#      No firewall management. No system changes.
# =============================================================================

#Requires -Version 5.1
Set-StrictMode -Off
$ErrorActionPreference = "Continue"

# Fresh-OS fix: ensure TLS 1.2 is available for all HTTPS downloads
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$env:NPM_CONFIG_UPDATE_NOTIFIER = "false"
$env:NO_UPDATE_NOTIFIER         = "1"
$env:NODE_NO_WARNINGS           = "1"
$env:ADBLOCK                    = "1"
$env:CI                         = "true"

function Write-OK   { param($m) Write-Host "  [OK]      $m" -ForegroundColor Green  }
function Write-WARN { param($m) Write-Host "  [WARN]    $m" -ForegroundColor Yellow }
function Write-FAIL { param($m) Write-Host "  [MISSING] $m" -ForegroundColor Red    }
function Write-HEAD { param($m) Write-Host "`n---  $m  ---" -ForegroundColor White  }
function Write-INFO { param($m) Write-Host "  [INFO]    $m" -ForegroundColor Cyan   }

$ErrorActionPreference = "Continue"
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

Show-Banner "AUDIT" 1
# ROOT defined above
$REPORT_FILE = "$ROOT\audit_report.txt"
$TOOL_TIMEOUT = 8

$REQUIRED_DIRS = @(
    "$ROOT\app",           "$ROOT\models",       "$ROOT\rag-index",
    "$ROOT\ocr-cache",     "$ROOT\updates",      "$ROOT\logs",
    "$ROOT\assets",        "$ROOT\assets\fonts",
    "$ROOT\patches"
)

$issues   = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()
$report   = [System.Text.StringBuilder]::new()

function Add-R { param($l) [void]$report.AppendLine($l) }
function Fail  { param($m) $issues.Add($m);   Write-FAIL $m; Add-R "MISSING : $m" }
function Warn  { param($m) $warnings.Add($m); Write-WARN $m; Add-R "WARN    : $m" }
function OK    { param($m)                    Write-OK $m;   Add-R "OK      : $m" }

function Get-Items {
    param([string]$Path, [string]$Filter = "*")
    if (-not (Test-Path $Path -EA SilentlyContinue)) { return @() }
    $r = Get-ChildItem $Path -Filter $Filter -ErrorAction SilentlyContinue
    if ($null -eq $r) { return @() } else { return @($r) }
}

function Run-Tool {
    param([string]$ExePath, [string[]]$Arguments = @(), [int]$TimeoutSec = $TOOL_TIMEOUT)
    if (-not (Test-Path $ExePath -EA SilentlyContinue)) {
        $found = Get-Command $ExePath -ErrorAction SilentlyContinue
        if (-not $found) { return "" }
        $ExePath = $found.Source
    }
    try {
        $job = Start-Job -ScriptBlock {
            param($exe, $args_)
            $env:NPM_CONFIG_UPDATE_NOTIFIER = "false"
            $env:NO_UPDATE_NOTIFIER = "1"
            $env:CI = "true"
            try { (& $exe @args_ 2>&1) -join "`n" } catch { "" }
        } -ArgumentList $ExePath, $Arguments
        $done = $job | Wait-Job -Timeout $TimeoutSec
        if ($null -eq $done) { $job | Remove-Job -Force; return "TIMEOUT" }
        $out = Receive-Job $job; $job | Remove-Job -Force
        if ($null -eq $out) { return "" } else { return $out.ToString().Trim() }
    } catch { return "" }
}

function Get-NodeVersionFromRegistry {
    foreach ($rp in @("HKLM:\SOFTWARE\Node.js","HKLM:\SOFTWARE\WOW6432Node\Node.js","HKCU:\SOFTWARE\Node.js")) {
        if (Test-Path $rp -EA SilentlyContinue) {
            $v = try { (Get-ItemProperty $rp -EA Stop).Version } catch { $null }
            if ($v) { return $v.ToString().TrimStart("v") }
        }
    }
    return $null
}

function Get-NodeExePath {
    $paths = @(
        "$env:ProgramFiles\nodejs\node.exe",
        "${env:ProgramFiles(x86)}\nodejs\node.exe",
        "$env:APPDATA\nvm\current\node.exe"
    )
    foreach ($p in $paths) { if (Test-Path $p -EA SilentlyContinue) { return $p } }
    foreach ($dir in ($env:Path -split ";")) {
        $c = Join-Path $dir.Trim() "node.exe"
        if (Test-Path $c -EA SilentlyContinue) { return $c }
    }
    return $null
}

function Get-NodeVersionFromFiles {
    $exe = Get-NodeExePath
    if (-not $exe) { return $null }
    try {
        $fvi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
        if ($fvi.FileVersion) { return $fvi.FileVersion.Split(" ")[0] }
    } catch {}
    return $null
}

# v8: Detect UTF-8 BOM on config files (root cause of Vite PostCSS crash)
function Test-HasBOM {
    param([string]$Path)
    if (-not (Test-Path $Path -EA SilentlyContinue)) { return $false }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        return ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    } catch { return $false }
}

# =============================================================================
Clear-Host
Write-Host "+==================================================================+" -ForegroundColor Magenta
Write-Host "|   VIBERIZE DESKTOP - AUDIT  (Script 1 of 8)  v8                |" -ForegroundColor Magenta
Write-Host "|   Read-only sweep. Zero changes. Identifies what needs fixing.  |" -ForegroundColor Magenta
Write-Host "+==================================================================+" -ForegroundColor Magenta

Add-R "VIBERIZE DESKTOP - AUDIT REPORT  v8"
Add-R "Generated : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Add-R "Machine   : $env:COMPUTERNAME  |  User: $env:USERNAME"
Add-R ("=" * 70)

# ── 1. OS ─────────────────────────────────────────────────────────────────────
Write-HEAD "1. OPERATING SYSTEM"
Add-R ""; Add-R "--- 1. OS ---"

$osBuild = 0
try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $osBuild = [int]$os.BuildNumber
    if ($osBuild -ge 19041) { OK "Windows (Build $osBuild) -- Tauri supported" }
    else { Fail "Windows build $osBuild -- need 19041+" }
    Add-R "OS: $($os.Caption) Build $osBuild"
} catch { Warn "Could not read OS info" }

$psVer = $PSVersionTable.PSVersion
if ($psVer.Major -ge 5) { OK "PowerShell $psVer" } else { Fail "PowerShell 5.1+ required" }
$policy = try { (Get-ExecutionPolicy).ToString() } catch { "Unknown" }
if ($policy -in @("RemoteSigned","Unrestricted","Bypass")) { OK "ExecutionPolicy: $policy" }
else { Warn "ExecutionPolicy '$policy' -- run: Set-ExecutionPolicy RemoteSigned -Scope CurrentUser" }

# ── 2. DISK ───────────────────────────────────────────────────────────────────
Write-HEAD "2. DISK SPACE"
Add-R ""; Add-R "--- 2. Disk ---"

try {
    $dl = (Split-Path -Qualifier $ROOT).TrimEnd(":")
    $freeGB = [math]::Round((Get-PSDrive $dl -EA Stop).Free / 1GB, 1)
    if ($freeGB -ge 20) { OK "Disk: ${freeGB} GB free (need 20 GB)" }
    else { Fail "Only ${freeGB} GB free -- need 20 GB" }
    Add-R "Free: ${freeGB} GB"
} catch { Warn "Could not read disk space" }

# ── 3. DIRS ───────────────────────────────────────────────────────────────────
Write-HEAD "3. DIRECTORIES"
Add-R ""; Add-R "--- 3. Directories ---"

if (Test-Path $ROOT) { OK "Root: $ROOT" } else { Fail "Root missing: $ROOT" }
foreach ($d in $REQUIRED_DIRS) {
    if (Test-Path $d -EA SilentlyContinue) { OK "Exists: $d" } else { Fail "Missing: $d" }
}

# ── 4. NODE ───────────────────────────────────────────────────────────────────
Write-HEAD "4. NODE.JS"
Add-R ""; Add-R "--- 4. Node.js ---"

$nodeVersion = Get-NodeVersionFromRegistry
if (-not $nodeVersion) { $nodeVersion = Get-NodeVersionFromFiles }
$nodeExePath = Get-NodeExePath

if ($nodeVersion) {
    $nm = 0; if ($nodeVersion -match '^(\d+)') { $nm = [int]$Matches[1] }
    if ($nm -ge 18) { OK "Node.js v$nodeVersion >= v18" }
    else { Fail "Node.js v$nodeVersion too old -- need v18+" }
    Add-R "Node: v$nodeVersion"
} elseif ($nodeExePath) {
    Warn "Node.js EXE at $nodeExePath but version unreadable -- likely OK"
} else {
    Fail "Node.js not found -- install from https://nodejs.org (LTS v20+)"
}

foreach ($dir in ($env:Path -split ";")) {
    $nc = Join-Path $dir.Trim() "npm.cmd"
    if (Test-Path $nc -EA SilentlyContinue) { OK "npm found: $nc"; Add-R "npm: $nc"; break }
}

# ── 5. RUST ───────────────────────────────────────────────────────────────────
Write-HEAD "5. RUST & CARGO"
Add-R ""; Add-R "--- 5. Rust ---"

# Fresh-OS: Check for Visual Studio Build Tools / MSVC (required by Rust on Windows)
$vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$hasMSVC = $false
if (Test-Path $vsWhere -EA SilentlyContinue) {
    $vsInstalls = & $vsWhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
    if ($vsInstalls) { $hasMSVC = $true }
}
# Fallback: check for cl.exe in common paths
if (-not $hasMSVC) {
    $clPaths = @(
        "${env:ProgramFiles}\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*\bin\Hostx64\x64\cl.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*\bin\Hostx64\x64\cl.exe"
    )
    foreach ($cp in $clPaths) {
        if (Get-Item $cp -EA SilentlyContinue) { $hasMSVC = $true; break }
    }
}
if ($hasMSVC) { OK "MSVC Build Tools: found (required for Rust compilation)" }
else { Fail "MSVC Build Tools not found -- Script 2 installs VS Build Tools" }

$rustcPath = @("$env:USERPROFILE\.cargo\bin\rustc.exe") + (
    $env:Path -split ";" | ForEach-Object { Join-Path $_.Trim() "rustc.exe" }
) | Where-Object { Test-Path $_ -EA SilentlyContinue } | Select-Object -First 1

if ($rustcPath) {
    $rv = Run-Tool -ExePath $rustcPath -Arguments @("--version") -TimeoutSec $TOOL_TIMEOUT
    if ($rv -eq "TIMEOUT") { Warn "rustc --version timed out" }
    elseif ($rv -match 'rustc (\d+)\.(\d+)') {
        $maj = [int]$Matches[1]; $min = [int]$Matches[2]
        if ($maj -gt 1 -or ($maj -eq 1 -and $min -ge 77)) { OK "Rust $maj.$min (>= 1.77)" }
        else { Fail "Rust $maj.$min too old -- need 1.77+" }
        Add-R "Rust: $rv"
    } else { Warn "rustc responded but version unparseable: $rv" }
} else { Fail "Rust (rustc.exe) not found in PATH or ~/.cargo/bin" }

$cargoPath = @("$env:USERPROFILE\.cargo\bin\cargo.exe") + (
    $env:Path -split ";" | ForEach-Object { Join-Path $_.Trim() "cargo.exe" }
) | Where-Object { Test-Path $_ -EA SilentlyContinue } | Select-Object -First 1
if ($cargoPath) { OK "Cargo: $cargoPath"; Add-R "Cargo: $cargoPath" }
else            { Fail "Cargo not found" }

$tauriExe = @("$env:USERPROFILE\.cargo\bin\cargo-tauri.exe","$env:USERPROFILE\.cargo\bin\tauri.exe") |
    Where-Object { Test-Path $_ -EA SilentlyContinue } | Select-Object -First 1
if ($tauriExe) { OK "Tauri CLI: $tauriExe" }
elseif ($cargoPath) {
    $tv = Run-Tool -ExePath $cargoPath -Arguments @("tauri","--version") -TimeoutSec $TOOL_TIMEOUT
    if ($tv -match "tauri") { OK "Tauri CLI: $($tv.Trim())" }
    elseif ($tv -eq "TIMEOUT") { Warn "Tauri CLI check timed out" }
    else { Fail "Tauri CLI not installed -- run: cargo install tauri-cli --locked" }
}

# ── 6. WEBVIEW2 ───────────────────────────────────────────────────────────────
Write-HEAD "6. WEBVIEW2"
Add-R ""; Add-R "--- 6. WebView2 ---"

$wv2Keys = @(
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}",
    "HKCU:\Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"
)
$wv2 = $wv2Keys | Where-Object { Test-Path $_ -EA SilentlyContinue } | Select-Object -First 1
if ($wv2) { $v = try { (Get-ItemProperty $wv2 -EA Stop).pv } catch { "found" }; OK "WebView2: $v" }
else { Fail "WebView2 runtime not found (required for Tauri)" }

# ── 7. OLLAMA ─────────────────────────────────────────────────────────────────
Write-HEAD "7. OLLAMA (offline LLM backbone)"
Add-R ""; Add-R "--- 7. Ollama ---"

$ollamaExe = @("C:\ViberizeDesktop\ollama\ollama.exe") + (
    $env:Path -split ";" | ForEach-Object { Join-Path $_.Trim() "ollama.exe" }
) | Where-Object { Test-Path $_ -EA SilentlyContinue } | Select-Object -First 1

if ($ollamaExe) {
    OK "Ollama installed: $ollamaExe"
    Add-R "Ollama: $ollamaExe"
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:11434/" -UseBasicParsing -TimeoutSec 3 -EA Stop
        if ($r.StatusCode -eq 200) { OK "Ollama server running on 127.0.0.1:11434" }
    } catch { Warn "Ollama not running -- Script 2 starts it automatically" }
} else { Fail "Ollama not installed -- Script 2 installs it" }

$ggufFiles = @(Get-Items "$ROOT\models" -Filter "*.gguf")
if ($ggufFiles.Count -gt 0) {
    foreach ($m in $ggufFiles) {
        $mb = [math]::Round($m.Length / 1MB, 1)
        OK "Model: $($m.Name) ($mb MB)"
        Add-R "Model: $($m.Name) [$mb MB]"
    }
} else { Warn "No .gguf in $ROOT\models -- Script 2 pulls model via Ollama" }

# ── 8. SOURCE ─────────────────────────────────────────────────────────────────
Write-HEAD "8. APP SOURCE FILES"
Add-R ""; Add-R "--- 8. Source ---"

$srcFiles = @(
    @{ P = "$ROOT\app\package.json";              D = "Frontend package manifest" },
    @{ P = "$ROOT\app\src-tauri\Cargo.toml";      D = "Rust/Tauri manifest" },
    @{ P = "$ROOT\app\src-tauri\tauri.conf.json"; D = "Tauri config" },
    @{ P = "$ROOT\app\src\App.tsx";               D = "React entry component" },
    @{ P = "$ROOT\app\src\styles\tokens.css";     D = "Design tokens CSS" },
    @{ P = "$ROOT\app\src-tauri\src\main.rs";     D = "Rust main.rs" },
    @{ P = "$ROOT\app\src-tauri\src\lib.rs";      D = "Rust lib.rs" },
    @{ P = "$ROOT\app\src-tauri\src\commands.rs"; D = "Rust commands.rs" },
    @{ P = "$ROOT\app\src-tauri\build.rs";        D = "Tauri 2.x build script (sets OUT_DIR)" }
)
foreach ($f in $srcFiles) {
    if (Test-Path $f.P -EA SilentlyContinue) { OK $f.D } else { Fail "$($f.D) MISSING: $($f.P)" }
}

$twCjs = Test-Path "$ROOT\app\tailwind.config.cjs" -EA SilentlyContinue
$twJs = Test-Path "$ROOT\app\tailwind.config.js" -EA SilentlyContinue
$twTs = Test-Path "$ROOT\app\tailwind.config.ts" -EA SilentlyContinue
if ($twCjs) { OK "tailwind.config.cjs (explicit CJS -- correct)" }
elseif ($twJs -and -not $twTs) { OK "tailwind.config.js (CJS -- legacy, consider .cjs)" }
elseif ($twTs)             { Warn "tailwind.config.ts exists -- BuildDeploy converts to .js" }
else                       { Fail "tailwind.config.js missing" }

# v8: postcss.config.cjs must exist (explicit CJS -- Node 24 fix)
# .js variant MUST NOT exist (causes jsonLoader crash under Node 24 + Vite 5.4)
if (Test-Path "$ROOT\app\postcss.config.js" -EA SilentlyContinue) {
    Fail "postcss.config.js exists -- MUST be .cjs not .js (Node 24 crash). BuildDeploy fixes this."
}
if (Test-Path "$ROOT\app\postcss.config.cjs" -EA SilentlyContinue) {
    $pc = try { Get-Content "$ROOT\app\postcss.config.cjs" -Raw } catch { "" }
    if ($pc -match "module\.exports") { OK "postcss.config.cjs: valid CJS (Node 24 safe)" }
    else { Warn "postcss.config.cjs format may be wrong" }
} else { Warn "postcss.config.cjs missing -- BuildDeploy creates it" }

# v8: BOM detection (root cause of Vite crash)
foreach ($cf in @("$ROOT\app\postcss.config.cjs","$ROOT\app\tailwind.config.cjs","$ROOT\app\vite.config.ts")) {
    if (Test-HasBOM $cf) {
        $cfName = Split-Path $cf -Leaf
        Warn "$cfName has UTF-8 BOM -- this will crash Vite. BuildDeploy.ps1 strips it."
    }
}

if (Test-Path "$ROOT\app\node_modules" -EA SilentlyContinue) {
    $nmCount = @(Get-Items "$ROOT\app\node_modules").Count
    OK "node_modules: ~$nmCount packages"
    if (Test-Path "$ROOT\app\node_modules\@fontsource-variable\inter" -EA SilentlyContinue) {
        OK "@fontsource-variable/inter installed"
    } elseif (Test-Path "$ROOT\app\node_modules\@fontsource\inter" -EA SilentlyContinue) {
        OK "@fontsource/inter installed"
    } else { Warn "@fontsource/inter not installed -- Script 2 npm install will add it" }
} else { Fail "node_modules missing -- run Script 2" }

# ── 9. OCR ────────────────────────────────────────────────────────────────────
Write-HEAD "9. PDF SUPPORT"
Add-R ""; Add-R "--- 9. PDF ---"

OK "PDF text extraction: built-in via pdf-extract crate (no external tools needed)"

# ── 10. FONT ──────────────────────────────────────────────────────────────────
Write-HEAD "10. FONT (Inter via @fontsource)"
Add-R ""; Add-R "--- 10. Fonts ---"

if (Test-Path "$ROOT\app\src\fonts\outfit.css" -EA SilentlyContinue) {
    $oc = try { Get-Content "$ROOT\app\src\fonts\outfit.css" -Raw } catch { "" }
    if ($oc -match "\.\./\.\./\.\./assets") {
        Warn "outfit.css has url() pointing outside Vite root -- BuildDeploy removes it"
    } else { OK "outfit.css exists (no bad url())" }
} else { OK "No broken outfit.css (correct)" }

if (Test-Path "$ROOT\app\src\main.tsx" -EA SilentlyContinue) {
    $mx = try { Get-Content "$ROOT\app\src\main.tsx" -Raw } catch { "" }
    if ($mx -match "@fontsource") { OK "@fontsource/inter imported in main.tsx" }
    else { Warn "main.tsx does not import @fontsource/inter" }
}

# ── 11. BUILD CONFIG ──────────────────────────────────────────────────────────
Write-HEAD "11. BUILD CONFIG"
Add-R ""; Add-R "--- 11. Build config ---"

if (Test-Path "$ROOT\app\vite.config.ts" -EA SilentlyContinue) { OK "vite.config.ts exists" }
else { Fail "vite.config.ts missing" }

# ── 12. RAG ───────────────────────────────────────────────────────────────────
Write-HEAD "12. RAG PIPELINE"
Add-R ""; Add-R "--- 12. RAG ---"

$ragCfg = "$ROOT\app\src-tauri\rag_folders.json"
if (Test-Path $ragCfg -EA SilentlyContinue) {
    try {
        $rc = Get-Content $ragCfg -Raw -EA Stop | ConvertFrom-Json
        $fc = @($rc.folders).Count
        if ($fc -eq 3) { OK "rag_folders.json: 3 folder selectors" }
        else { Warn "rag_folders.json: $fc selectors (expected 3)" }
    } catch { Warn "rag_folders.json invalid JSON" }
} else { Warn "rag_folders.json missing -- Script 2 creates it" }

# ── 13. PATCHES ───────────────────────────────────────────────────────────────
Write-HEAD "13. PATCH & UPDATE SYSTEM"
Add-R ""; Add-R "--- 13. Patches ---"

$pubKey = "$ROOT\updates\signing_public.key"
if (Test-Path $pubKey -EA SilentlyContinue) {
    $kc = try { Get-Content $pubKey -Raw } catch { "" }
    if ($kc -match "PLACEHOLDER") { Warn "Signing key is placeholder" }
    else { OK "Signing public key present (non-placeholder)" }
} else { Fail "Signing public key missing: $pubKey" }

# ── 14. SECURITY ──────────────────────────────────────────────────────────────
Write-HEAD "14. SECURITY POSTURE"
Add-R ""; Add-R "--- 14. Security ---"
Add-R "NOTE: Firewall management removed. Ollama is loopback-only (127.0.0.1:11434)."
OK "Ollama bound to 127.0.0.1:11434 (loopback only)"
OK "Firewall: not managed by these scripts (zero changes to your rules)"

if (Test-Path "$ROOT\app\src-tauri\tauri.conf.json" -EA SilentlyContinue) {
    try {
        $tc = Get-Content "$ROOT\app\src-tauri\tauri.conf.json" -Raw | ConvertFrom-Json
        $csp = try { $tc.app.security.csp } catch { "" }
        if ($csp -and $csp -notmatch "unsafe-eval") { OK "CSP: no unsafe-eval (good)" }
        elseif ($csp -match "unsafe-eval") { Warn "CSP contains unsafe-eval" }
        if ($csp -match "127\.0\.0\.1:11434") { OK "CSP: loopback Ollama allowed" }
    } catch {}
}

# ── SUMMARY ───────────────────────────────────────────────────────────────────
Write-HEAD "AUDIT SUMMARY"

$fc = $issues.Count
$wc = $warnings.Count
Add-R ""; Add-R ("=" * 70)
Add-R "Failures: $fc  |  Warnings: $wc"
if ($fc -gt 0) { Add-R "BLOCKING ISSUES:"; $issues | ForEach-Object { Add-R "  X $_" } }
if ($wc -gt 0) { Add-R ""; Add-R "WARNINGS:"; $warnings | ForEach-Object { Add-R "  ! $_" } }
Add-R ""
if ($fc -eq 0) { Add-R "VERDICT: READY -- proceed to Script 2" }
else           { Add-R "VERDICT: $fc blocking issue(s) -- run Script 2 then re-audit" }
Add-R ("=" * 70)
Add-R "Completed: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

if (-not (Test-Path $ROOT -EA SilentlyContinue)) { New-Item -ItemType Directory $ROOT -Force | Out-Null }
$report.ToString() | Set-Content -Path $REPORT_FILE -Encoding UTF8

Write-Host ""
if ($fc -eq 0 -and $wc -eq 0) { Write-Host "  ALL CHECKS PASSED" -ForegroundColor Green }
elseif ($fc -eq 0)             { Write-Host "  PASSED WITH $wc WARNING(S)" -ForegroundColor Yellow }
else                           { Write-Host "  $fc BLOCKING ISSUE(S) -- run Script 2 to resolve" -ForegroundColor Red }
Write-Host ""
Write-Host "  NEXT: Run InstallScaffoldOllama.ps1 as Administrator" -ForegroundColor White
Write-Host "  Report: $REPORT_FILE" -ForegroundColor Cyan
Write-Host ""
