# Fresh-OS fix: ensure TLS 1.2 is available for all HTTPS downloads
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

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

# =============================================================================
#  VIBERIZE DESKTOP — Scaffold Source (Script 3 of 8)
#  Writes all application source files: React, Rust, configs, manifests
#  Re-runnable: overwrites source files to restore clean state
# =============================================================================

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


Show-Banner "SCAFFOLD SOURCE FILES" 3

# Fresh-OS fix: refresh PATH from registry so tools installed by Script 2 are visible
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("Path","User")
# Ensure common tool directories are on PATH
foreach ($toolDir in @("$env:ProgramFiles\nodejs","${env:ProgramFiles(x86)}\nodejs","$env:USERPROFILE\.cargo\bin")) {
    if ((Test-Path $toolDir -EA SilentlyContinue) -and ($env:Path -notlike "*$toolDir*")) {
        $env:Path = "$toolDir;$env:Path"
    }
}

Write-HEAD "WRITING APPLICATION SOURCE"
Write-HEAD "STEP 9: SCAFFOLD APP SOURCE"
# =============================================================================

# ── package.json (Inter replaces Outfit) ─────────────────────────────────────
Write-FileAlways "$APP\package.json" @'
{
  "name": "viberize-desktop",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "dev":   "vite",
    "build": "vite build",
    "tauri": "tauri"
  },
  "dependencies": {
    "react":                     "^18.3.1",
    "react-dom":                 "^18.3.1",
    "@tauri-apps/api":           "^2.1.1",
    "@tauri-apps/plugin-fs":     "^2.0.0",
    "@tauri-apps/plugin-dialog": "^2.0.0",
    "@tauri-apps/plugin-shell":  "^2.0.0",
    "lucide-react":              "^0.263.1",
    "zustand":                   "^4.5.2"
  },
  "devDependencies": {
    "@types/react":          "^18.3.3",
    "@types/react-dom":      "^18.3.0",
    "@vitejs/plugin-react":  "^4.3.1",
    "autoprefixer":          "^10.4.19",
    "postcss":               "^8.4.38",
    "tailwindcss":           "^3.4.4",
    "typescript":            "^5.4.5",
    "vite":                  "^5.3.1",
    "@fontsource/inter": "^5.1.0"
  }
}
'@ -Label "package.json"

# ── tsconfig.json ─────────────────────────────────────────────────────────────
Write-FileAlways "$APP\tsconfig.json" @'
{
  "compilerOptions": {
    "target": "ES2020",
    "useDefineForClassFields": true,
    "lib": ["ES2020","DOM","DOM.Iterable"],
    "module": "ESNext",
    "skipLibCheck": true,
    "moduleResolution": "bundler",
    "allowImportingTsExtensions": true,
    "resolveJsonModule": true,
    "isolatedModules": true,
    "noEmit": true,
    "jsx": "react-jsx",
    "strict": true,
    "noUnusedLocals": false,
    "noUnusedParameters": false,
    "noFallthroughCasesInSwitch": true
  },
  "include": ["src"]
}
'@ -Label "tsconfig.json"

# ── vite.config.ts ────────────────────────────────────────────────────────────
# vite.config.ts with INLINE PostCSS plugins (bypasses postcss-load-config entirely)
# This prevents the Node 24 + Vite 5.4 cosmiconfig jsonLoader crash.
# Uses createRequire to load CJS PostCSS plugins from ESM context.
Write-FileAlways "$APP\vite.config.ts" @'
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const tailwindcss = require("tailwindcss");
const autoprefixer = require("autoprefixer");

export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  server: { port: 1420, strictPort: true },
  envPrefix: ["VITE_","TAURI_"],
  css: {
    postcss: {
      plugins: [tailwindcss, autoprefixer],
    },
  },
  build: {
    target: process.env.TAURI_PLATFORM === "windows" ? "chrome105" : "safari13",
    minify: !process.env.TAURI_DEBUG ? "esbuild" : false,
    sourcemap: !!process.env.TAURI_DEBUG,
  },
});
'@ -Label "vite.config.ts (inline PostCSS via createRequire)"

# ── tailwind.config.cjs (explicit CJS -- Node 24 fix) ────────────────────────
# v8: .cjs extension = always CJS under Node 24+
Write-FileAlways "$APP\tailwind.config.cjs" @'
/** @type {import("tailwindcss").Config} */
module.exports = {
  content: ["./index.html","./src/**/*.{ts,tsx,js,jsx}"],
  theme: {
    extend: {
      fontFamily: {
        sans:  ["InterVariable","Inter","system-ui","sans-serif"],
        inter: ["InterVariable","Inter","sans-serif"],
      },
      colors: {
        vbg:           "var(--v-bg)",
        vsurface:      "var(--v-surface)",
        "vsurface-alt":"var(--v-surface-alt)",
        vstroke:       "var(--v-stroke)",
        vtext:         "var(--v-text)",
        "vtext-sec":   "var(--v-text-sec)",
        "vtext-muted": "var(--v-text-muted)",
        vdanger:       "var(--v-danger)",
        vsuccess:      "var(--v-success)",
      },
      borderRadius: { chip:"999px", btn:"16px", card:"18px", input:"16px" },
    },
  },
  plugins: [],
};
'@ -Label "tailwind.config.cjs"

# Remove stale .ts and .js config (now using .cjs)
foreach ($stale in @("$APP\tailwind.config.ts","$APP\tailwind.config.js")) {
    if (Test-Path $stale -EA SilentlyContinue) {
        Remove-Item $stale -Force -EA SilentlyContinue
        Write-OK "Removed stale $(Split-Path $stale -Leaf)"
    }
}

# v8: postcss.config.cjs (explicit CJS -- Node 24 + Vite 5.4 fix)
# .cjs is loaded via require() by lilconfig. NEVER routed through jsonLoader.
if (Test-Path "$APP\postcss.config.js" -EA SilentlyContinue) {
    Remove-Item "$APP\postcss.config.js" -Force -EA SilentlyContinue
    Write-OK "Removed stale postcss.config.js"
}
Write-FileAlways "$APP\postcss.config.cjs" @'
module.exports = {
  plugins: {
    tailwindcss:  {},
    autoprefixer: {},
  },
};
'@ -Label "postcss.config.cjs"

# ── index.html ────────────────────────────────────────────────────────────────
Write-FileIfMissing "$APP\index.html" @'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <link rel="icon" type="image/png" href="__FAVICON_HREF__" />
    <title>Viberize Desktop</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.tsx"></script>
  </body>
</html>
'@ -Label "index.html"

# ── src/styles/tokens.css (Inter font -- NO url() to external files) ──────────
Ensure-Dir $STYLES
# FONT FIX: No @import url() pointing to TTF files. Inter is imported via npm in main.tsx.
# tokens.css only contains CSS custom properties and base styles.
Write-FileAlways "$STYLES\tokens.css" @'
/* ═══════════════════════════════════════════════════════════════════════════
   Viberize Design Tokens v5 — Three themes: Night, Day, Dusk
   Font: Inter (via @fontsource/inter -- imported in main.tsx)
   ═══════════════════════════════════════════════════════════════════════════ */

/* ── NIGHT (default dark theme) ─────────────────────────────────────────── */
:root, [data-theme="night"] {
  --v-bg:            #070707;
  --v-bg-fade:       rgba(7, 7, 7, 0.92);
  --v-surface:       #111111;
  --v-surface-alt:   #191919;
  --v-surface-pill:  rgba(255, 255, 255, 0.06);
  --v-surface-seg:   #141414;
  --v-surface-seg-on:#222222;
  --v-stroke:        rgba(255, 255, 255, 0.10);
  --v-stroke-mid:    rgba(255, 255, 255, 0.18);
  --v-stroke-strong: rgba(255, 255, 255, 0.30);
  --v-text:          #F2F2F2;
  --v-text-sec:      #C8C8C8;
  --v-text-muted:    #888888;
  --v-text-faint:    #555555;
  --v-text-disabled: #444444;
  --v-danger:        #D15B5B;
  --v-danger-bg:     rgba(209, 91, 91, 0.12);
  --v-danger-border: rgba(209, 91, 91, 0.25);
  --v-danger-text:   #E87676;
  --v-success:       #6FCF97;
  --v-warning:       #F2C94C;
  --v-glow:          rgba(111, 207, 151, 0.35);
  --v-shadow:        rgba(0,0,0,0.5);
}

/* ── DAY (clean light theme) ────────────────────────────────────────────── */
[data-theme="day"] {
  --v-bg:            #FAFAFA;
  --v-bg-fade:       rgba(250, 250, 250, 0.92);
  --v-surface:       #FFFFFF;
  --v-surface-alt:   #F0F0F0;
  --v-surface-pill:  rgba(0, 0, 0, 0.04);
  --v-surface-seg:   #F5F5F5;
  --v-surface-seg-on:#E8E8E8;
  --v-stroke:        rgba(0, 0, 0, 0.10);
  --v-stroke-mid:    rgba(0, 0, 0, 0.15);
  --v-stroke-strong: rgba(0, 0, 0, 0.25);
  --v-text:          #1A1A1A;
  --v-text-sec:      #3D3D3D;
  --v-text-muted:    #777777;
  --v-text-faint:    #AAAAAA;
  --v-text-disabled: #CCCCCC;
  --v-danger:        #C53030;
  --v-danger-bg:     rgba(197, 48, 48, 0.08);
  --v-danger-border: rgba(197, 48, 48, 0.20);
  --v-danger-text:   #C53030;
  --v-success:       #2F855A;
  --v-warning:       #C68A00;
  --v-glow:          rgba(47, 133, 90, 0.20);
  --v-shadow:        rgba(0,0,0,0.08);
}

/* ── DUSK (warm mid-tone) ───────────────────────────────────────────────── */
[data-theme="dusk"] {
  --v-bg:            #1A1520;
  --v-bg-fade:       rgba(26, 21, 32, 0.92);
  --v-surface:       #221C2A;
  --v-surface-alt:   #2A2333;
  --v-surface-pill:  rgba(255, 255, 255, 0.06);
  --v-surface-seg:   #251F2E;
  --v-surface-seg-on:#332B3D;
  --v-stroke:        rgba(255, 255, 255, 0.10);
  --v-stroke-mid:    rgba(255, 255, 255, 0.16);
  --v-stroke-strong: rgba(255, 255, 255, 0.28);
  --v-text:          #EAE6EF;
  --v-text-sec:      #C4BDD0;
  --v-text-muted:    #8A8094;
  --v-text-faint:    #5A5064;
  --v-text-disabled: #4A4054;
  --v-danger:        #E06060;
  --v-danger-bg:     rgba(224, 96, 96, 0.12);
  --v-danger-border: rgba(224, 96, 96, 0.25);
  --v-danger-text:   #F08080;
  --v-success:       #7EC8A0;
  --v-warning:       #E8B84A;
  --v-glow:          rgba(126, 200, 160, 0.30);
  --v-shadow:        rgba(0,0,0,0.4);
}

/* ── Layout tokens (shared across all themes) ───────────────────────────── */
:root {
  --v-pad-x:         20px;
  --v-gap-section:   14px;
  --v-gap-card:      14px;
  --v-r-card:        14px;
  --v-r-input:       10px;
  --v-r-chip:        999px;
  --v-cta-h:         44px;
}

/* ── Reset + base ───────────────────────────────────────────────────────── */
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

body {
  background: var(--v-bg);
  color: var(--v-text);
  font-family: "InterVariable", "Inter", "Segoe UI", system-ui, sans-serif;
  -webkit-font-smoothing: antialiased;
  -moz-osx-font-smoothing: grayscale;
  transition: background 0.3s ease, color 0.3s ease;
}

::-webkit-scrollbar { width: 5px; }
::-webkit-scrollbar-track { background: transparent; }
::-webkit-scrollbar-thumb { background: var(--v-stroke-mid); border-radius: 99px; }
::-webkit-scrollbar-thumb:hover { background: var(--v-stroke-strong); }

/* Smooth theme transitions */
nav, div, button, input, textarea, p, span {
  transition: background-color 0.2s ease, border-color 0.2s ease, color 0.2s ease;
}
'@ -Label "tokens.css (Inter, no url())"


# ── src/main.tsx (Inter font imported HERE, not in CSS url()) ─────────────────
# FONT FIX: Import @fontsource/inter in main.tsx.
# @fontsource ships the font files inside node_modules.
# Vite bundles them from node_modules -- no url() to outside project root.
Write-FileAlways "$SRC\main.tsx" @'
import React from "react";
import ReactDOM from "react-dom/client";
// Inter variable font — loaded from node_modules, bundled by Vite.
// This replaces the old outfit.css @font-face url() approach which crashed
// Vite by pointing to ../../../assets/fonts/ (outside the project root).
import "@fontsource/inter";
import App from "./App";
import "./styles/tokens.css";

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode><App /></React.StrictMode>
);
'@ -Label "main.tsx (Inter font import)"

# ── src/types/index.ts ────────────────────────────────────────────────────────
Ensure-Dir "$SRC\types"
Write-FileAlways "$SRC\types\index.ts" @'
export interface HistoryItem {
  id:              string;
  prompt:          string;
  response:        string;
  improvedPrompt:  string;
  analysis:        string;
  model:           string;
  provider:        string;
  timestamp:       string;
  tone?:           string;
}
export interface RagFolder {
  id:                string;
  label:             string;
  path:              string;
  status:            "available" | "slow" | "not_reachable" | "not_configured";
  last_indexed:      string | null;
  network_optimized: boolean;
}
export interface AppSettings {
  defaultModel:   string;
  persona:        string;
  systemTemplate: string;
  ragFolders:     RagFolder[];
  ollamaApiKey:   string;        // Ollama cloud API key for web search (free tier available)
}
export type JobType = "generate" | "ocr" | "index";
export interface Job {
  id: string; type: JobType;
  status: "running" | "done" | "cancelled" | "error";
  progress: number; message: string;
}
export type Tone = "neutral" | "professional" | "casual" | "concise";
'@ -Label "types/index.ts"

# ── src/utils/parseOutput.ts (shared parser for LLM output) ──────────────────
Ensure-Dir "$SRC\utils"
Write-FileAlways "$SRC\utils\parseOutput.ts" @'
export interface ParsedOutput {
  response: string;
  improvedPrompt: string;
  analysis: string;
}

export function parseOutput(raw: string): ParsedOutput {
  const r: ParsedOutput = { response: "", improvedPrompt: "", analysis: "" };
  const respMatch = raw.match(/===RESPONSE===\s*([\s\S]*?)(?====IMPROVED_PROMPT===|$)/);
  const promptMatch = raw.match(/===IMPROVED_PROMPT===\s*([\s\S]*?)(?====ANALYSIS===|$)/);
  const analysisMatch = raw.match(/===ANALYSIS===\s*([\s\S]*?)$/);

  if (respMatch) r.response = respMatch[1].trim();
  if (promptMatch) r.improvedPrompt = promptMatch[1].trim();
  if (analysisMatch) r.analysis = analysisMatch[1].trim();

  // Fallback: if no delimiters found, treat entire output as response
  if (!r.response && !r.improvedPrompt && !r.analysis) {
    r.response = raw.trim();
  }
  return r;
}
'@ -Label "utils/parseOutput.ts (shared)"

# ── src/store/appStore.ts ─────────────────────────────────────────────────────
Ensure-Dir "$SRC\store"
Write-FileAlways "$SRC\store\appStore.ts" @'
import { create } from "zustand";
import { invoke } from "@tauri-apps/api/core";
import { HistoryItem, Job, AppSettings, Tone } from "../types";

export type Theme = "night" | "day" | "dusk";

const DEFAULT_SETTINGS: AppSettings = {
  defaultModel: "qwen2.5:7b",
  persona:      "",
  systemTemplate: "",
  ollamaApiKey: "",
  ragFolders: [
    { id:"f1", label:"RAG Folder 1", path:"", status:"not_configured", last_indexed:null, network_optimized:true },
    { id:"f2", label:"RAG Folder 2", path:"", status:"not_configured", last_indexed:null, network_optimized:true },
    { id:"f3", label:"RAG Folder 3", path:"", status:"not_configured", last_indexed:null, network_optimized:true },
  ],
};

