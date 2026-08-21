#Requires -Version 5.1
<#
.SYNOPSIS
    IME Lock 的環境自檢與自動安裝啟動器。

.DESCRIPTION
    依序做四件事：
      1. 找出這台機器上可用的 Python（版本夠新、而且 import 得到 tkinter）
      2. 找不到就自動安裝 —— 優先用 winget，失敗才退回官網安裝檔
      3. 若專案有 requirements.txt，就把裡面的套件裝好
      4. 把結果寫進 .ime-lock-python 快取，讓 run.bat 下次能直接啟動

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File bootstrap.ps1
    只檢查環境並回報，不啟動程式。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File bootstrap.ps1 -Launch
    檢查完直接啟動 IME Lock。
#>
[CmdletBinding()]
param(
    # 檢查通過後啟動 ime_lock.pyw
    [switch]$Launch,
    # 以系統管理員身分啟動主程式（搭配 -Launch）
    [switch]$Elevated,
    # 忽略快取，強制重新偵測並重裝相依套件
    [switch]$Force,
    # 只偵測不安裝，缺東西就直接回報失敗
    [switch]$NoInstall
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest 的進度條會拖慢下載

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$AppScript = Join-Path $ScriptDir 'ime_lock.pyw'
$CacheFile = Join-Path $ScriptDir '.ime-lock-python'
$StampFile = Join-Path $ScriptDir '.ime-lock-deps'
$ReqFile   = Join-Path $ScriptDir 'requirements.txt'

$MinPython = [version]'3.8'
# winget 的套件 id 綁小版號，所以列一串由新到舊，裝得起來哪個算哪個
$WingetIds = @('Python.Python.3.14', 'Python.Python.3.13', 'Python.Python.3.12')
# 官網目錄抓不到時的保底版本（每個都會先用 HEAD 確認檔案真的存在）
$FallbackVersions = @('3.13.5', '3.12.10', '3.11.9')

$script:SawPythonWithoutTk = $false
$script:ProbePath = $null


# ---------------------------------------------------------------- 輸出小工具

function Write-Step { param([string]$Message) Write-Host "[*] $Message" -ForegroundColor Cyan }
function Write-Good { param([string]$Message) Write-Host "[+] $Message" -ForegroundColor Green }
function Write-Note { param([string]$Message) Write-Host "[!] $Message" -ForegroundColor Yellow }
function Write-Bad  { param([string]$Message) Write-Host "[x] $Message" -ForegroundColor Red }


# ---------------------------------------------------------------- Python 偵測

# 探針：印出版本、有沒有 tkinter、以及真正的直譯器路徑。
# 寫成暫存檔再餵給直譯器，省得跟 PowerShell 的引號跳脫規則纏鬥。
$ProbeSource = @'
import sys
try:
    import tkinter
    tk = "1"
except Exception:
    tk = "0"
print("PROBE|%d.%d.%d|%s|%s" % (
    sys.version_info[0], sys.version_info[1], sys.version_info[2], tk, sys.executable))
'@

function Get-ProbeFile {
    if ($script:ProbePath -and (Test-Path $script:ProbePath)) { return $script:ProbePath }
    $script:ProbePath = Join-Path ([IO.Path]::GetTempPath()) ("ime_lock_probe_{0}.py" -f $PID)
    [IO.File]::WriteAllText($script:ProbePath, $ProbeSource, (New-Object Text.UTF8Encoding $false))
    return $script:ProbePath
}

function Remove-ProbeFile {
    if ($script:ProbePath) {
        try { Remove-Item $script:ProbePath -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Test-PythonExe {
    <#
      跑一次探針。可用就回傳 Path / Version / Tkinter，否則回 $null。
      注意只能餵 python.exe 或 py.exe：pythonw.exe 沒有主控台，print 不出東西。
    #>
    param([string]$Exe, [string[]]$Prefix = @())

    if (-not $Exe) { return $null }
    try {
        $argList = @()
        if ($Prefix.Count -gt 0) { $argList += $Prefix }
        $argList += (Get-ProbeFile)

        $out = & $Exe @argList 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }

        $line = $out | Where-Object { $_ -like 'PROBE|*' } | Select-Object -First 1
        if (-not $line) { return $null }

        $parts = $line.Split('|')
        if ($parts.Count -lt 4) { return $null }

        return [pscustomobject]@{
            Path    = $parts[3]
            Version = [version]$parts[1]
            Tkinter = ($parts[2] -eq '1')
        }
    } catch {
        return $null
    }
}

function Get-PythonCandidates {
    <# 由可靠到勉強，列出所有值得一試的直譯器。 #>
    $found = New-Object System.Collections.ArrayList

    # 1) 官方啟動器最準，它自己知道所有已註冊的版本
    $py = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($py) { [void]$found.Add(@{ Exe = $py.Source; Prefix = @('-3') }) }

    # 2) PATH 上的 python.exe
    foreach ($cmd in @(Get-Command python.exe -All -ErrorAction SilentlyContinue)) {
        if (-not $cmd.Source) { continue }
        # Microsoft Store 的執行別名是 0 byte 的重解析點，執行它只會跳出商店頁面
        try {
            if ((Get-Item $cmd.Source -ErrorAction Stop).Length -eq 0) { continue }
        } catch { continue }
        [void]$found.Add(@{ Exe = $cmd.Source; Prefix = @() })
    }

    # 3) 登錄檔裡註冊過的安裝位置（沒加進 PATH 的也找得到）
    $hives = @(
        'HKCU:\SOFTWARE\Python\PythonCore',
        'HKLM:\SOFTWARE\Python\PythonCore',
        'HKLM:\SOFTWARE\WOW6432Node\Python\PythonCore'
    )
    foreach ($hive in $hives) {
        if (-not (Test-Path $hive)) { continue }
        foreach ($key in @(Get-ChildItem $hive -ErrorAction SilentlyContinue)) {
            $ip = Get-ItemProperty (Join-Path $key.PSPath 'InstallPath') -ErrorAction SilentlyContinue
            if (-not $ip) { continue }
            $root = $ip.'(default)'
            if (-not $root) { continue }
            $exe = Join-Path $root 'python.exe'
            if (Test-Path $exe) { [void]$found.Add(@{ Exe = $exe; Prefix = @() }) }
        }
    }

    # 4) 常見的安裝路徑，最後補一槍
    $globs = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python3*\python.exe'),
        'C:\Python3*\python.exe',
        (Join-Path $env:ProgramFiles 'Python3*\python.exe')
    )
    foreach ($glob in $globs) {
        foreach ($item in @(Get-ChildItem $glob -ErrorAction SilentlyContinue)) {
            [void]$found.Add(@{ Exe = $item.FullName; Prefix = @() })
        }
    }

    return $found
}

function Resolve-Python {
    <# 回傳第一個版本夠新又有 tkinter 的直譯器。 #>
    $seen = @{}
    foreach ($candidate in Get-PythonCandidates) {
        $key = $candidate.Exe.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true

        $info = Test-PythonExe -Exe $candidate.Exe -Prefix $candidate.Prefix
        if (-not $info) { continue }

        # 不同的候選路徑常常指向同一個直譯器（例如 py.exe 和 PATH 上的 python.exe），
        # 解析出真實路徑後再去重一次，才不會把同一份安裝重複回報
        $realKey = $info.Path.ToLowerInvariant()
        if ($seen.ContainsKey($realKey)) { continue }
        $seen[$realKey] = $true

        if ($info.Version -lt $MinPython) {
            Write-Note "略過 $($info.Path)：版本 $($info.Version) 低於需求 $MinPython"
            continue
        }
        if (-not $info.Tkinter) {
            Write-Note "略過 $($info.Path)：這個 Python 沒有 tkinter"
            $script:SawPythonWithoutTk = $true
            continue
        }
        return $info
    }
    return $null
}

function Get-PythonwPath {
    <# GUI 程式要用 pythonw.exe 才不會拖一個黑色主控台視窗。 #>
    param([string]$PythonExe)
    $pyw = Join-Path (Split-Path -Parent $PythonExe) 'pythonw.exe'
    if (Test-Path $pyw) { return $pyw }
    return $PythonExe
}


# ---------------------------------------------------------------- 安裝 Python

function Update-SessionPath {
    <# 裝完之後，讓目前這個行程也看得到新的 PATH。 #>
    $parts = @(
        [Environment]::GetEnvironmentVariable('Path', 'Machine'),
        [Environment]::GetEnvironmentVariable('Path', 'User')
    ) | Where-Object { $_ }
    if ($parts) { $env:Path = $parts -join ';' }
}

function Install-PythonWithWinget {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-Note '這台機器沒有 winget'
        return $false
    }

    # 先試使用者範圍（不需要 UAC），全部失敗再試預設範圍
    foreach ($userScope in @($true, $false)) {
        foreach ($id in $WingetIds) {
            $scopeLabel = 'default'
            if ($userScope) { $scopeLabel = 'user' }
            Write-Step "winget 安裝 $id（scope=$scopeLabel）..."

            $argList = @(
                'install', '--id', $id, '--exact', '--source', 'winget', '--silent',
                '--accept-package-agreements', '--accept-source-agreements'
            )
            if ($userScope) { $argList += @('--scope', 'user') }

            & $winget.Source @argList
            if ($LASTEXITCODE -eq 0) {
                Write-Good "$id 安裝完成"
                return $true
            }
            Write-Note "$id 沒裝成功（結束碼 $LASTEXITCODE）"
        }
    }
    return $false
}

function Get-PythonInstallerUrl {
    # 64 位元是 -amd64、ARM 是 -arm64，32 位元則完全沒有後綴
    $arch = $env:PROCESSOR_ARCHITEW6432
    if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
    $suffix = ''
    if ($arch -eq 'AMD64') { $suffix = '-amd64' }
    elseif ($arch -eq 'ARM64') { $suffix = '-arm64' }

    $versions = @()
    try {
        Write-Step '查詢 python.org 上的可用版本...'
        $index = Invoke-WebRequest -Uri 'https://www.python.org/ftp/python/' -UseBasicParsing -TimeoutSec 20
        $versions = @(
            [regex]::Matches($index.Content, 'href="(3\.\d+\.\d+)/"') |
                ForEach-Object { $_.Groups[1].Value } |
                Sort-Object { [version]$_ } -Descending |
                Select-Object -First 6
        )
    } catch {
        Write-Note "版本清單抓不到（$($_.Exception.Message)），改用內建的保底清單"
    }

    foreach ($version in @($versions + $FallbackVersions | Select-Object -Unique)) {
        $url = "https://www.python.org/ftp/python/$version/python-$version$suffix.exe"
        try {
            $head = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec 15
            if ($head.StatusCode -eq 200) { return $url }
        } catch { }
    }
    return $null
}

function Install-PythonWithInstaller {
    $url = Get-PythonInstallerUrl
    if (-not $url) {
        Write-Bad '找不到可下載的官方安裝檔'
        return $false
    }

    $dest = Join-Path ([IO.Path]::GetTempPath()) (Split-Path $url -Leaf)
    try {
        Write-Step "下載 $url"
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing

        # InstallAllUsers=0 才不會跳 UAC；Include_tcltk=1 是這支程式的關鍵
        Write-Step '安裝中（只裝給目前使用者，不需要系統管理員權限）...'
        $proc = Start-Process -FilePath $dest -Wait -PassThru -ArgumentList @(
            '/quiet',
            'InstallAllUsers=0',
            'PrependPath=1',
            'Include_launcher=1',
            'Include_tcltk=1',
            'Include_pip=1'
        )
        if ($proc.ExitCode -ne 0) {
            Write-Bad "安裝程式回傳結束碼 $($proc.ExitCode)"
            return $false
        }
        Write-Good '官方安裝檔安裝完成'
        return $true
    } catch {
        Write-Bad "安裝失敗：$($_.Exception.Message)"
        return $false
    } finally {
        Remove-Item $dest -Force -ErrorAction SilentlyContinue
    }
}


# ---------------------------------------------------------------- 相依套件

function Install-Requirement {
    <# 目前這支程式只用標準函式庫，這段是為了日後加了 requirements.txt 也不用改啟動流程。 #>
    param([string]$PythonExe)

    if (-not (Test-Path $ReqFile)) {
        Remove-Item $StampFile -Force -ErrorAction SilentlyContinue
        Write-Good '沒有 requirements.txt，只用到標準函式庫'
        return $true
    }

    # 用內容雜湊當戳記，requirements.txt 沒動過就不用每次都叫 pip
    $hash = (Get-FileHash -Algorithm SHA256 -Path $ReqFile).Hash
    if ((-not $Force) -and (Test-Path $StampFile)) {
        $stamp = Get-Content $StampFile -Raw -ErrorAction SilentlyContinue
        if ($stamp -and $stamp.Trim() -eq $hash) {
            Write-Good 'requirements.txt 自上次安裝後沒有變動'
            return $true
        }
    }

    & $PythonExe -m pip --version *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Note '找不到 pip，先跑 ensurepip'
        & $PythonExe -m ensurepip --upgrade
    }

    Write-Step '安裝 requirements.txt 列出的套件...'
    & $PythonExe -m pip install --disable-pip-version-check --no-input -r $ReqFile
    if ($LASTEXITCODE -ne 0) {
        Write-Bad "pip 安裝失敗（結束碼 $LASTEXITCODE）"
        return $false
    }

    Set-Content -Path $StampFile -Value $hash -Encoding ascii
    Write-Good '相依套件安裝完成'
    return $true
}