interface AppState {
  prompt: string; attachments: string[]; streamOutput: string;
  isStreaming: boolean; currentJob: Job | null;
  history: HistoryItem[]; historyOpen: boolean; settingsOpen: boolean;
  settings: AppSettings; activeModel: string;
  tone: Tone; ollamaReady: boolean; ollamaChecking: boolean;
  isLocalOnly: boolean; webSearchEnabled: boolean; theme: Theme;
  viberizeEnabled: boolean;

  setPrompt: (p: string) => void;
  clearPrompt: () => void;
  addAttachment: (p: string) => void;
  removeAttachment: (idx: number) => void;
  appendStream: (t: string) => void;
  finishStream: (item: Omit<HistoryItem,"id">) => void;
  cancelJob: () => void;
  restoreHistory: (item: HistoryItem) => void;
  removeHistory: (id: string) => void;
  clearHistory: () => void;
  toggleHistory: () => void;
  toggleSettings: () => void;
  updateSettings: (s: Partial<AppSettings>) => void;
  setActiveModel: (m: string) => void;
  setTone: (t: Tone) => void;
  setOllamaReady: (b: boolean) => void;
  setOllamaChecking: (b: boolean) => void;
  setIsLocalOnly: (b: boolean) => void;
  setWebSearchEnabled: (b: boolean) => void;
  setViberizeEnabled: (b: boolean) => void;
  setTheme: (t: Theme) => void;
  loadPersistedSettings: () => Promise<void>;
  persistSettings: () => Promise<void>;
}

export const useAppStore = create<AppState>((set, get) => ({
  prompt: "", attachments: [], streamOutput: "",
  isStreaming: false, currentJob: null,
  history: [], historyOpen: false, settingsOpen: false,
  settings: DEFAULT_SETTINGS, activeModel: "qwen2.5:7b",
  tone: "neutral", ollamaReady: false, ollamaChecking: true,
  isLocalOnly: true, webSearchEnabled: false, theme: "night",
  viberizeEnabled: true,

  setPrompt:     (p) => set({ prompt: p }),
  clearPrompt:   ()  => set({ prompt: "", attachments: [], streamOutput: "" }),
  addAttachment: (p) => set(s => ({ attachments: [...s.attachments, p] })),
  removeAttachment: (idx) => set(s => ({ attachments: s.attachments.filter((_, i) => i !== idx) })),
  appendStream:  (t) => set(s => ({ streamOutput: s.streamOutput + t })),
  finishStream:  (item) => set(s => ({
    isStreaming: false, currentJob: null,
    history: [{ ...item, id: crypto.randomUUID() }, ...s.history],
  })),
  cancelJob:      ()    => set({ isStreaming: false, currentJob: null }),
  restoreHistory: (item)=> set({ prompt: item.prompt, streamOutput: item.response }),
  removeHistory:  (id)  => set(s => ({ history: s.history.filter(h => h.id !== id) })),
  clearHistory:   ()    => set({ history: [] }),
  toggleHistory:  ()    => set(s => ({ historyOpen: !s.historyOpen })),
  toggleSettings: ()    => set(s => ({ settingsOpen: !s.settingsOpen })),
  updateSettings: (sv)  => set(s => ({ settings: { ...s.settings, ...sv } })),
  setActiveModel: (m)   => set({ activeModel: m }),
  setTone:        (t)   => set({ tone: t }),
  setOllamaReady: (b)   => set({ ollamaReady: b }),
  setOllamaChecking: (b) => set({ ollamaChecking: b }),
  setIsLocalOnly: (b)   => set({ isLocalOnly: b }),
  setWebSearchEnabled: (b) => set({ webSearchEnabled: b }),
  setViberizeEnabled: (b) => set({ viberizeEnabled: b }),
  setTheme: (t) => {
    document.documentElement.setAttribute("data-theme", t);
    set({ theme: t });
  },

  loadPersistedSettings: async () => {
    try {
      const json = await invoke<string>("load_settings");
      if (json && json !== "{}") {
        const loaded = JSON.parse(json);
        const { activeModel, tone, theme, isLocalOnly, webSearchEnabled, viberizeEnabled, ...rest } = loaded as any;
        set(s => ({
          settings: { ...s.settings, ...rest },
          ...(activeModel ? { activeModel } : {}),
          ...(tone ? { tone } : {}),
          ...(theme ? { theme } : {}),
          ...(typeof isLocalOnly === "boolean" ? { isLocalOnly } : {}),
          ...(typeof webSearchEnabled === "boolean" ? { webSearchEnabled } : {}),
          ...(typeof viberizeEnabled === "boolean" ? { viberizeEnabled } : {}),
        }));
        if (theme) document.documentElement.setAttribute("data-theme", theme);
      }
    } catch {}
  },

  persistSettings: async () => {
    const s = get();
    const payload = { ...s.settings, activeModel: s.activeModel, tone: s.tone, theme: s.theme, isLocalOnly: s.isLocalOnly, webSearchEnabled: s.webSearchEnabled, viberizeEnabled: s.viberizeEnabled };
    try { await invoke("save_settings", { settingsJson: JSON.stringify(payload) }); } catch {}
  },
}));
'@ -Label "store/appStore.ts"




# ── src/App.tsx ───────────────────────────────────────────────────────────────
Write-FileAlways "$SRC\App.tsx" @'
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { useEffect, useRef, useState, useCallback, useMemo } from "react";
import { useAppStore } from "./store/appStore";
import { Navbar }        from "./components/Navbar";
import { PromptCard }    from "./components/PromptCard";
import { ViberizeBtn }   from "./components/ViberizeBtn";
import { HistoryList }   from "./components/HistoryList";
import { SettingsPanel } from "./components/SettingsPanel";
import { ToneBar }       from "./components/ToneBar";
import { OutputCard }    from "./components/OutputCard";
import { Tone }          from "./types";
import { writeTextFile }  from "@tauri-apps/plugin-fs";
import { save }           from "@tauri-apps/plugin-dialog";
import { parseOutput }    from "./utils/parseOutput";

const TONE_INSTRUCTIONS: Record<Tone, string> = {
  neutral: "",
  professional: "Use a professional, business-appropriate tone.",
  casual: "Use a casual, friendly conversational tone.",
  concise: "Be extremely concise and direct. Remove all filler words.",
};

export default function App() {
  const {
    prompt, attachments, isStreaming, appendStream, finishStream,
    cancelJob, settingsOpen, activeModel, tone, history,
    streamOutput, settings, isLocalOnly, webSearchEnabled, viberizeEnabled,
    ollamaReady, ollamaChecking, setOllamaReady, setOllamaChecking,
    loadPersistedSettings,
  } = useAppStore();
  const unlisten = useRef<(() => void) | null>(null);
  const unlistenErr = useRef<(() => void) | null>(null);
  const outputRef = useRef<HTMLDivElement>(null);
  const tokenBuf = useRef("");
  const rafRef = useRef<number | null>(null);
  const [error, setError] = useState<string | null>(null);

  // Load settings + auto-start AI engine + auto-select model
  useEffect(() => {
    loadPersistedSettings();
    let cancelled = false;
    (async () => {
      setOllamaChecking(true);
      // Try up to 3 times with increasing waits (engine may need time to load model)
      let connected = false;
      for (let attempt = 1; attempt <= 3 && !cancelled; attempt++) {
        try {
          const ok = await invoke<boolean>("ensure_ollama_running");
          if (ok) {
            setOllamaReady(true);
            connected = true;
            // Auto-select the best available model
            try {
              const best = await invoke<string>("auto_select_model");
              if (best) useAppStore.getState().setActiveModel(best);
            } catch {}
            break;
          }
        } catch {}
        // Wait before retry (3s, 6s, 9s)
        if (attempt < 3 && !cancelled) {
          await new Promise(r => setTimeout(r, attempt * 3000));
        }
      }
      if (!connected && !cancelled) setOllamaReady(false);
      if (!cancelled) setOllamaChecking(false);
    })();
    // Background health polling — keeps retrying even after splash screen disappears
    const healthInterval = setInterval(async () => {
      if (cancelled) return;
      try {
        const ok = await invoke<boolean>("check_ollama_health");
        const wasReady = useAppStore.getState().ollamaReady;
        if (ok && !wasReady) {
          setOllamaReady(true);
          // Auto-select model on reconnect
          try {
            const best = await invoke<string>("auto_select_model");
            if (best) useAppStore.getState().setActiveModel(best);
          } catch {}
        } else if (!ok && wasReady) {
          setOllamaReady(false);
        }
      } catch {}
    }, 5000);
    return () => { cancelled = true; clearInterval(healthInterval); };
  }, []);

  // Event listeners with token batching (RAF)
  useEffect(() => {
    listen<string>("stream_token", e => {
      tokenBuf.current += e.payload;
      if (!rafRef.current) {
        rafRef.current = requestAnimationFrame(() => {
          appendStream(tokenBuf.current);
          tokenBuf.current = "";
          rafRef.current = null;
          // Scroll to bottom
          if (outputRef.current) {
            outputRef.current.scrollTop = outputRef.current.scrollHeight;
          }
        });
      }
    }).then(u => { unlisten.current = u; });
    listen<string>("stream_error", e => { setError(e.payload); cancelJob(); })
      .then(u => { unlistenErr.current = u; });
    return () => { unlisten.current?.(); unlistenErr.current?.(); };
  }, []);

  // Build system prompt with structured output format + history context
  // Stable reference to recent history (only changes when top item changes)
  const recentHistory = useMemo(
    () => history.slice(0, 3),
    [history.length > 0 ? history[0]?.id : ""]
  );

  const buildSystemPrompt = useCallback(() => {
    const { isLocalOnly: quickMode } = useAppStore.getState();
    let sys = settings.systemTemplate || "You are Viberize, an expert prompt engineer and AI assistant.";

    if (quickMode) {
      // Quick mode: used in pass 2 — just answer the (already improved) prompt
      sys += ` Answer the following prompt directly and thoroughly. Give the best, most helpful response possible.`;
    } else {
      // Deep mode: single call, 3-section output
      sys += ` When the user gives you a prompt, you do three things:

IMPORTANT: You MUST structure your response using these EXACT delimiters:

===RESPONSE===
Provide the actual answer/result that the user's prompt is asking for. This is the primary output.

===IMPROVED_PROMPT===
Provide an improved version of the user's original prompt that would yield even better results from any LLM. Just the prompt text, nothing else.

===ANALYSIS===
In 2-3 sentences, explain how and why you improved the prompt. Be specific and concise.

Always include all three sections with the exact delimiter format above.`;
    }

    if (settings.persona) sys += `\nUser persona: ${settings.persona}`;
    const ti = TONE_INSTRUCTIONS[tone];
    if (ti) sys += `\n${ti}`;

    // History context for continuity (last 3 interactions)
    if (recentHistory.length > 0) {
      sys += "\n\nRecent conversation history for context (use this for continuity):";
      recentHistory.forEach((h, i) => {
        sys += `\n--- Previous interaction ${i + 1} ---`;
        sys += `\nUser prompt: ${h.prompt.substring(0, 300)}`;
        if (h.response) sys += `\nYour response (truncated): ${h.response.substring(0, 200)}`;
      });
    }

    return sys;
  }, [tone, settings, recentHistory]);

  async function handleViberize() {
    if (!prompt.trim() || isStreaming) return;
    setError(null);
    useAppStore.setState({
      isStreaming: true, streamOutput: "",
      currentJob: { id: crypto.randomUUID(), type:"generate", status:"running", progress:0, message:"Generating..." }
    });
    try {
      const { isLocalOnly: quickMode, webSearchEnabled: useWeb, viberizeEnabled: viberize } = useAppStore.getState();

      // ── Step 1: Web search context (if enabled — works regardless of Viberize toggle) ──
      let webContext = "";
      if (useWeb) {
        try {
          useAppStore.setState({
            currentJob: { id: crypto.randomUUID(), type:"generate", status:"running", progress:10, message:"Searching the web..." }
          });
          webContext = await invoke<string>("web_search_ddg", { query: prompt.substring(0, 150) });
        } catch (e: any) {
          console.warn("Web search failed, continuing without:", e);
        }
      }

      // ── Step 1b: RAG context (always runs when folders are indexed) ──
      let ragContext = "";
      try {
        ragContext = await invoke<string>("query_rag", { query: prompt.substring(0, 300) });
      } catch (e: any) {
        console.warn("RAG query failed, continuing without:", e);
      }

      // Combine all external context
      let externalContext = "";
      if (webContext) externalContext += webContext + "\n\n";
      if (ragContext) externalContext += ragContext + "\n\n";

      if (!viberize) {
        // ── Chatbot mode: no prompt improvement, just pass-through ──
        useAppStore.setState({
          currentJob: { id: crypto.randomUUID(), type:"generate", status:"running", progress:30, message:"Generating..." }
        });
        const sys = settings.systemTemplate || (settings.persona ? `You are a helpful assistant. User persona: ${settings.persona}` : "You are a helpful assistant.");
        const finalPrompt = externalContext
          ? `${externalContext}Using the context above, respond to the following:\n\n${prompt}`
          : prompt;

        await invoke("generate_stream", {
          prompt: finalPrompt, model: activeModel, systemPrompt: sys,
          attachments,
        });
        const raw = useAppStore.getState().streamOutput;
        finishStream({
          prompt,
          response: raw,
          improvedPrompt: undefined,
          analysis: undefined,
          model: activeModel, provider: useWeb ? "chatbot+web" : "chatbot",
          timestamp: new Date().toLocaleString(), tone,
        });

      } else if (quickMode) {
        // ── Quick mode: two-pass (improve prompt → answer improved prompt) ──
        // Pass 1: Improve the prompt (non-streaming, fast)
        useAppStore.setState({
          currentJob: { id: crypto.randomUUID(), type:"generate", status:"running", progress:20, message:"Improving prompt..." }
        });
        let improvedPrompt = prompt;
        try {
          improvedPrompt = await invoke<string>("improve_prompt", {
            prompt, model: activeModel,
          });
        } catch {
          // If improvement fails, use original prompt
          improvedPrompt = prompt;
        }

        // Pass 2: Answer the improved prompt (streaming)
        useAppStore.setState({
          currentJob: { id: crypto.randomUUID(), type:"generate", status:"running", progress:50, message:"Generating response..." }
        });
        const sys = buildSystemPrompt();
        const finalPrompt = externalContext
          ? `${externalContext}Using the context above, respond to the following:\n\n${improvedPrompt}`
          : improvedPrompt;

        await invoke("generate_stream", {
          prompt: finalPrompt, model: activeModel, systemPrompt: sys,
          attachments,
        });
        const raw = useAppStore.getState().streamOutput;
        finishStream({
          prompt,
          response: raw,
          improvedPrompt: improvedPrompt !== prompt ? improvedPrompt : undefined,
          analysis: undefined,
          model: activeModel, provider: useWeb ? "quick+web" : "quick",
          timestamp: new Date().toLocaleString(), tone,
        });

      } else {
        // ── Deep mode: single call with 3-section output ──────────────
        useAppStore.setState({
          currentJob: { id: crypto.randomUUID(), type:"generate", status:"running", progress:30, message:"Generating with analysis..." }
        });
        const sys = buildSystemPrompt();
        const finalPrompt = externalContext
          ? `${externalContext}Using the context above, respond to the following:\n\n${prompt}`
          : prompt;

        await invoke("generate_stream", {
          prompt: finalPrompt, model: activeModel, systemPrompt: sys,
          attachments,
        });
        const raw = useAppStore.getState().streamOutput;
        const parsed = parseOutput(raw);
        finishStream({
          prompt,
          response: parsed.response || raw,
          improvedPrompt: parsed.improvedPrompt,
          analysis: parsed.analysis,
          model: activeModel, provider: useWeb ? "deep+web" : "deep",
          timestamp: new Date().toLocaleString(), tone,
        });
      }
    } catch (e: any) {
      setError(e?.toString() || "Generation failed");
      cancelJob();
    }
  }

  async function handleCancel() {
    await invoke("cancel_job").catch(() => {});
    cancelJob();
  }

  async function handleExport(format: "txt" | "md") {
    if (!streamOutput) return;
    try {
      // Export clean response text, not raw delimited output
      const parsed = parseOutput(streamOutput);
      let exportText = parsed.response || streamOutput;
      // In Deep mode, optionally include improved prompt and analysis
      if (!isLocalOnly && parsed.improvedPrompt) {
        exportText += "\n\n---\nImproved Prompt:\n" + parsed.improvedPrompt;
      }
      if (!isLocalOnly && parsed.analysis) {
        exportText += "\n\n---\nAnalysis:\n" + parsed.analysis;
      }
      const path = await save({
        defaultPath: `viberize-output.${format}`,
        filters: [{ name: format.toUpperCase(), extensions: [format] }],
      });
      if (path) await writeTextFile(path, exportText);
    } catch {}
  }

  // Keyboard shortcuts
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
        e.preventDefault();
        if (isStreaming) handleCancel();
        else handleViberize();
      }
      if (e.key === "Escape" && isStreaming) { e.preventDefault(); handleCancel(); }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [isStreaming, prompt, activeModel, tone]);

  // Splash while AI engine starting
  if (ollamaChecking) {
    return (
      <div style={{ minHeight:"100vh", background:"var(--v-bg)", color:"var(--v-text)",
                    display:"flex", flexDirection:"column", alignItems:"center",
                    justifyContent:"center", gap:12, fontFamily:"InterVariable,Inter,sans-serif" }}>
        <div style={{ width:24, height:24, border:"2px solid var(--v-text-muted)", borderTopColor:"transparent", borderRadius:"50%", animation:"spin 1s linear infinite" }} />
        <span style={{ fontSize:14, color:"var(--v-text-muted)", letterSpacing:0.5 }}>Starting Viberize...</span>
        <style>{`@keyframes spin{from{transform:rotate(0deg)}to{transform:rotate(360deg)}}`}</style>
      </div>
    );
  }

  return (
    <div style={{ minHeight:"100vh", background:"var(--v-bg)", color:"var(--v-text)",
                  fontFamily:"InterVariable,Inter,system-ui,sans-serif" }}>
      <Navbar />
      <div style={{ padding:"16px var(--v-pad-x)", display:"flex",
                    flexDirection:"column", gap:"var(--v-gap-section)" }}>
        <PromptCard />
        <ToneBar />
        <ViberizeBtn
          disabled={!prompt.trim() || isStreaming || !ollamaReady}
          loading={isStreaming}
          onClick={isStreaming ? handleCancel : handleViberize}
        />
        {!ollamaReady && !ollamaChecking && (
          <div style={{ background:"rgba(255,200,50,0.08)", border:"1px solid rgba(255,200,50,0.25)",
                        borderRadius:"var(--v-r-card)", padding:"12px 16px", fontSize:13, color:"rgba(255,200,50,0.8)",
                        textAlign:"center" }}>
            AI engine is loading... This may take a moment on first run. It will connect automatically.
          </div>
        )}
        {error && (
          <div style={{ background:"rgba(209,91,91,0.1)", border:"1px solid var(--v-danger)",
                        borderRadius:"var(--v-r-card)", padding:"12px 16px", fontSize:14, color:"var(--v-danger)" }}>
            {error}
            <br/><span style={{ fontSize:12, color:"var(--v-text-muted)" }}>
              The AI engine may still be loading. Please wait a moment and try again.
            </span>
          </div>
        )}
        {streamOutput && (
          <OutputCard
            ref={outputRef}
            output={streamOutput}
            isStreaming={isStreaming}
            onExport={handleExport}
          />
        )}
        <HistoryList />
      </div>
      {settingsOpen && <SettingsPanel />}
      <style>{`@keyframes blink{0%,100%{opacity:1}50%{opacity:0}} @keyframes spin{from{transform:rotate(0deg)}to{transform:rotate(360deg)}}`}</style>
    </div>
  );
}
'@ -Label "App.tsx"




# ── Components ────────────────────────────────────────────────────────────────
Ensure-Dir $COMPONENTS

Write-FileAlways "$COMPONENTS\Navbar.tsx" @'
import { Settings, Globe } from "lucide-react";
import { useAppStore } from "../store/appStore";

/* Logo injected by Script 3 from C:\ViberizeDesktop\assets\logo.png */
/* __LOGO_BASE64__ is replaced at scaffold time by PowerShell */
const LOGO_B64 = "__LOGO_BASE64__";
const hasRealLogo = !LOGO_B64.startsWith("__");

const LogoIcon = () => hasRealLogo ? (
  <img src={`data:image/png;base64,${LOGO_B64}`} width={22} height={22}
       alt="Viberize" style={{ borderRadius:4, objectFit:"contain" }} />
) : (
  <svg viewBox="0 0 100 100" width="22" height="22" fill="none" stroke="currentColor" strokeWidth="5" strokeLinecap="round" strokeLinejoin="round">
    <path d="M50 10 C65 10 80 20 85 35 C90 50 80 65 75 72 C65 85 55 90 50 90 C45 90 35 85 25 72 C20 65 10 50 15 35 C20 20 35 10 50 10Z" />
    <path d="M50 25 L50 75" /><path d="M30 38 L70 62" /><path d="M30 62 L70 38" />
    <circle cx="50" cy="50" r="12" />
  </svg>
);

export function Navbar() {
  const toggleSettings = useAppStore(s => s.toggleSettings);
  const ollamaReady = useAppStore(s => s.ollamaReady);
  const isLocalOnly = useAppStore(s => s.isLocalOnly);
  const setIsLocalOnly = useAppStore(s => s.setIsLocalOnly);
  const webSearchEnabled = useAppStore(s => s.webSearchEnabled);
  const setWebSearchEnabled = useAppStore(s => s.setWebSearchEnabled);
  const viberizeEnabled = useAppStore(s => s.viberizeEnabled);

  return (
    <nav style={{
      height:52, display:"flex", alignItems:"center", justifyContent:"space-between",
      padding:"0 var(--v-pad-x)", borderBottom:"1px solid var(--v-stroke)",
      background:"var(--v-bg-fade)", position:"sticky", top:0, zIndex:50,
      backdropFilter:"blur(12px)",
    }}>
      <div style={{ display:"flex", alignItems:"center", gap:10 }}>
        <div style={{ width:28, height:28, borderRadius:8, background:"var(--v-surface-alt)",
                      border:"1px solid var(--v-stroke)", display:"flex",
                      alignItems:"center", justifyContent:"center", color:"var(--v-text)" }}>
          <LogoIcon />
        </div>
        <span style={{ fontSize:17, fontWeight:700, letterSpacing:-0.3, color:"var(--v-text)",
                       fontFamily:"InterVariable,Inter,sans-serif" }}>Viberize</span>
      </div>
      <div style={{ display:"flex", alignItems:"center", gap:6 }}>
        {/* Quick / Deep toggle — only when Viberize is ON */}
        {viberizeEnabled && (
          <button onClick={() => setIsLocalOnly(!isLocalOnly)}
            title={isLocalOnly
              ? "Quick mode — improves your prompt behind the scenes, shows only the response"
              : "Deep mode — shows response, improved prompt, and analysis"}
            style={{ display:"flex", alignItems:"center", gap:4, padding:"5px 10px",
                     borderRadius:"var(--v-r-chip)", cursor:"pointer", fontSize:12, fontWeight:600,
                     background: isLocalOnly ? "rgba(111,207,151,0.1)" : "rgba(168,130,255,0.1)",
                     border: `1px solid ${isLocalOnly ? "rgba(111,207,151,0.25)" : "rgba(168,130,255,0.3)"}`,
                     color: isLocalOnly ? "var(--v-success)" : "#a882ff",
                     transition:"all 0.2s ease" }}>
            {isLocalOnly ? "⚡ Quick" : "🔍 Deep"}
          </button>
        )}
        {/* Web search toggle — always available */}
        <button onClick={() => setWebSearchEnabled(!webSearchEnabled)}
          title={webSearchEnabled
            ? "Web search ON — results augmented with live web data"
            : "Web search OFF — no internet"}
          style={{ display:"flex", alignItems:"center", gap:4, padding:"5px 10px",
                   borderRadius:"var(--v-r-chip)", cursor:"pointer", fontSize:12, fontWeight:600,
                   background: webSearchEnabled ? "rgba(100,149,237,0.12)" : "rgba(255,255,255,0.04)",
                   border: `1px solid ${webSearchEnabled ? "rgba(100,149,237,0.35)" : "var(--v-stroke)"}`,
                   color: webSearchEnabled ? "cornflowerblue" : "var(--v-text-faint)",
                   transition:"all 0.2s ease" }}>
          <Globe size={12} />
          Web
        </button>
        {/* Status dot */}
        <div title={ollamaReady ? "AI engine running" : "AI engine starting..."}
          style={{ width:8, height:8, borderRadius:4,
                   background: ollamaReady ? "var(--v-success)" : "var(--v-danger)",
                   boxShadow: ollamaReady ? "0 0 6px var(--v-success)" : "none",
                   transition:"all 0.3s ease" }} />
        {/* Settings */}
        <button onClick={toggleSettings} aria-label="Settings"
          style={{ width:36, height:36, borderRadius:10, background:"var(--v-surface-alt)",
                   border:"1px solid var(--v-stroke)", display:"flex", alignItems:"center",
                   justifyContent:"center", cursor:"pointer", color:"var(--v-text-muted)",
                   transition:"all 0.15s ease" }}>
          <Settings size={16} />
        </button>
      </div>
    </nav>
  );
}
'@ -Label "Navbar.tsx"


Write-FileAlways "$COMPONENTS\PromptCard.tsx" @'
import { Paperclip, BookOpen } from "lucide-react";
import { useState, useCallback } from "react";
import { useAppStore } from "../store/appStore";
import { open } from "@tauri-apps/plugin-dialog";

const TEMPLATES = [
  { label: "Rewrite professionally", text: "Rewrite the following text in a professional tone:\n\n" },
  { label: "Improve clarity", text: "Improve the clarity and readability of this text:\n\n" },
  { label: "Convert to bullet points", text: "Convert the following into clear, concise bullet points:\n\n" },
  { label: "Write a job description", text: "Write a detailed job description for the following role:\n\n" },
  { label: "Summarise a document", text: "Summarise the key points of the following document:\n\n" },
  { label: "Draft an email", text: "Draft a professional email about the following:\n\n" },
  { label: "Debug this code", text: "Debug the following code and explain what is wrong:\n\n" },
  { label: "Explain this code", text: "Explain what the following code does in plain language:\n\n" },
  { label: "Make it engaging", text: "Rewrite the following to be more engaging and compelling:\n\n" },
  { label: "Simplify language", text: "Explain the following in simple terms anyone would understand:\n\n" },
];

export function PromptCard() {
  const { prompt, setPrompt, clearPrompt, attachments, addAttachment, removeAttachment } = useAppStore();
  const viberizeEnabled = useAppStore(s => s.viberizeEnabled);
  const [showTemplates, setShowTemplates] = useState(false);

  async function handleAttach() {
    try {
      const sel = await open({
        multiple: true,
        filters: [
          { name: "Documents", extensions: ["pdf","txt","md","csv","json","xml","yaml","yml","toml","html"] },
          { name: "Code", extensions: ["py","rs","ts","tsx","js","jsx","css","sql","sh","bat","ps1"] },
          { name: "Images", extensions: ["png","jpg","jpeg","gif","webp","bmp"] },
          { name: "All Files", extensions: ["*"] },
        ],
      });
      if (!sel) return;
      (Array.isArray(sel) ? sel : [sel]).forEach(f => addAttachment(f as string));
    } catch {}
  }

  const handleDrop = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    Array.from(e.dataTransfer.files).forEach(f => {
      const ext = f.name.split(".").pop()?.toLowerCase() || "";
      const supported = ["txt","md","pdf","csv","json","yaml","yml","toml","xml",
                         "py","rs","ts","tsx","js","jsx","html","css","sql",
                         "log","text","sh","bat","ps1","cfg","ini","env",
                         "png","jpg","jpeg","gif","webp","bmp"];
      if (supported.includes(ext)) {
        const path = (f as any).path || f.name;
        if (path) addAttachment(path);
      }
    });
  }, []);

  return (
    <div style={{ background:"var(--v-surface)", border:"1px solid var(--v-stroke)",
                  borderRadius:"var(--v-r-card)", padding:"var(--v-gap-card)" }}>
      <div style={{ display:"flex", justifyContent:"space-between", alignItems:"center", marginBottom:8 }}>
        <span style={{ fontSize:11, fontWeight:600, letterSpacing:1,
                       textTransform:"uppercase", color:"var(--v-text-muted)" }}>YOUR PROMPT</span>
      </div>
      {showTemplates && (
        <div style={{ marginBottom:10, padding:10, background:"var(--v-surface-alt)",
                      border:"1px solid var(--v-stroke)", borderRadius:10 }}>
          <div style={{ display:"flex", flexWrap:"wrap", gap:5 }}>
            {TEMPLATES.map((t, i) => (
              <button key={i} onClick={() => { setPrompt(t.text); setShowTemplates(false); }}
                style={{ padding:"5px 10px", fontSize:11, borderRadius:7, cursor:"pointer",
                         background:"var(--v-surface)", border:"1px solid var(--v-stroke)",
                         color:"var(--v-text-sec)" }}>
                {t.label}
              </button>
            ))}
          </div>
        </div>
      )}
      <textarea value={prompt} onChange={e => setPrompt(e.target.value)}
        placeholder={viberizeEnabled ? "Paste or type the prompt you want to improve..." : "Ask me anything..."}
        onDrop={handleDrop} onDragOver={e => e.preventDefault()}
        style={{ width:"100%", minHeight:140, resize:"vertical",
                 background:"var(--v-surface-alt)", border:"1px solid var(--v-stroke)",
                 borderRadius:"var(--v-r-input)", padding:14,
                 color:"var(--v-text)", fontSize:15, lineHeight:1.5,
                 fontFamily:"InterVariable,Inter,sans-serif", outline:"none" }}
        onFocus={e => (e.target.style.borderColor = "var(--v-stroke-strong)")}
        onBlur={e  => (e.target.style.borderColor = "var(--v-stroke)")}
      />
      <div style={{ display:"flex", justifyContent:"space-between", alignItems:"center", marginTop:8 }}>
        <div style={{ display:"flex", gap:4, alignItems:"center" }}>
          <button onClick={() => setShowTemplates(v => !v)} title="Prompt templates"
            style={{ width:30, height:30, borderRadius:8, cursor:"pointer",
                     background: showTemplates ? "var(--v-surface-alt)" : "transparent",
                     border:`1px solid ${showTemplates ? "var(--v-stroke-strong)" : "var(--v-stroke)"}`,
                     display:"flex", alignItems:"center", justifyContent:"center", color:"var(--v-text-muted)" }}>
            <BookOpen size={13} />
          </button>
          <button onClick={handleAttach} title="Attach files"
            style={{ width:30, height:30, borderRadius:8, cursor:"pointer",
                     background:"transparent", border:"1px solid var(--v-stroke)",
                     display:"flex", alignItems:"center", justifyContent:"center",
                     color:"var(--v-text-muted)", position:"relative" }}>
            <Paperclip size={13} />
            {attachments.length > 0 && (
              <span style={{ position:"absolute", top:2, right:2, width:7, height:7,
                             borderRadius:"50%", background:"var(--v-success)" }} />
            )}
          </button>
        </div>
        <div style={{ display:"flex", gap:12, alignItems:"center" }}>
          <span style={{ fontSize:11, color:"var(--v-text-faint)" }}>Ctrl+Enter to run</span>
          {prompt.length > 0 && (
            <button onClick={clearPrompt}
              style={{ background:"none", border:"none", cursor:"pointer",
                       fontSize:13, color:"var(--v-text-muted)" }}>Clear</button>
          )}
        </div>
      </div>
      {attachments.length > 0 && (
        <div style={{ marginTop:8, display:"flex", flexWrap:"wrap", gap:5 }}>
          {attachments.map((a, i) => (
            <span key={i} style={{ fontSize:11, padding:"3px 8px",
                                   background:"var(--v-surface-pill)", border:"1px solid var(--v-stroke)",
                                   borderRadius:"var(--v-r-chip)", color:"var(--v-text-muted)",
                                   display:"flex", alignItems:"center", gap:4 }}>
              {a.split(/[\\\/]/).pop()}
              <button onClick={() => removeAttachment(i)}
                style={{ background:"none", border:"none", cursor:"pointer", color:"var(--v-text-muted)",
                         fontSize:12, padding:0, lineHeight:1 }}>\u2715</button>
            </span>
          ))}
        </div>
      )}
    </div>
  );
}
'@ -Label "PromptCard.tsx"