# ---------------------------------------------------------------- 主流程

function Invoke-Main {
    Write-Host ''
    Write-Host '=== IME Lock 環境檢查 ===' -ForegroundColor White

    if ($env:OS -ne 'Windows_NT') {
        Write-Bad 'IME Lock 只能在 Windows 上執行'
        return 1
    }

    $osName = 'Windows'
    try {
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
        if ($cv.ProductName) { $osName = $cv.ProductName }
        # Windows 11 的 ProductName 到現在還寫著 Windows 10，只有組建號分得出來
        $build = 0
        if ($cv.CurrentBuildNumber) { [void][int]::TryParse($cv.CurrentBuildNumber, [ref]$build) }
        if ($build -ge 22000) { $osName = $osName -replace 'Windows 10', 'Windows 11' }
        if ($build -gt 0) { $osName = "$osName (build $build)" }
    } catch { }
    $arch = $env:PROCESSOR_ARCHITEW6432
    if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
    Write-Step "系統：$osName / $arch"

    if (-not (Test-Path $AppScript)) {
        Write-Bad "找不到主程式：$AppScript"
        return 1
    }

    Write-Step "尋找 Python（需要 $MinPython 以上，且要有 tkinter）..."
    $python = Resolve-Python

    if (-not $python) {
        if ($script:SawPythonWithoutTk) {
            Write-Note '有找到 Python，但都缺 tkinter —— 需要一份含 tcl/tk 的安裝'
        } else {
            Write-Note '這台機器上找不到可用的 Python'
        }

        if ($NoInstall) {
            Write-Bad '指定了 -NoInstall，就此停手'
            return 1
        }

        Write-Step '開始自動安裝 Python...'
        $installed = Install-PythonWithWinget
        if (-not $installed) {
            Write-Note '改用官網安裝檔'
            $installed = Install-PythonWithInstaller
        }
        if (-not $installed) {
            Write-Bad '自動安裝失敗，請自行到 https://www.python.org/downloads/windows/ 安裝（記得勾選 tcl/tk）'
            return 1
        }

        Update-SessionPath
        Write-Step '重新偵測...'
        $python = Resolve-Python
    }

    if (-not $python) {
        Write-Bad '裝完之後還是找不到可用的 Python，請重開一個終端機再試一次'
        return 1
    }

    Write-Good "Python $($python.Version)：$($python.Path)"

    if (-not (Install-Requirement -PythonExe $python.Path)) { return 1 }

    $pythonw = Get-PythonwPath -PythonExe $python.Path
    # 用系統 ANSI 編碼寫檔，run.bat 的 set /p 才讀得到非 ASCII 路徑
    [IO.File]::WriteAllText($CacheFile, $pythonw, [Text.Encoding]::Default)
    Write-Good "環境就緒（啟動器：$pythonw）"

    if (-not $Launch) {
        Write-Host ''
        Write-Host '檢查完成。用 run.bat 啟動 IME Lock。' -ForegroundColor White
        return 0
    }

    Write-Step '啟動 IME Lock...'
    try {
        if ($Elevated) {
            Start-Process -FilePath $pythonw -Verb RunAs -ArgumentList @($AppScript)
        } else {
            Start-Process -FilePath $pythonw -ArgumentList @($AppScript)
        }
    } catch {
        # 使用者在 UAC 對話框按取消也會走到這裡
        Write-Bad "啟動失敗：$($_.Exception.Message)"
        return 1
    }
    return 0
}

try {
    $code = Invoke-Main
} finally {
    Remove-ProbeFile
}
exit $code