Write-FileAlways "$COMPONENTS\ViberizeBtn.tsx" @'
import { Zap, Square } from "lucide-react";
interface Props { disabled: boolean; loading: boolean; onClick: () => void; }
export function ViberizeBtn({ disabled, loading, onClick }: Props) {
  return (
    <button onClick={onClick} disabled={disabled && !loading}
      aria-label={loading ? "Cancel generation" : "Viberize"}
      style={{ width:"100%", height:"var(--v-cta-h)", borderRadius:"var(--v-r-card)",
               background: disabled && !loading ? "var(--v-surface-alt)" : "var(--v-surface-seg-on)",
               border:"1px solid var(--v-stroke-mid)",
               display:"flex", alignItems:"center", justifyContent:"center", gap:8,
               cursor: disabled && !loading ? "not-allowed" : "pointer",
               transition:"all 0.15s ease",
               color: disabled && !loading ? "var(--v-text-disabled)" : "var(--v-text)",
               fontFamily:"InterVariable,Inter,sans-serif" }}>
      {loading ? <Square size={14} /> : <Zap size={14} style={{ opacity: disabled ? 0.4 : 1 }} />}
      <span style={{ fontSize:14, fontWeight:700, letterSpacing:0.3 }}>{loading ? "Cancel" : "Viberize"}</span>
    </button>
  );
}
'@ -Label "ViberizeBtn.tsx"

Write-FileAlways "$COMPONENTS\ToneBar.tsx" @'
import { useAppStore } from "../store/appStore";
import { Tone } from "../types";
const TONES: { value: Tone; label: string }[] = [
  { value: "neutral", label: "Neutral" },
  { value: "professional", label: "Professional" },
  { value: "casual", label: "Casual" },
  { value: "concise", label: "Concise" },
];
export function ToneBar() {
  const { tone, setTone } = useAppStore();
  return (
    <div style={{ display:"flex", gap:0, borderRadius:12, overflow:"hidden",
                  border:"1px solid var(--v-stroke)" }}>
      {TONES.map((t, i) => (
        <button key={t.value} onClick={() => setTone(t.value)}
          style={{ flex:1, padding:"8px 0", fontSize:13, fontWeight: tone === t.value ? 600 : 400,
                   background: tone === t.value ? "var(--v-surface-alt)" : "transparent",
                   border:"none", borderRight: i < TONES.length-1 ? "1px solid var(--v-stroke)" : "none",
                   color: tone === t.value ? "var(--v-text)" : "var(--v-text-muted)",
                   cursor:"pointer" }}>
          {t.label}
        </button>
      ))}
    </div>
  );
}
'@ -Label "ToneBar.tsx"

Write-FileAlways "$COMPONENTS\OutputCard.tsx" @'
import { Copy, Check, Download } from "lucide-react";
import { forwardRef, useState, useMemo } from "react";
import { parseOutput } from "../utils/parseOutput";
import { useAppStore } from "../store/appStore";

interface Props {
  output: string; isStreaming: boolean;
  onExport: (fmt: "txt"|"md") => void;
}

function CopyBtn({ text, label }: { text: string; label: string }) {
  const [copied, setCopied] = useState(false);
  async function handleCopy() {
    try { await navigator.clipboard.writeText(text); setCopied(true); setTimeout(() => setCopied(false), 1500); } catch {}
  }
  return (
    <button onClick={handleCopy} title={`Copy ${label}`}
      style={{ padding:"4px 10px", fontSize:11, borderRadius:6, cursor:"pointer",
               background:"var(--v-surface-alt)", border:"1px solid var(--v-stroke)",
               color: copied ? "var(--v-success)" : "var(--v-text-muted)",
               display:"flex", alignItems:"center", gap:4 }}>
      {copied ? <><Check size={11} />Copied</> : <><Copy size={11} />Copy</>}
    </button>
  );
}

function Section({ title, content, copyable, isStreaming, scrollRef }: {
  title: string; content: string; copyable?: boolean; isStreaming: boolean;
  scrollRef?: React.Ref<HTMLDivElement>;
}) {
  if (!content && !isStreaming) return null;
  return (
    <div style={{ borderBottom:"1px solid var(--v-stroke)" }}>
      <div style={{ display:"flex", justifyContent:"space-between", alignItems:"center",
                    padding:"8px 14px", background:"var(--v-surface-alt)" }}>
        <span style={{ fontSize:11, fontWeight:600, letterSpacing:0.5,
                       textTransform:"uppercase", color:"var(--v-text-muted)" }}>{title}</span>
        {copyable && content && <CopyBtn text={content} label={title} />}
      </div>
      <div ref={scrollRef}
           style={{ padding:"12px 14px", whiteSpace:"pre-wrap", lineHeight:1.6,
                    fontSize:14, color:"var(--v-text-sec)", maxHeight:300, overflowY:"auto" }}>
        {content || ""}
        {isStreaming && title === "Response" && <span style={{ animation:"blink 1s step-end infinite", color:"var(--v-text-muted)" }}>|</span>}
      </div>
    </div>
  );
}

export const OutputCard = forwardRef<HTMLDivElement, Props>(
  ({ output, isStreaming, onExport }, ref) => {
  const parsed = useMemo(() => parseOutput(output), [output]);
  const isLocalOnly = useAppStore(s => s.isLocalOnly);

  return (
    <div style={{ background:"var(--v-surface)", border:"1px solid var(--v-stroke)",
                  borderRadius:"var(--v-r-card)", overflow:"hidden" }}>
      {isStreaming ? (
        <div>
          <div style={{ padding:"8px 14px", background:"var(--v-surface-alt)",
                        borderBottom:"1px solid var(--v-stroke)" }}>
            <span style={{ fontSize:11, fontWeight:600, letterSpacing:0.5,
                           textTransform:"uppercase", color:"var(--v-text-muted)" }}>Generating...</span>
          </div>
          <div ref={ref} style={{ padding:"12px 14px", whiteSpace:"pre-wrap", lineHeight:1.6,
                                   fontSize:14, color:"var(--v-text-sec)", maxHeight:400, overflowY:"auto" }}>
            {output}
            <span style={{ animation:"blink 1s step-end infinite", color:"var(--v-text-muted)" }}>|</span>
          </div>
        </div>
      ) : (
        <>
          <Section title="Response" content={parsed.response} copyable isStreaming={false} scrollRef={ref} />
          {!isLocalOnly && parsed.improvedPrompt && (
            <Section title="Improved Prompt" content={parsed.improvedPrompt} copyable isStreaming={false} />
          )}
          {!isLocalOnly && parsed.analysis && (
            <Section title="Analysis" content={parsed.analysis} copyable isStreaming={false} />
          )}
          <div style={{ display:"flex", justifyContent:"flex-end", padding:"6px 14px", gap:4 }}>
            <button onClick={() => onExport("txt")} title="Save as .txt"
              style={{ padding:"4px 10px", fontSize:11, borderRadius:6, cursor:"pointer",
                       background:"var(--v-surface-alt)", border:"1px solid var(--v-stroke)",
                       color:"var(--v-text-muted)", display:"flex", alignItems:"center", gap:4 }}>
              <Download size={11} />.txt
            </button>
          </div>
        </>
      )}
    </div>
  );
});
'@ -Label "OutputCard.tsx"


Write-FileAlways "$COMPONENTS\HistoryList.tsx" @'
import { Clock, ChevronUp, ChevronDown, RotateCcw, X } from "lucide-react";
import { useAppStore } from "../store/appStore";
export function HistoryList() {
  const { history, historyOpen, toggleHistory, restoreHistory, removeHistory, clearHistory, prompt } = useAppStore();
  return (
    <div>
      <div style={{ display:"flex", alignItems:"center", gap:8, marginBottom:12 }}>
        <Clock size={16} color="var(--v-text-muted)" />
        <span style={{ fontSize:15, color:"var(--v-text-muted)", flex:1 }}>Recent history</span>
        <span style={{ fontSize:12, padding:"2px 8px", background:"var(--v-surface-alt)",
                       border:"1px solid var(--v-stroke)", borderRadius:8, color:"var(--v-text-muted)" }}>
          {history.length}
        </span>
        <button onClick={toggleHistory} style={{ background:"none", border:"none", cursor:"pointer", color:"var(--v-text-muted)" }}>
          {historyOpen ? <ChevronUp size={16}/> : <ChevronDown size={16}/>}
        </button>
        {historyOpen && history.length > 0 && (
          <button onClick={clearHistory} style={{ background:"none", border:"none", cursor:"pointer",
                                                  fontSize:13, color:"var(--v-text-muted)" }}>Clear all</button>
        )}
      </div>
      {historyOpen && (
        <div style={{ display:"flex", flexDirection:"column", gap:10 }}>
          {history.length === 0 && (
            <p style={{ fontSize:13, color:"var(--v-text-faint)", textAlign:"center", padding:"16px 0" }}>No history yet</p>
          )}
          {history.map(item => (
            <div key={item.id} style={{ background:"var(--v-surface)", border:"1px solid var(--v-stroke)",
                                        borderRadius:"var(--v-r-card)", padding:14,
                                        display:"flex", alignItems:"flex-start", gap:12 }}>
              <div style={{ flex:1, minWidth:0 }}>
                <p style={{ fontSize:14, fontWeight:600, color:"var(--v-text)", overflow:"hidden",
                             display:"-webkit-box", WebkitLineClamp:2, WebkitBoxOrient:"vertical" }}>
                  {item.prompt}
                </p>
                {item.improvedPrompt && (
                  <p style={{ fontSize:12, color:"var(--v-text-sec)", marginTop:4, overflow:"hidden",
                               display:"-webkit-box", WebkitLineClamp:1, WebkitBoxOrient:"vertical", fontStyle:"italic" }}>
                    Improved: {item.improvedPrompt}
                  </p>
                )}
                <p style={{ fontSize:11, color:"var(--v-text-faint)", marginTop:4 }}>
                  {item.model}{item.tone && item.tone !== "neutral" ? ` · ${item.tone}` : ""} · {item.timestamp}
                </p>
              </div>
              <div style={{ display:"flex", gap:6 }}>
                <button onClick={() => {
                    if (prompt && prompt !== item.prompt && !window.confirm("Replace current prompt?")) return;
                    restoreHistory(item);
                  }} title="Restore"
                  style={{ width:40, height:40, borderRadius:14, background:"var(--v-surface-alt)",
                           border:"1px solid var(--v-stroke)", display:"flex", alignItems:"center",
                           justifyContent:"center", cursor:"pointer", color:"var(--v-text-muted)" }}>
                  <RotateCcw size={15} />
                </button>
                <button onClick={() => removeHistory(item.id)} title="Remove"
                  style={{ width:40, height:40, borderRadius:14, background:"var(--v-surface-alt)",
                           border:"1px solid var(--v-stroke)", display:"flex", alignItems:"center",
                           justifyContent:"center", cursor:"pointer", color:"var(--v-text-muted)" }}>
                  <X size={15} />
                </button>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
'@ -Label "HistoryList.tsx"

Write-FileAlways "$COMPONENTS\SettingsPanel.tsx" @'
import { X, ShieldCheck, FolderOpen, RefreshCw, Save, Check, Zap, XCircle } from "lucide-react";
import { useAppStore } from "../store/appStore";
import { invoke } from "@tauri-apps/api/core";
import { open } from "@tauri-apps/plugin-dialog";
import { useState, useEffect } from "react";

export function SettingsPanel() {
  const { settings, updateSettings, toggleSettings, persistSettings } = useAppStore();
  const viberizeEnabled = useAppStore(s => s.viberizeEnabled);
  const setViberizeEnabled = useAppStore(s => s.setViberizeEnabled);
  const [engineOk, setEngineOk] = useState(false);
  const [checking, setChecking] = useState(false);
  const [saved, setSaved] = useState(false);
  const [draft, setDraft] = useState(settings);
  const [indexing, setIndexing] = useState<number | null>(null);

  async function checkEngine() {
    setChecking(true);
    try {
      const ok = await invoke<boolean>("check_ollama_health");
      setEngineOk(ok);
      useAppStore.getState().setOllamaReady(ok);
    } catch { setEngineOk(false); }
    setChecking(false);
  }
  useEffect(() => {
    checkEngine();
    const id = setInterval(checkEngine, 5000);
    return () => clearInterval(id);
  }, []);

  async function handleFolderPick(index: number) {
    try {
      const sel = await open({ directory: true, multiple: false, title: "Select RAG folder" });
      if (sel) {
        const folderPath = sel as string;
        const configuring = draft.ragFolders.map((rf, ri) =>
          ri === index ? { ...rf, path: folderPath, status: "available" as const } : rf
        );
        setDraft(d => ({ ...d, ragFolders: configuring }));
        setIndexing(index);

        try {
          // Layer 4: Frontend timeout — if backend doesn't respond in 35s, recover gracefully
          const timeout = new Promise<never>((_, reject) =>
            setTimeout(() => reject(new Error("Indexing took too long")), 35000)
          );
          const result = await Promise.race([
            invoke<string>("index_rag_folder", { folderPath }),
            timeout,
          ]);
          const indexed = draft.ragFolders.map((rf, ri) =>
            ri === index ? { ...rf, path: folderPath, status: "available" as const,
                             last_indexed: new Date().toISOString() } : rf
          );
          setDraft(d => ({ ...d, ragFolders: indexed }));
        } catch (err: any) {
          const msg = err?.message || err?.toString() || "Unknown error";
          console.warn("RAG indexing failed:", msg);
          const failed = draft.ragFolders.map((rf, ri) =>
            ri === index ? { ...rf, path: folderPath, status: "not_reachable" as const } : rf
          );
          setDraft(d => ({ ...d, ragFolders: failed }));
        }
        setIndexing(null);
      }
    } catch { setIndexing(null); }
  }

  function handleFolderClear(index: number) {
    const cleared = draft.ragFolders.map((rf, ri) =>
      ri === index ? { ...rf, path: "", status: "not_configured" as const, last_indexed: null } : rf
    );
    setDraft(d => ({ ...d, ragFolders: cleared }));
  }

  function handleSave() {
    updateSettings(draft);
    persistSettings();
    setSaved(true);
    setTimeout(() => setSaved(false), 2000);
  }

  const SectionLabel = ({ children }: { children: string }) => (
    <p style={{ fontSize:11, fontWeight:600, letterSpacing:1,
                textTransform:"uppercase", color:"var(--v-text-muted)", marginBottom:8 }}>{children}</p>
  );

  return (
    <div style={{ position:"fixed", inset:0, background:"rgba(0,0,0,0.7)", zIndex:100,
                  display:"flex", justifyContent:"flex-end" }}
         onClick={e => { if (e.target === e.currentTarget) toggleSettings(); }}>
      <div style={{ width:"min(100%, 460px)", height:"100%", overflowY:"auto",
                    background:"var(--v-bg)", borderLeft:"1px solid var(--v-stroke)",
                    padding:"var(--v-gap-card)", fontFamily:"InterVariable,Inter,sans-serif",
                    display:"flex", flexDirection:"column" }}>
        <div style={{ display:"flex", justifyContent:"space-between", alignItems:"center", marginBottom:24 }}>
          <span style={{ fontSize:18, fontWeight:700 }}>Settings</span>
          <button onClick={toggleSettings}
            style={{ width:40, height:40, borderRadius:12, cursor:"pointer",
                     background:"var(--v-surface-alt)", border:"1px solid var(--v-stroke)",
                     display:"flex", alignItems:"center", justifyContent:"center", color:"var(--v-text-muted)" }}>
            <X size={18} />
          </button>
        </div>
        <div style={{ flex:1 }}>
          {/* AI Engine status */}
          <div style={{ background:"var(--v-surface)", border:"1px solid var(--v-stroke)",
                        borderRadius:14, padding:14, marginBottom:24,
                        display:"flex", alignItems:"flex-start", gap:10 }}>
            <ShieldCheck size={18} color={engineOk ? "var(--v-success)" : "var(--v-danger)"} style={{ marginTop:2 }} />
            <div style={{ flex:1 }}>
              <p style={{ fontSize:14, fontWeight:600, color:"var(--v-text)" }}>
                {engineOk ? "AI Engine: Connected" : "AI Engine: Starting..."}
              </p>
              <p style={{ fontSize:12, color:"var(--v-text-muted)", marginTop:4 }}>
                {engineOk ? "All inference runs locally. Zero data leaves your machine." : "The AI engine is loading. This may take a moment on first run."}
              </p>
            </div>
            <button onClick={checkEngine} title="Refresh"
              style={{ width:36, height:36, borderRadius:10, cursor:"pointer",
                       background:"var(--v-surface-alt)", border:"1px solid var(--v-stroke)",
                       display:"flex", alignItems:"center", justifyContent:"center", color:"var(--v-text-muted)" }}>
              <RefreshCw size={14} style={{ animation: checking ? "spin 1s linear infinite" : "none" }} />
            </button>
          </div>
          <SectionLabel>THEME</SectionLabel>
          <div style={{ display:"flex", gap:8, marginBottom:24 }}>
            {(["night", "day", "dusk"] as const).map(t => {
              const current = useAppStore.getState().theme;
              return (
                <button key={t} onClick={() => { useAppStore.getState().setTheme(t); persistSettings(); }}
                  style={{ flex:1, padding:"10px 12px", borderRadius:10, cursor:"pointer",
                           background: current === t ? "var(--v-surface-seg-on)" : "var(--v-surface-alt)",
                           border: `1px solid ${current === t ? "var(--v-stroke-strong)" : "var(--v-stroke)"}`,
                           color:"var(--v-text)", fontSize:13, fontWeight: current === t ? 700 : 400,
                           textTransform:"capitalize" }}>
                  {t === "night" ? "Night" : t === "day" ? "Day" : "Dusk"}
                </button>
              );
            })}
          </div>
          <SectionLabel>VIBERIZE</SectionLabel>
          <div style={{ display:"flex", alignItems:"center", justifyContent:"space-between",
                        background:"var(--v-surface)", border:"1px solid var(--v-stroke)",
                        borderRadius:12, padding:"12px 16px", marginBottom:8 }}>
            <div>
              <p style={{ fontSize:14, fontWeight:600, color:"var(--v-text)" }}>
                {viberizeEnabled ? "Viberize is ON" : "Viberize is OFF"}
              </p>
              <p style={{ fontSize:11, color:"var(--v-text-faint)", marginTop:2 }}>
                {viberizeEnabled
                  ? "Prompts are improved before generating."
                  : "Standard chatbot mode. No prompt improvement."}
              </p>
            </div>
            <button onClick={() => { setViberizeEnabled(!viberizeEnabled); }}
              style={{ width:48, height:26, borderRadius:13, cursor:"pointer",
                       background: viberizeEnabled ? "var(--v-success)" : "var(--v-surface-alt)",
                       border: `1px solid ${viberizeEnabled ? "var(--v-success)" : "var(--v-stroke)"}`,
                       position:"relative", transition:"all 0.2s ease", flexShrink:0 }}>
              <div style={{ width:20, height:20, borderRadius:10,
                            background:"white",
                            position:"absolute", top:2,
                            left: viberizeEnabled ? 25 : 3,
                            transition:"left 0.2s ease",
                            boxShadow:"0 1px 3px rgba(0,0,0,0.3)" }} />
            </button>
          </div>
          <div style={{ height:16 }} />
          <SectionLabel>PERSONA</SectionLabel>
          <input value={draft.persona}
            onChange={e => setDraft(d => ({ ...d, persona: e.target.value }))}
            placeholder="e.g. Senior Product Manager"
            style={{ width:"100%", padding:"12px 14px", marginBottom:16,
                     background:"var(--v-surface-alt)", border:"1px solid var(--v-stroke)",
                     borderRadius:"var(--v-r-input)", color:"var(--v-text)",
                     fontSize:14, fontFamily:"InterVariable,Inter,sans-serif", outline:"none" }} />
          <SectionLabel>SYSTEM PROMPT TEMPLATE</SectionLabel>
          <textarea value={draft.systemTemplate}
            onChange={e => setDraft(d => ({ ...d, systemTemplate: e.target.value }))}
            placeholder="System prompt template..."
            style={{ width:"100%", minHeight:100, resize:"vertical",
                     background:"var(--v-surface-alt)", border:"1px solid var(--v-stroke)",
                     borderRadius:"var(--v-r-input)", padding:"12px 14px",
                     color:"var(--v-text)", fontSize:14,
                     fontFamily:"InterVariable,Inter,sans-serif", outline:"none" }} />
          <SectionLabel>RAG FOLDERS (LOCAL KNOWLEDGE INDEX)</SectionLabel>
          <p style={{ fontSize:12, color:"var(--v-text-faint)", marginBottom:12 }}>
            Index local/network folders to give the offline LLM access to current information.
          </p>
          {draft.ragFolders.map((f, i) => (
            <div key={f.id} style={{ background:"var(--v-surface)", border:"1px solid var(--v-stroke)",
                                     borderRadius:14, padding:"12px 14px", marginBottom:10 }}>
              <div style={{ display:"flex", justifyContent:"space-between", alignItems:"center", marginBottom:6 }}>
                <span style={{ fontSize:13, fontWeight:600 }}>{f.label}</span>
                <span style={{ fontSize:11, color:"var(--v-text-faint)" }}>
                  {indexing === i ? "indexing..." : f.status === "not_reachable" ? "error — try a smaller folder" : f.path ? "configured" : "not configured"}
                </span>
              </div>
              <div style={{ display:"flex", gap:6 }}>
                <input value={f.path}
                  onChange={e => {
                    const updated = draft.ragFolders.map((rf, ri) =>
                      ri === i ? { ...rf, path: e.target.value } : rf
                    );
                    setDraft(d => ({ ...d, ragFolders: updated }));
                  }}
                  placeholder="\\server\share or C:\knowledge-base"
                  style={{ flex:1, padding:"9px 12px", background:"var(--v-surface-alt)",
                           border:"1px solid var(--v-stroke)", borderRadius:10, color:"var(--v-text)",
                           fontSize:13, fontFamily:"InterVariable,Inter,sans-serif", outline:"none" }} />
                <button onClick={() => handleFolderPick(i)} title="Browse folder"
                  style={{ width:36, height:36, borderRadius:10, cursor:"pointer",
                           background:"var(--v-surface-alt)", border:"1px solid var(--v-stroke)",
                           display:"flex", alignItems:"center", justifyContent:"center", color:"var(--v-text-muted)" }}>
                  <FolderOpen size={14} />
                </button>
                {f.path && (
                  <button onClick={() => handleFolderClear(i)} title="Clear folder"
                    style={{ width:36, height:36, borderRadius:10, cursor:"pointer",
                             background:"rgba(209,91,91,0.08)", border:"1px solid rgba(209,91,91,0.2)",
                             display:"flex", alignItems:"center", justifyContent:"center", color:"var(--v-danger)" }}>
                    <XCircle size={14} />
                  </button>
                )}
              </div>
            </div>
          ))}
        </div>
        {/* Save button -- sticky bottom */}
        <div style={{ padding:"16px 0 0", borderTop:"1px solid var(--v-stroke)", marginTop:24 }}>
          <button onClick={handleSave}
            style={{ width:"100%", padding:"14px", borderRadius:12, cursor:"pointer",
                     background: saved ? "var(--v-success)" : "var(--v-surface-alt)",
                     border:"1px solid var(--v-stroke)",
                     color: saved ? "var(--v-bg)" : "var(--v-text)",
                     fontSize:15, fontWeight:700, display:"flex", alignItems:"center",
                     justifyContent:"center", gap:8, transition:"all 0.2s" }}>
            {saved ? <><Check size={18} />Saved</> : <><Save size={18} />Save Settings</>}
          </button>
        </div>
      </div>
      <style>{`@keyframes spin{from{transform:rotate(0deg)}to{transform:rotate(360deg)}}`}</style>
    </div>
  );
}
'@ -Label "SettingsPanel.tsx"



# ── Rust backend ──────────────────────────────────────────────────────────────
Write-FileAlways "$TAURI_DIR\Cargo.toml" @'
[package]
name    = "viberize-desktop"
version = "1.0.0"
edition = "2021"

[lib]
name       = "viberize_desktop_lib"
crate-type = ["staticlib","cdylib","rlib"]

[dependencies]
tauri               = { version = "2", features = [] }
tauri-plugin-fs     = "2"
tauri-plugin-dialog = "2"
tauri-plugin-shell  = "2"
serde               = { version = "1", features = ["derive"] }
serde_json          = "1"
tokio               = { version = "1", features = ["rt-multi-thread", "macros", "sync", "time", "fs", "io-util"] }
anyhow              = "1"
# reqwest: Ollama loopback API + optional DuckDuckGo web search
reqwest             = { version = "0.12", features = ["stream","json"] }
futures-util        = "0.3"
pdf-extract         = "0.7"
base64              = "0.22"

[build-dependencies]
tauri-build = { version = "2", features = [] }

[profile.dev]
incremental = true

[profile.release]
panic         = "abort"
codegen-units = 1
lto           = true
strip         = true
'@ -Label "Cargo.toml"

Write-FileAlways "$TAURI_DIR\src\main.rs" @'
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    let args: Vec<String> = std::env::args().collect();

    // Child process mode: --rag-index <folder_path> <output_json_path>
    if args.len() >= 4 && args[1] == "--rag-index" {
        let folder = &args[2];
        let output = &args[3];
        std::process::exit(rag_worker::run_indexer(folder, output));
    }

    // Normal Tauri app mode
    viberize_desktop_lib::run();
}

/// Isolated RAG indexer that runs in a child process.
/// If this crashes (segfault from pdf_extract), only this process dies.
mod rag_worker {
    use std::path::Path;

    pub fn run_indexer(folder: &str, output_path: &str) -> i32 {
        eprintln!("RAG-WORKER: Indexing {}", folder);
        eprintln!("PROGRESS:0");

        let dir = Path::new(folder);
        if !dir.is_dir() {
            eprintln!("RAG-WORKER: ERROR: Not a directory: {}", folder);
            return 1;
        }

        // Walk directory (depth 3, max 500 files)
        let mut files: Vec<std::path::PathBuf> = Vec::new();
        walk_dir(dir, &mut files, 0);
        eprintln!("RAG-WORKER: Found {} files", files.len());
        eprintln!("PROGRESS:20");

        if files.is_empty() {
            // Write empty index
            let data = serde_json::json!({
                "folder": folder,
                "file_count": 0,
                "indexed_at": timestamp_now(),
                "files": [],
            });
            if write_json(output_path, &data) { return 0; } else { return 1; }
        }

        // Read file contents and build index
        let mut indexed: Vec<serde_json::Value> = Vec::new();
        let total = files.len();
        for (i, file_path) in files.iter().enumerate() {
            let ext = file_path.extension()
                .and_then(|e| e.to_str())
                .unwrap_or("")
                .to_lowercase();

            let content = if ext == "pdf" {
                // This is the dangerous part — pdf_extract can segfault.
                // That is exactly why we run in a child process.
                match std::fs::read(file_path) {
                    Ok(bytes) => {
                        match pdf_extract::extract_text_from_mem(&bytes) {
                            Ok(text) => text,
                            Err(_) => continue,
                        }
                    }
                    Err(_) => continue,
                }
            } else {
                match std::fs::read_to_string(file_path) {
                    Ok(c) => c,
                    Err(_) => continue,
                }
            };

            let preview = if content.len() > 10_000 {
                &content[..10_000]
            } else {
                &content
            };

            indexed.push(serde_json::json!({
                "path": file_path.to_string_lossy(),
                "size": content.len(),
                "preview": preview,
                "modified": std::fs::metadata(file_path)
                    .and_then(|m| m.modified())
                    .map(|t| format!("{:?}", t))
                    .unwrap_or_default(),
            }));

            // Progress: 20-90%
            if total > 0 {
                let pct = 20 + ((i * 70) / total);
                eprintln!("PROGRESS:{}", pct);
            }
        }

        eprintln!("RAG-WORKER: Indexed {} files", indexed.len());
        eprintln!("PROGRESS:95");

        let data = serde_json::json!({
            "folder": folder,
            "file_count": indexed.len(),
            "indexed_at": timestamp_now(),
            "files": indexed,
        });

        if write_json(output_path, &data) {
            eprintln!("PROGRESS:100");
            eprintln!("RAG-WORKER: SUCCESS");
            0
        } else {
            eprintln!("RAG-WORKER: ERROR: Failed to write index");
            1
        }
    }

    fn walk_dir(dir: &Path, out: &mut Vec<std::path::PathBuf>, depth: u32) {
        if depth > 3 || out.len() >= 500 { return; }
        let entries = match std::fs::read_dir(dir) {
            Ok(e) => e,
            Err(_) => return,
        };
        for entry in entries {
            if out.len() >= 500 { return; }
            let entry = match entry {
                Ok(e) => e,
                Err(_) => continue,
            };
            let p = entry.path();
            if let Some(name) = p.file_name().and_then(|n| n.to_str()) {
                if name.starts_with('.') || name.starts_with('$')
                   || name == "desktop.ini" || name == "Thumbs.db"
                   || name == "NTUSER.DAT" { continue; }
            }
            let is_dir = match p.metadata() {
                Ok(m) => m.is_dir(),
                Err(_) => continue,
            };
            if is_dir {
                walk_dir(&p, out, depth + 1);
            } else if let Some(ext) = p.extension().and_then(|e| e.to_str()) {
                if ["txt","md","text","log","rs","ts","tsx","py","json","toml","yaml","yml","csv",
                    "js","jsx","html","css","sql","xml","sh","bat","ps1","cfg","ini","env","pdf"]
                        .contains(&ext.to_lowercase().as_str()) {
                    out.push(p);
                }
            }
        }
    }

    fn timestamp_now() -> String {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs().to_string())
            .unwrap_or_default()
    }

    fn write_json(path: &str, data: &serde_json::Value) -> bool {
        match serde_json::to_string_pretty(data) {
            Ok(json) => {
                if let Some(parent) = Path::new(path).parent() {
                    let _ = std::fs::create_dir_all(parent);
                }
                std::fs::write(path, json).is_ok()
            }
            Err(_) => false,
        }
    }
}
'@ -Label "main.rs"

Write-FileAlways "$TAURI_DIR\src\lib.rs" @'
mod commands;
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_shell::init())
        .invoke_handler(tauri::generate_handler![
            commands::generate_stream,
            commands::cancel_job,
            commands::ocr_pdf,
            commands::index_rag_folder,
            commands::query_rag,
            commands::read_file_content,
            commands::get_available_models,
            commands::check_ollama_health,
            commands::web_search_ddg,
            commands::improve_prompt,
            commands::ensure_ollama_running,
            commands::auto_select_model,
            commands::load_settings,
            commands::save_settings,
        ])
        .run(tauri::generate_context!())
        .expect("error running Viberize Desktop");
}
'@ -Label "lib.rs"


# ── build.rs (REQUIRED for Tauri 2.x -- sets OUT_DIR for generate_context!) ──
Write-FileAlways "$TAURI_DIR\build.rs" @'
fn main() {
    tauri_build::build()
}
'@ -Label "build.rs (Tauri 2.x build script)"

Write-FileAlways "$TAURI_DIR\src\commands.rs" @'
//! Viberize Desktop -- Tauri command handlers
//! All LLM inference routes through Ollama on 127.0.0.1:11434 (loopback only).
//! Zero network egress. Streaming: Ollama NDJSON -> Tauri events -> React.

use std::sync::atomic::{AtomicBool, Ordering};
use std::path::Path;
use tauri::{AppHandle, Emitter, Manager};
use serde::{Deserialize, Serialize};
use futures_util::StreamExt;
use base64::Engine as _;

static CANCEL_FLAG: AtomicBool = AtomicBool::new(false);
const OLLAMA_BASE:  &str = "http://127.0.0.1:11434";
const DEFAULT_MODEL: &str = "qwen2.5:7b";

// Preferred models in order of quality (best first). auto_select_model picks the best one installed.
const PREFERRED_MODELS: &[&str] = &[
    // Tier 1: Premium (needs 16+ GB RAM or 8+ VRAM)
    "llama3.1:8b", "qwen2.5:7b", "gemma2:9b", "mistral:7b", "llama4:8b",
    // Tier 2: Lightweight (needs 8+ GB RAM)
    "qwen2.5:3b", "llama3.2:3b", "phi3:mini", "gemma:2b",
    // Tier 3: Minimal (needs 4+ GB RAM)
    "llama3.2:1b", "tinyllama:1b",
];
const MAX_PROMPT_LEN: usize = 200_000;

#[derive(Debug, Deserialize)]
struct OllamaChunk {
    response: Option<String>,
    done:     Option<bool>,
    error:    Option<String>,
}
#[derive(Debug, Deserialize)]
struct OllamaTagsResp { models: Vec<OllamaModel> }
#[derive(Debug, Deserialize)]
struct OllamaModel { name: String }

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct RagFolder {
    id: String, label: String, path: String, status: String,
    last_indexed: Option<String>, network_optimized: bool,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct AppSettings {
    #[serde(rename = "defaultModel")] default_model: String,
    persona: String,
    #[serde(rename = "systemTemplate")] system_template: String,
    #[serde(rename = "ollamaApiKey", default)] ollama_api_key: String,
    #[serde(rename = "ragFolders")] rag_folders: Vec<RagFolder>,
}

// -- Validation helpers --

fn validate_model_name(model: &str) -> Result<(), String> {
    if model.is_empty() || model.len() > 100 {
        return Err("Invalid model name length".into());
    }
    if !model.chars().all(|c| c.is_alphanumeric() || ".-_:/".contains(c)) {
        return Err("Model name contains invalid characters".into());
    }
    Ok(())
}

fn validate_path(p: &str) -> Result<(), String> {
    if p.contains("..") { return Err("Path traversal not allowed".into()); }
    if p.is_empty() { return Err("Empty path not allowed".into()); }

    // Canonicalize to resolve symlinks and relative paths
    if let Ok(canonical) = std::fs::canonicalize(p) {
        let cs = canonical.to_string_lossy().to_lowercase();
        // Block access to sensitive system directories
        let blocked = ["\\windows\\system32", "\\windows\\syswow64", "/etc/", "/usr/", "/bin/", "/sbin/"];
        for b in &blocked {
            if cs.contains(b) {
                return Err(format!("Access to system directory not allowed: {}", p));
            }
        }
    }
    // Even if canonicalize fails (file doesn't exist yet), the ".." check above still protects
    Ok(())
}

// -- HTTP client: connect timeout only, no response-body timeout for streaming --

// Static clients: one connection pool shared for app lifetime (no re-creation per request)
use std::sync::LazyLock;

static STREAM_CLIENT: LazyLock<reqwest::Client> = LazyLock::new(|| {
    reqwest::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(30))
        .no_proxy()
        .build().expect("reqwest stream client")
});

static QUICK_CLIENT: LazyLock<reqwest::Client> = LazyLock::new(|| {
    reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(15))
        .connect_timeout(std::time::Duration::from_secs(10))
        .no_proxy()
        .build().expect("reqwest quick client")
});

// ============================================================================
// CORE: Streaming LLM generation
// ============================================================================

#[tauri::command]
pub async fn generate_stream(
    app: AppHandle, prompt: String, model: String,
    system_prompt: String, attachments: Vec<String>,
) -> Result<(), String> {
    // Security: validate inputs
    // Fast-fail for extremely long raw prompts (final check happens after attachments)
    if prompt.len() > MAX_PROMPT_LEN {
        let msg = format!("Prompt too long ({} chars, max {})", prompt.len(), MAX_PROMPT_LEN);
        let _ = app.emit("stream_error", &msg);
        return Err(msg);
    }
    let m = if model.trim().is_empty() { DEFAULT_MODEL.to_string() } else { model };
    validate_model_name(&m)?;

    CANCEL_FLAG.store(false, Ordering::SeqCst);

    // Build full prompt with attachments
    let mut full_prompt = String::new();
    let mut images: Vec<String> = Vec::new(); // base64 images for multimodal
    for att_path in &attachments {
        validate_path(att_path)?;
        let p = Path::new(att_path);
        if p.exists() {
            let filename = p.file_name().map(|f| f.to_string_lossy().to_string()).unwrap_or_default();
            let ext = p.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();

            // Images: encode as base64 for Ollama vision models
            if ["png","jpg","jpeg","gif","webp","bmp"].contains(&ext.as_str()) {
                if let Ok(bytes) = tokio::fs::read(p).await {
                    let b64 = base64::engine::general_purpose::STANDARD.encode(&bytes);
                    images.push(b64);
                    full_prompt.push_str(&format!("[Attached image: {}]\n\n", filename));
                }
                continue;
            }

            // PDFs: extract text using pdf-extract
            let content = if ext == "pdf" {
                let fp = att_path.clone();
                match tokio::task::spawn_blocking(move || {
                    std::panic::catch_unwind(|| {
                        std::fs::read(&fp).ok().and_then(|bytes| pdf_extract::extract_text_from_mem(&bytes).ok())
                    }).unwrap_or(None)
                }).await {
                    Ok(Some(text)) => {
                        let trimmed = text.trim().to_string();
                        if trimmed.len() > 15_000 { trimmed[..15_000].to_string() } else { trimmed }
                    }
                    _ => String::new(),
                }
            } else {
                // Text files
                tokio::fs::read_to_string(p).await.unwrap_or_default()
            };

            if !content.is_empty() {
                // Truncate to 20k chars per file
                let truncated = if content.len() > 20_000 {
                    format!("{}...\n[File truncated at 20,000 chars]", &content[..20_000])
                } else { content };
                full_prompt.push_str(&format!("[Attached file: {}]\n{}\n\n", filename, truncated));
            }
        }
    }
    full_prompt.push_str(&prompt);

    // Guard combined prompt length (attachments can push it way past the raw prompt check)
    if full_prompt.len() > MAX_PROMPT_LEN {
        let msg = format!("Combined prompt too long ({} chars, max {})", full_prompt.len(), MAX_PROMPT_LEN);
        let _ = app.emit("stream_error", &msg);
        return Err(msg);
    }

    let payload = serde_json::json!({
        "model": m, "prompt": full_prompt, "system": system_prompt, "stream": true,
        "images": images, // empty array if no images, Ollama ignores it
        "options": { "num_predict": 2048, "temperature": 0.7, "top_p": 0.9 }
    });

    // Try to connect, auto-restart engine if first attempt fails
    let resp = match STREAM_CLIENT
        .post(format!("{}/api/generate", OLLAMA_BASE))
        .json(&payload).send().await {
        Ok(r) => r,
        Err(_first_err) => {
            // Engine might have died — try restarting it
            let _ = ensure_ollama_running().await;
            // Wait a moment for model to load
            tokio::time::sleep(std::time::Duration::from_secs(3)).await;
            // Retry once
            STREAM_CLIENT
                .post(format!("{}/api/generate", OLLAMA_BASE))
                .json(&payload).send().await
                .map_err(|e| {
                    let msg = format!("AI engine unreachable after restart attempt. ({})", e);
                    let _ = app.emit("stream_error", &msg);
                    msg
                })?
        }
    };
    if !resp.status().is_success() {
        let msg = format!("AI engine returned HTTP {}", resp.status());
        let _ = app.emit("stream_error", &msg);
        return Err(msg);
    }
    let mut stream = resp.bytes_stream();
    let mut buf = String::new();
    while let Some(chunk) = stream.next().await {
        // Fix #2: check cancel at chunk level (not just newline level)
        if CANCEL_FLAG.load(Ordering::SeqCst) {
            let _ = app.emit("stream_done", serde_json::Value::Null);
            return Ok(());
        }
        let bytes = chunk.map_err(|e| e.to_string())?;
        buf.push_str(std::str::from_utf8(&bytes).map_err(|e| e.to_string())?);
        while let Some(nl) = buf.find('\n') {
            if CANCEL_FLAG.load(Ordering::SeqCst) {
                let _ = app.emit("stream_done", serde_json::Value::Null);
                return Ok(());
            }
            let line: String = buf.drain(..=nl).collect();
            let line = line.trim();
            if line.is_empty() { continue; }
            if let Ok(c) = serde_json::from_str::<OllamaChunk>(line) {
                if let Some(err) = c.error { let _ = app.emit("stream_error", &err); return Err(err); }
                if let Some(tok) = c.response { if !tok.is_empty() { let _ = app.emit("stream_token", tok); } }
                if c.done.unwrap_or(false) { let _ = app.emit("stream_done", serde_json::Value::Null); return Ok(()); }
            }
        }
    }
    let _ = app.emit("stream_done", serde_json::Value::Null);
    Ok(())
}

#[tauri::command]
pub async fn cancel_job() -> Result<(), String> {
    CANCEL_FLAG.store(true, Ordering::SeqCst); Ok(())
}

// ============================================================================
// PDF text extraction via pdf-extract crate (#8)
// ============================================================================

#[tauri::command]
pub async fn ocr_pdf(_app: AppHandle, file_path: String) -> Result<String, String> {
    validate_path(&file_path)?;
    let p = Path::new(&file_path);
    if !p.exists() { return Err(format!("File not found: {}", file_path)); }

    // Use pdf-extract to get text from PDF (no external tools needed)
    let fp = file_path.clone();
    let extract_task = tokio::task::spawn_blocking(move || {
        // catch_unwind prevents pdf_extract panics from killing the app
        match std::panic::catch_unwind(|| {
            let bytes = std::fs::read(&fp).map_err(|e| format!("Cannot read PDF: {}", e))?;
            pdf_extract::extract_text_from_mem(&bytes)
                .map_err(|e| format!("PDF text extraction failed: {}", e))
        }) {
            Ok(result) => result,
            Err(_) => Err("PDF extraction panicked — file may be corrupted".into()),
        }
    });

    match tokio::time::timeout(std::time::Duration::from_secs(60), extract_task).await {
        Ok(join_result) => {
            let text = join_result.map_err(|e| format!("PDF task failed: {}", e))??;
            let trimmed = text.trim().to_string();
            if trimmed.is_empty() {
                Ok("[PDF contained no extractable text — may be a scanned image PDF]".into())
            } else {
                // Truncate very large PDFs to first 15,000 chars
                let truncated = if trimmed.len() > 15_000 {
                    format!("{}...\n[PDF truncated — showing first 15,000 of {} chars]",
                            &trimmed[..15_000], trimmed.len())
                } else { trimmed };
                Ok(truncated)
            }
        }
        Err(_) => Err("PDF extraction timed out after 60 seconds".into()),
    }
}

// Read any file and return its content (text or base64 for images)
#[tauri::command]
pub async fn read_file_content(file_path: String) -> Result<String, String> {
    validate_path(&file_path)?;
    let p = Path::new(&file_path);
    if !p.exists() { return Err(format!("File not found: {}", file_path)); }

    let ext = p.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();

    // Images: return as base64 for Ollama multimodal
    if ["png","jpg","jpeg","gif","webp","bmp"].contains(&ext.as_str()) {
        let bytes = tokio::fs::read(p).await.map_err(|e| e.to_string())?;
        let b64 = base64::engine::general_purpose::STANDARD.encode(&bytes);
        return Ok(format!("IMAGE_BASE64:{}", b64));
    }

    // PDFs: extract text
    if ext == "pdf" {
        let fp = file_path.clone();
        let task = tokio::task::spawn_blocking(move || {
            match std::panic::catch_unwind(|| {
                let bytes = std::fs::read(&fp).map_err(|e| format!("Cannot read PDF: {}", e))?;
                pdf_extract::extract_text_from_mem(&bytes)
                    .map_err(|e| format!("PDF extraction failed: {}", e))
            }) {
                Ok(result) => result,
                Err(_) => Err("PDF extraction panicked — file may be corrupted".into()),
            }
        });
        let text = match tokio::time::timeout(std::time::Duration::from_secs(60), task).await {
            Ok(join) => join.map_err(|e| e.to_string())??,
            Err(_) => return Err("PDF extraction timed out".into()),
        };
        let trimmed = text.trim().to_string();
        if trimmed.len() > 15_000 {
            return Ok(format!("{}...\n[Truncated — {} chars total]", &trimmed[..15_000], trimmed.len()));
        }
        return Ok(if trimmed.is_empty() { "[No extractable text in PDF]".into() } else { trimmed });
    }

    // Text files: read directly
    match tokio::fs::read_to_string(p).await {
        Ok(content) => {
            if content.len() > 20_000 {
                Ok(format!("{}...\n[Truncated — {} chars total]", &content[..20_000], content.len()))
            } else { Ok(content) }
        }
        Err(_) => Err("Cannot read file as text".into()),
    }
}

// Query RAG index — find relevant file snippets for a given prompt
#[tauri::command]
pub async fn query_rag(app: AppHandle, query: String) -> Result<String, String> {
    let index_dir = app.path().app_data_dir()
        .unwrap_or_else(|_| std::path::PathBuf::from("C:\\ViberizeDesktop"))
        .join("rag-index");
    let idx_file = index_dir.join("index.json");

    if !idx_file.exists() {
        return Ok(String::new()); // No index = no context, not an error
    }

    let idx_json = tokio::fs::read_to_string(&idx_file).await
        .map_err(|e| format!("Cannot read RAG index: {}", e))?;
    let idx: serde_json::Value = serde_json::from_str(&idx_json)
        .map_err(|e| format!("Invalid RAG index JSON: {}", e))?;

    let files = idx.get("files").and_then(|f| f.as_array());
    if files.is_none() { return Ok(String::new()); }
    let files = files.unwrap();
    if files.is_empty() { return Ok(String::new()); }

    // Simple keyword matching: score each file by how many query words appear in its content
    let query_lower = query.to_lowercase();
    let query_words: Vec<&str> = query_lower.split_whitespace()
        .filter(|w| w.len() > 2) // skip tiny words
        .collect();

    if query_words.is_empty() { return Ok(String::new()); }

    let mut scored: Vec<(f64, &serde_json::Value)> = Vec::new();
    for file in files {
        let preview = file.get("preview").and_then(|p| p.as_str()).unwrap_or("");
        let path = file.get("path").and_then(|p| p.as_str()).unwrap_or("");
        let preview_lower = preview.to_lowercase();
        let path_lower = path.to_lowercase();

        let mut score: f64 = 0.0;
        for word in &query_words {
            if preview_lower.contains(word) { score += 1.0; }
            if path_lower.contains(word) { score += 0.5; }
        }
        if score > 0.0 {
            scored.push((score, file));
        }
    }

    if scored.is_empty() {
        // No keyword matches — include top 3 files by recency as general context
        let top: Vec<&serde_json::Value> = files.iter().rev().take(3).collect();
        let mut context = String::from("[Local Knowledge (RAG) — top files from indexed folder]\n\n");
        for f in top {
            let path = f.get("path").and_then(|p| p.as_str()).unwrap_or("unknown");
            let preview = f.get("preview").and_then(|p| p.as_str()).unwrap_or("");
            let snippet = if preview.len() > 500 { &preview[..500] } else { preview };
            context.push_str(&format!("File: {}\n{}\n\n", path, snippet));
        }
        context.push_str("[End of Local Knowledge]\n");
        return Ok(context);
    }

    // Sort by score descending, take top 5
    scored.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
    let top_n = scored.iter().take(5);

    let mut context = String::from("[Local Knowledge (RAG) — relevant files from indexed folder]\n\n");
    for (score, file) in top_n {
        let path = file.get("path").and_then(|p| p.as_str()).unwrap_or("unknown");
        let preview = file.get("preview").and_then(|p| p.as_str()).unwrap_or("");
        // Include more content for higher-scored files
        let max_len = if *score > 2.0 { 1500 } else { 600 };
        let snippet = if preview.len() > max_len { &preview[..max_len] } else { preview };
        context.push_str(&format!("File: {} (relevance: {:.0})\n{}\n\n", path, score, snippet));
    }
    context.push_str("[End of Local Knowledge — cite file paths when referencing this information]\n");

    Ok(context)
}

// ============================================================================
// RAG folder indexing (placeholder with progress events) (#9)
// ============================================================================

#[tauri::command]
pub async fn index_rag_folder(app: AppHandle, folder_path: String) -> Result<String, String> {
    validate_path(&folder_path)?;
    let p = Path::new(&folder_path);
    if !p.is_dir() { return Err(format!("Not a directory: {}", folder_path)); }

    let _ = app.emit("index_progress", 0u32);

    // === TWO-PROCESS ARCHITECTURE ===
    // Spawn a child process to do the actual indexing.
    // If pdf_extract segfaults on a corrupted PDF, only the child dies.
    // The main app stays alive and reports the error to the UI.

    // 1. Determine paths
    let current_exe = std::env::current_exe()
        .map_err(|e| format!("Cannot find own executable: {}", e))?;

    let index_dir = app.path().app_data_dir()
        .unwrap_or_else(|_| std::path::PathBuf::from("C:\\ViberizeDesktop"))
        .join("rag-index");
    if !index_dir.exists() { let _ = std::fs::create_dir_all(&index_dir); }
    let idx_file = index_dir.join("index.json");
    let idx_path_str = idx_file.to_string_lossy().to_string();

    // 2. Spawn child process: same exe with --rag-index flag
    let folder_clone = folder_path.clone();
    let idx_clone = idx_path_str.clone();
    let exe_clone = current_exe.clone();

    let child_task = tokio::task::spawn_blocking(move || {
        use std::process::{Command, Stdio};
        use std::io::{BufRead, BufReader};
        #[cfg(windows)]
        use std::os::windows::process::CommandExt;

        let mut cmd = Command::new(&exe_clone);
        cmd.args(&["--rag-index", &folder_clone, &idx_clone])
            .stdout(Stdio::null())
            .stderr(Stdio::piped());
        #[cfg(windows)]
        cmd.creation_flags(0x08000000); // CREATE_NO_WINDOW

        let mut child = cmd.spawn()
            .map_err(|e| format!("Failed to spawn RAG worker: {}", e))?;

        // Read stderr for progress updates
        let stderr = child.stderr.take();
        let mut last_progress: u32 = 0;
        let mut error_msg = String::new();

        if let Some(pipe) = stderr {
            let reader = BufReader::new(pipe);
            for line in reader.lines().flatten() {
                if line.starts_with("PROGRESS:") {
                    if let Ok(pct) = line[9..].parse::<u32>() {
                        last_progress = pct;
                    }
                } else if line.contains("ERROR:") {
                    error_msg = line.replace("RAG-WORKER: ERROR: ", "");
                }
            }
        }

        let status = child.wait().map_err(|e| format!("RAG worker failed: {}", e))?;

        if status.success() {
            Ok(last_progress)
        } else {
            let code = status.code().unwrap_or(-1);
            if error_msg.is_empty() {
                error_msg = format!("RAG worker exited with code {} (possible crash on a corrupted file)", code);
            }
            Err(error_msg)
        }
    });

    // 3. Wait with timeout (60s)
    let result = match tokio::time::timeout(std::time::Duration::from_secs(60), child_task).await {
        Ok(join) => join.map_err(|e| format!("RAG worker task failed: {}", e))?,
        Err(_) => {
            let _ = app.emit("index_progress", 100u32);
            return Err("RAG indexing timed out after 60 seconds — try a smaller folder".into());
        }
    };

    match result {
        Ok(_) => {
            // 4. Read the index JSON that the child wrote
            let json = tokio::fs::read_to_string(&idx_file).await
                .map_err(|e| format!("Cannot read index file: {}", e))?;
            let data: serde_json::Value = serde_json::from_str(&json)
                .map_err(|e| format!("Invalid index JSON: {}", e))?;
            let count = data["file_count"].as_u64().unwrap_or(0);

            let _ = app.emit("index_progress", 100u32);
            Ok(format!("Indexed {} files from {}", count, folder_path))
        }
        Err(err) => {
            let _ = app.emit("index_progress", 100u32);
            Err(err)
        }
    }
}

// ============================================================================
// Auto-start Ollama (#5)
// ============================================================================

#[tauri::command]
pub async fn ensure_ollama_running() -> Result<bool, String> {
    // Check if already running
    if QUICK_CLIENT.get(format!("{}/", OLLAMA_BASE)).send().await
        .map(|r| r.status().is_success()).unwrap_or(false) {
        return Ok(true);
    }
    // Find ollama binary — check bundled location first, then system
    let ollama_bin = find_ollama_binary();
    let bin = match ollama_bin {
        Some(p) => p,
        None => "ollama".to_string(), // fallback to PATH
    };

    // Verify binary exists before trying to spawn
    if bin != "ollama" && !Path::new(&bin).exists() {
        return Err(format!("AI engine binary not found at: {}", bin));
    }

    // Start ollama as a hidden sidecar — no tray, no window
    let mut cmd = std::process::Command::new(&bin);
    cmd.arg("serve");
    cmd.env("OLLAMA_HOST", "127.0.0.1:11434");
    cmd.env("OLLAMA_ORIGINS", "*");
    cmd.env("OLLAMA_NOPRUNE", "1");
    cmd.env("OLLAMA_FLASH_ATTENTION", "1");
    // Keep models in our directory
    let sys = std::env::var("SystemDrive").unwrap_or_else(|_| "C:".to_string());
    let models_dir = std::env::var("OLLAMA_MODELS")
        .unwrap_or_else(|_| format!(r"{}\ViberizeDesktop\models", sys));
    cmd.env("OLLAMA_MODELS", &models_dir);
    cmd.stdin(std::process::Stdio::null());
    cmd.stdout(std::process::Stdio::null());
    cmd.stderr(std::process::Stdio::null());
    // Windows: CREATE_NO_WINDOW flag hides from taskbar/tray
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x08000000); // CREATE_NO_WINDOW
    }
    match cmd.spawn() {
        Ok(_) => {
            // Poll for up to 90 seconds — first model load can be slow
            for i in 0..90 {
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                if QUICK_CLIENT.get(format!("{}/", OLLAMA_BASE)).send().await
                    .map(|r| r.status().is_success()).unwrap_or(false) {
                    return Ok(true);
                }
                // Log progress every 10s (visible in debug builds)
                if i > 0 && i % 10 == 0 {
                    eprintln!("[viberize] Waiting for AI engine... {}s", i);
                }
            }
            Err("AI engine started but did not become ready within 90s".into())
        }
        Err(e) => Err(format!("Could not start AI engine: {} (path: {})", e, bin))
    }
}

fn find_ollama_binary() -> Option<String> {
    // 1. Check our bundled sidecar directory (relative to exe)
    if let Ok(exe_path) = std::env::current_exe() {
        // From release: C:\ViberizeDesktop\app\src-tauri\target\release\viberize-desktop.exe
        // Walk up to: C:\ViberizeDesktop\ollama\ollama.exe
        if let Some(root) = exe_path.parent()
            .and_then(|p| p.parent())
            .and_then(|p| p.parent())
            .and_then(|p| p.parent())
            .and_then(|p| p.parent())
        {
            let p = root.join("ollama").join("ollama.exe");
            if p.exists() { return Some(p.to_string_lossy().to_string()); }
        }
        // Also check 2 levels up (for direct run from target/release/)
        if let Some(root) = exe_path.parent()
            .and_then(|p| p.parent())
        {
            let p = root.join("ollama").join("ollama.exe");
            if p.exists() { return Some(p.to_string_lossy().to_string()); }
        }
    }
    // 2. Check VIBERIZE_ROOT env var
    if let Ok(root) = std::env::var("VIBERIZE_ROOT") {
        let p = format!(r"{}\ollama\ollama.exe", root);
        if Path::new(&p).exists() { return Some(p); }
    }
    // 3. System drive default location
    let sys = std::env::var("SystemDrive").unwrap_or_else(|_| "C:".to_string());
    let p = format!(r"{}\ViberizeDesktop\ollama\ollama.exe", sys);
    if Path::new(&p).exists() { return Some(p); }
    // 4. User's LOCALAPPDATA (default Ollama installer location)
    if let Ok(appdata) = std::env::var("LOCALAPPDATA") {
        let p = format!(r"{}\Programs\Ollama\ollama.exe", appdata);
        if Path::new(&p).exists() { return Some(p); }
    }
    // 5. Program Files
    if let Ok(pf) = std::env::var("ProgramFiles") {
        let p = format!(r"{}\Ollama\ollama.exe", pf);
        if Path::new(&p).exists() { return Some(p); }
    }
    // 6. Search PATH
    if let Ok(path_var) = std::env::var("PATH") {
        for dir in path_var.split(';') {
            let p = Path::new(dir.trim()).join("ollama.exe");
            if p.exists() { return Some(p.to_string_lossy().to_string()); }
        }
    }
    None
}

/// Shared helper: fetch model names from Ollama (one HTTP call)
async fn fetch_model_names() -> Result<Vec<String>, String> {
    let r = QUICK_CLIENT.get(format!("{}/api/tags", OLLAMA_BASE)).send().await
        .map_err(|e| e.to_string())?;
    if !r.status().is_success() { return Err("AI engine API returned non-200".into()); }
    let tags: OllamaTagsResp = r.json().await.map_err(|e| e.to_string())?;
    Ok(tags.models.into_iter().map(|m| m.name).collect())
}

/// Auto-select the best available model — called on startup
#[tauri::command]
pub async fn auto_select_model() -> Result<String, String> {
    let names = fetch_model_names().await.unwrap_or_default();
    if names.is_empty() { return Ok(DEFAULT_MODEL.to_string()); }
    // Pick the first preferred model that's actually installed
    for pref in PREFERRED_MODELS {
        let prefix = pref.split(':').next().unwrap_or("");
        if let Some(matched) = names.iter().find(|n| *n == pref || n.starts_with(&format!("{}:", prefix))) {
            return Ok(matched.clone());
        }
    }
    Ok(names.into_iter().next().unwrap_or_else(|| DEFAULT_MODEL.to_string()))
}

// ============================================================================
// Settings persistence (#3/#12)
// ============================================================================

fn settings_path(app: &AppHandle) -> std::path::PathBuf {
    let dir = app.path().app_data_dir().unwrap_or_else(|_| std::path::PathBuf::from("C:\\ViberizeDesktop"));
    if !dir.exists() { let _ = std::fs::create_dir_all(&dir); }
    dir.join("viberize-settings.json")
}

#[tauri::command]
pub async fn load_settings(app: AppHandle) -> Result<String, String> {
    let p = settings_path(&app);
    if p.exists() {
        tokio::fs::read_to_string(&p).await.map_err(|e| e.to_string())
    } else {
        Ok("{}".to_string())
    }
}

#[tauri::command]
pub async fn save_settings(app: AppHandle, settings_json: String) -> Result<(), String> {
    let p = settings_path(&app);
    tokio::fs::write(&p, &settings_json).await.map_err(|e| e.to_string())
}

// ============================================================================
// Model & health
// ============================================================================

#[tauri::command]
pub async fn get_available_models() -> Result<Vec<String>, String> {
    let names = fetch_model_names().await.unwrap_or_default();
    Ok(if names.is_empty() { vec![DEFAULT_MODEL.into()] } else { names })
}

#[tauri::command]
pub async fn check_ollama_health() -> Result<bool, String> {
    Ok(QUICK_CLIENT.get(format!("{}/", OLLAMA_BASE)).send().await
        .map(|r| r.status().is_success()).unwrap_or(false))
}

/// Web search via DuckDuckGo HTML — no API key needed, with validation layer
#[tauri::command]
pub async fn web_search_ddg(query: String) -> Result<String, String> {
    if query.trim().is_empty() {
        return Err("Search query is empty".into());
    }

    // Use DuckDuckGo HTML endpoint (no API key, no JS required)
    let url = format!("https://html.duckduckgo.com/html/?q={}", urlencoding(query.trim()));
    let resp = QUICK_CLIENT.get(&url)
        .header("User-Agent", "Viberize/1.0")
        .send().await
        .map_err(|e| format!("Web search failed: {}", e))?;

    if !resp.status().is_success() {
        return Err(format!("Web search HTTP {}", resp.status()));
    }

    let html = resp.text().await.map_err(|e| e.to_string())?;

    // Parse search results from DuckDuckGo HTML
    // Results are in <a class="result__a"> tags with snippets in <a class="result__snippet">
    let mut results: Vec<(String, String, String)> = Vec::new(); // (title, url, snippet)

    // Simple HTML parsing — find result blocks
    for block in html.split("class=\"result__body\"") {
        if results.len() >= 5 { break; }
        // Extract title
        let title = extract_between(block, "class=\"result__a\"", "</a>")
            .map(|s| strip_html_tags(&s))
            .unwrap_or_default();
        // Extract URL
        let url = extract_between(block, "class=\"result__url\"", "</a>")
            .map(|s| strip_html_tags(&s).trim().to_string())
            .unwrap_or_default();
        // Extract snippet
        let snippet = extract_between(block, "class=\"result__snippet\"", "</a>")
            .map(|s| strip_html_tags(&s))
            .unwrap_or_default();

        if !title.is_empty() && !snippet.is_empty() {
            results.push((title, url, snippet));
        }
    }

    if results.is_empty() {
        return Err("No search results found".into());
    }

    // ── Validation layer: cross-reference and quality check ──
    // 1. Remove duplicate/near-duplicate snippets
    let mut seen_snippets: Vec<String> = Vec::new();
    let mut validated: Vec<(String, String, String)> = Vec::new();
    for (title, url, snippet) in &results {
        let normalized = snippet.to_lowercase();
        let is_dup = seen_snippets.iter().any(|s| {
            // Check if >60% of words overlap (near-duplicate detection)
            let words_a: std::collections::HashSet<&str> = normalized.split_whitespace().collect();
            let words_b: std::collections::HashSet<&str> = s.split_whitespace().collect();
            if words_a.is_empty() || words_b.is_empty() { return false; }
            let overlap = words_a.intersection(&words_b).count();
            (overlap as f64 / words_a.len().min(words_b.len()) as f64) > 0.6
        });
        if !is_dup {
            seen_snippets.push(normalized);
            validated.push((title.clone(), url.clone(), snippet.clone()));
        }
    }

    // 2. Build context with source attribution (helps LLM distinguish facts from claims)
    let mut context = String::from("[Web Search Results — use these as reference, cite sources when possible]\n");
    for (i, (title, url, snippet)) in validated.iter().enumerate() {
        // Truncate snippets to prevent single source from dominating
        let safe_snippet = if snippet.len() > 400 { &snippet[..400] } else { snippet.as_str() };
        context.push_str(&format!("\nSource {}: {} ({})\n{}\n", i + 1, title, url, safe_snippet));
    }
    context.push_str("\n[End of Web Search Results — if search results conflict, note the disagreement]\n");
    Ok(context)
}

// Helper: URL-encode a string (minimal, for query params)
fn urlencoding(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(b as char),
            b' ' => out.push('+'),
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}

// Helper: extract text between a marker and end tag
fn extract_between(html: &str, start_marker: &str, end_tag: &str) -> Option<String> {
    let start = html.find(start_marker)?;
    let after_marker = &html[start + start_marker.len()..];
    // Skip to after the first '>'
    let content_start = after_marker.find('>')? + 1;
    let content = &after_marker[content_start..];
    let end = content.find(end_tag)?;
    Some(content[..end].to_string())
}

// Helper: strip HTML tags from a string
fn strip_html_tags(s: &str) -> String {
    let mut out = String::new();
    let mut in_tag = false;
    for c in s.chars() {
        match c {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => out.push(c),
            _ => {}
        }
    }
    // Decode common HTML entities
    out.replace("&amp;", "&")
       .replace("&lt;", "<")
       .replace("&gt;", ">")
       .replace("&quot;", "\"")
       .replace("&#x27;", "'")
       .replace("&nbsp;", " ")
       .trim()
       .to_string()
}

/// Quick mode: improve the prompt (non-streaming, returns improved text)
#[tauri::command]
pub async fn improve_prompt(prompt: String, model: String) -> Result<String, String> {
    let m = if model.trim().is_empty() { DEFAULT_MODEL.to_string() } else { model };
    validate_model_name(&m)?;

    let sys = "You are an expert prompt engineer. Your job is to improve the user's prompt to get better results from an AI. \
               Return ONLY the improved prompt text, nothing else. No explanations, no preamble, no quotes around it. \
               Just the improved prompt ready to be sent to an AI.";

    let payload = serde_json::json!({
        "model": m, "prompt": prompt, "system": sys, "stream": false,
        "options": { "num_predict": 512, "temperature": 0.6 }
    });

    let resp = QUICK_CLIENT
        .post(format!("{}/api/generate", OLLAMA_BASE))
        .json(&payload).send().await
        .map_err(|e| format!("Prompt improvement failed: {}", e))?;

    if !resp.status().is_success() {
        return Err(format!("AI engine returned HTTP {}", resp.status()));
    }

    let body: serde_json::Value = resp.json().await.map_err(|e| e.to_string())?;
    let improved = body.get("response")
        .and_then(|r| r.as_str())
        .unwrap_or("")
        .trim()
        .to_string();

    if improved.is_empty() {
        Ok(prompt) // fallback to original if improvement is empty
    } else {
        Ok(improved)
    }
}
'@ -Label "commands.rs"


Write-FileAlways "$TAURI_DIR\tauri.conf.json" @'
{
  "productName": "Viberize Desktop",
  "version": "1.0.0",
  "identifier": "com.viberize.desktop",
  "build": {
    "beforeDevCommand":   "npm run dev",
    "beforeBuildCommand": "npm run build",
    "devUrl":             "http://localhost:1420",
    "frontendDist":       "../dist"
  },
  "bundle": {
    "active":   true,
    "targets":  "all",
    "icon": [
      "icons/32x32.png","icons/128x128.png",
      "icons/128x128@2x.png","icons/icon.icns","icons/icon.ico"
    ],
    "resources": [],
    "externalBin": [],
    "windows": {
      "webviewInstallMode": { "type": "embedBootstrapper" },
      "nsis": {
        "installerIcon": "icons/icon.ico",
        "headerImage": null,
        "sidebarImage": null,
        "installMode": "both",
        "displayLanguageSelector": false
      }
    }
  },
  "app": {
    "windows": [{
      "label":      "main",
      "title":      "Viberize Desktop",
      "width":       480,
      "height":      850,
      "resizable":   true,
      "fullscreen":  false,
      "decorations": true
    }],
    "security": {
      "csp": "default-src 'self'; connect-src 'self' http://127.0.0.1:11434; img-src 'self' data:; style-src 'self' 'unsafe-inline'; font-src 'self'; script-src 'self'"
    }
  },
  "plugins": {}
}
'@ -Label "tauri.conf.json"


# ── Tauri 2.x capabilities (required for plugin permissions) ──────────────────
Ensure-Dir "$TAURI_DIR\capabilities"
Write-FileAlways "$TAURI_DIR\capabilities\default.json" @'
{
  "identifier": "default",
  "description": "Default capabilities for Viberize Desktop",
  "windows": ["main"],
  "permissions": [
    "core:default",
    "dialog:default",
    "dialog:allow-open",
    "dialog:allow-save",
    "dialog:allow-message",
    "dialog:allow-ask",
    "fs:default",
    "fs:allow-read",
    "fs:allow-write",
    "fs:allow-read-text-file",
    "fs:allow-write-text-file",
    "fs:allow-exists",
    "fs:allow-mkdir",
    "shell:default",
    "shell:allow-open"
  ]
}
'@ -Label "capabilities/default.json (plugin permissions)"

# ── Tauri icons — generated from real logo.png ─────────────────────────────────
# Uses C:\ViberizeDesktop\assets\logo.png as source. Falls back to placeholder "V"
# if logo.png is not present. Generates all sizes Tauri needs for Windows.
$iconsDir = "$TAURI_DIR\icons"
if (-not (Test-Path $iconsDir -EA SilentlyContinue)) {
    New-Item -ItemType Directory $iconsDir -Force | Out-Null
}

$logoSrc = "$ROOT\assets\logo.png"
$hasLogo = Test-Path $logoSrc -EA SilentlyContinue

if ($hasLogo) {
    Write-ACT "Generating Tauri icons from real logo..."
} else {
    Write-WARN "No logo.png in $ROOT\assets — generating placeholder icons"
    Write-INFO "Place your logo.png in $ROOT\assets\ and re-run this script"
}

try {
    Add-Type -AssemblyName System.Drawing

    # Helper: create icon at target size from logo or placeholder
    function New-IconBitmap {
        param([int]$Size)
        $bmp = New-Object System.Drawing.Bitmap($Size, $Size)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

        if ($script:hasLogoImg) {
            $g.Clear([System.Drawing.Color]::Transparent)
            $g.DrawImage($script:logoImg, 0, 0, $Size, $Size)
        } else {
            $g.Clear([System.Drawing.Color]::FromArgb(7, 7, 7))
            $fs = [Math]::Floor($Size * 0.55)
            $font = New-Object System.Drawing.Font("Segoe UI", $fs, [System.Drawing.FontStyle]::Bold)
            $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(242, 242, 242))
            $sf = New-Object System.Drawing.StringFormat
            $sf.Alignment = [System.Drawing.StringAlignment]::Center
            $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
            $g.DrawString("V", $font, $brush, (New-Object System.Drawing.RectangleF(0,0,$Size,$Size)), $sf)
            $font.Dispose(); $brush.Dispose(); $sf.Dispose()
        }
        $g.Dispose()
        return $bmp
    }

    # Load source logo if available
    $script:hasLogoImg = $false
    $script:logoImg = $null
    if ($hasLogo) {
        try {
            # Load into memory stream so file is not locked
            $logoBytes = [System.IO.File]::ReadAllBytes($logoSrc)
            $logoMs = New-Object System.IO.MemoryStream(,$logoBytes)
            $script:logoImg = [System.Drawing.Image]::FromStream($logoMs)
            $script:hasLogoImg = $true
            Write-OK "Logo loaded: $($script:logoImg.Width)x$($script:logoImg.Height)"
        } catch {
            Write-WARN "Could not load logo.png: $_ — using placeholder"
        }
    }

    # Generate PNGs: 32x32, 128x128
    foreach ($size in @(32, 128)) {
        $pngPath = "$iconsDir\${size}x${size}.png"
        $bmp = New-IconBitmap $size
        $bmp.Save($pngPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        Write-OK "Generated ${size}x${size}.png$(if ($script:hasLogoImg) { ' (from logo)' })"
    }

    # Generate 128x128@2x.png (= 256x256)
    $bmp256 = New-IconBitmap 256
    $bmp256.Save("$iconsDir\128x128@2x.png", [System.Drawing.Imaging.ImageFormat]::Png)
    Write-OK "Generated 128x128@2x.png$(if ($script:hasLogoImg) { ' (from logo)' })"

    # Generate icon.ico from 256x256 bitmap
    $ms = New-Object System.IO.MemoryStream
    $bmp256.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $pngBytes = $ms.ToArray()
    $ms.Dispose()
    $bmp256.Dispose()

    $icoMs = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($icoMs)
    $bw.Write([UInt16]0)     # reserved
    $bw.Write([UInt16]1)     # type: ICO
    $bw.Write([UInt16]1)     # count: 1 image
    $bw.Write([byte]0)       # width (0 = 256)
    $bw.Write([byte]0)       # height (0 = 256)
    $bw.Write([byte]0)       # color palette
    $bw.Write([byte]0)       # reserved
    $bw.Write([UInt16]1)     # color planes
    $bw.Write([UInt16]32)    # bits per pixel
    $bw.Write([UInt32]$pngBytes.Length)
    $bw.Write([UInt32]22)    # offset
    $bw.Write($pngBytes)
    $bw.Flush()
    [System.IO.File]::WriteAllBytes("$iconsDir\icon.ico", $icoMs.ToArray())
    $bw.Dispose(); $icoMs.Dispose()
    Write-OK "Generated icon.ico$(if ($script:hasLogoImg) { ' (from logo)' })"

    # Cleanup loaded image
    if ($script:logoImg) { $script:logoImg.Dispose() }

} catch {
    Write-WARN "Icon generation failed: $_ — creating minimal fallback"
    $minIco = [byte[]]@(0,0,1,0,1,0,1,1,0,0,1,0,32,0,40,0,0,0,22,0,0,0,
        40,0,0,0,1,0,0,0,2,0,0,0,1,0,32,0,0,0,0,0,4,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
        7,7,7,255,0,0,0,0)
    [System.IO.File]::WriteAllBytes("$iconsDir\icon.ico", $minIco)
}

Write-OK "Tauri icons directory ready"


# ── Inject logo base64 into Navbar.tsx and favicon into index.html ────────────
$logoSrc = "$ROOT\assets\logo.png"
if (Test-Path $logoSrc -EA SilentlyContinue) {
    # Read logo, resize to 44x44 for navbar (keeps base64 small ~3-5KB)
    try {
        Add-Type -AssemblyName System.Drawing
        $logoBytes = [System.IO.File]::ReadAllBytes($logoSrc)
        $logoMs = New-Object System.IO.MemoryStream(,$logoBytes)
        $srcImg = [System.Drawing.Image]::FromStream($logoMs)

        # 44px version for navbar (renders at 22px, 2x for retina)
        $navBmp = New-Object System.Drawing.Bitmap(44, 44)
        $g = [System.Drawing.Graphics]::FromImage($navBmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.DrawImage($srcImg, 0, 0, 44, 44)
        $g.Dispose()

        $navMs = New-Object System.IO.MemoryStream
        $navBmp.Save($navMs, [System.Drawing.Imaging.ImageFormat]::Png)
        $navB64 = [Convert]::ToBase64String($navMs.ToArray())
        $navMs.Dispose(); $navBmp.Dispose()

        # 32px version for favicon
        $favBmp = New-Object System.Drawing.Bitmap(32, 32)
        $g = [System.Drawing.Graphics]::FromImage($favBmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.DrawImage($srcImg, 0, 0, 32, 32)
        $g.Dispose()

        $favMs = New-Object System.IO.MemoryStream
        $favBmp.Save($favMs, [System.Drawing.Imaging.ImageFormat]::Png)
        $favB64 = [Convert]::ToBase64String($favMs.ToArray())
        $favMs.Dispose(); $favBmp.Dispose()

        $srcImg.Dispose(); $logoMs.Dispose()

        # Inject into Navbar.tsx
        $navbarPath = "$COMPONENTS\Navbar.tsx"
        if (Test-Path $navbarPath -EA SilentlyContinue) {
            $content = [System.IO.File]::ReadAllText($navbarPath)
            $content = $content.Replace("__LOGO_BASE64__", $navB64)
            [System.IO.File]::WriteAllText($navbarPath, $content, $script:UTF8NoBOM)
            Write-OK "Navbar.tsx: logo base64 injected ($('{0:N0}' -f $navB64.Length) chars)"
        }

        # Inject into index.html
        $indexPath = "$APP\index.html"
        if (Test-Path $indexPath -EA SilentlyContinue) {
            $content = [System.IO.File]::ReadAllText($indexPath)
            $content = $content.Replace("__FAVICON_HREF__", "data:image/png;base64,$favB64")
            [System.IO.File]::WriteAllText($indexPath, $content, $script:UTF8NoBOM)
            Write-OK "index.html: favicon injected"
        }

        # Also copy logo to public/ for Vite (accessible as /logo.png at runtime)
        $publicDir = "$APP\public"
        if (-not (Test-Path $publicDir -EA SilentlyContinue)) {
            New-Item -ItemType Directory $publicDir -Force | Out-Null
        }
        Copy-Item $logoSrc "$publicDir\logo.png" -Force
        Write-OK "Logo copied to public/logo.png (Vite static asset)"

    } catch {
        Write-WARN "Logo injection failed: $_ — UI will use SVG fallback"
    }
} else {
    Write-INFO "No logo.png in $ROOT\assets — Navbar will use SVG fallback"
    # Clean up placeholders so fallback SVG activates
    $indexPath = "$APP\index.html"
    if (Test-Path $indexPath -EA SilentlyContinue) {
        $content = [System.IO.File]::ReadAllText($indexPath)
        $content = $content.Replace('<link rel="icon" type="image/png" href="__FAVICON_HREF__" />', '')
        [System.IO.File]::WriteAllText($indexPath, $content, $script:UTF8NoBOM)
    }
}


Write-FileIfMissing "$TAURI_DIR\rag_folders.json" @'
{
  "folders": [
    {"id":"f1","label":"RAG Folder 1","path":"","enabled":false,"recursive":true},
    {"id":"f2","label":"RAG Folder 2","path":"","enabled":false,"recursive":true},
    {"id":"f3","label":"RAG Folder 3","path":"","enabled":false,"recursive":false}
  ]
}
'@ -Label "rag_folders.json"

# Icon status
Ensure-Dir "$TAURI_DIR\icons"
if (Test-Path "$TAURI_DIR\icons\icon.ico" -EA SilentlyContinue) {
    Write-OK "Tauri icons: ready"
} else {
    Write-WARN "Icons not generated yet — re-run this script after placing logo.png in $ROOT\assets\"
}

# =============================================================================
Write-HEAD "STEP 11: SIGNING KEYS"
# =============================================================================

$privKey = "$UPDATE_DIR\signing_private.key"
$pubKey  = "$UPDATE_DIR\signing_public.key"
if ((Test-Path $privKey -EA SilentlyContinue) -and (Test-Path $pubKey -EA SilentlyContinue)) {
    $kc = try { Get-Content $pubKey -Raw } catch { "" }
    if ($kc -notmatch "PLACEHOLDER") { Write-SKIP "Real signing key pair exists" }
    else { Write-WARN "Placeholder keys -- replace with: cargo tauri signer generate" }
} else {
    $generated = $false
    try {
        & cargo tauri signer generate -w "$privKey" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-OK "Signing keys generated"; $generated = $true }
    } catch {}
    if (-not $generated) {
        "PLACEHOLDER_PRIVATE_KEY" | Set-Content $privKey -Encoding UTF8
        "PLACEHOLDER_PUBLIC_KEY"  | Set-Content $pubKey  -Encoding UTF8
        Write-WARN "Placeholder keys -- replace with: cargo tauri signer generate -w $privKey"
    }
}
$mfPath = "$UPDATE_DIR\update_manifest.json"
if (-not (Test-Path $mfPath -EA SilentlyContinue)) {
    @{ version="1.0.0"; releaseDate=(Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"); notes="Initial" } |
        ConvertTo-Json | Set-Content $mfPath -Encoding UTF8
    Write-OK "Update manifest created"
}

# =============================================================================
Write-HEAD "STEP 12: SECURITY NOTE"
# =============================================================================
# v7: Firewall management REMOVED at user request.
# Ollama is bound to 127.0.0.1:11434 (loopback) via OLLAMA_HOST -- not reachable
# from LAN or internet. Your Windows Firewall rules are NOT touched by this script.
Write-OK "Ollama security: loopback-only (127.0.0.1:11434) -- zero LAN/internet exposure"
Write-OK "Firewall: not managed by this script -- your existing rules are unchanged"


# =============================================================================
Write-HEAD "SOURCE SCAFFOLD COMPLETE"
# =============================================================================

Write-Host ""
Write-Host "+==================================================================+" -ForegroundColor Green
Write-Host "|   SOURCE FILES WRITTEN                                           |" -ForegroundColor Green
Write-Host "+==================================================================+" -ForegroundColor Green
Write-Host ""
Write-Host "  All .tsx, .rs, .toml, .json, and config files are in place." -ForegroundColor White
Write-Host "  NEXT STEP: Run 4-Install-Dependencies.ps1" -ForegroundColor Yellow
Write-Host ""

# ── Mark step complete ──────────────────────────────────────────────────────
Set-StepComplete "scaffold-source"
Save-Log "Scaffold-Source"
Write-OK "All source files written. Run Install-Dependencies.ps1 next."
