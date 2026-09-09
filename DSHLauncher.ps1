#Requires -Version 5.1
# ============================================================
#  DeepSeek Harness 启动器 (dsh-launcher)
#  功能: 检测 / 启动 / 重启 / 升级 / 自动安装 DeepSeek Harness (dsh)
#  依赖: Node.js (v22.19+), 由 npm 全局安装 @deepseek-ai/dsh
# ============================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Auto)]
public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
'@

$ErrorActionPreference = 'SilentlyContinue'

# ---------------- 路径解析 ----------------
function Resolve-NodeNpm {
    $candidates = @()
    if ($env:ProgramFiles) { $candidates += "$env:ProgramFiles\nodejs\npm.cmd" }
    $candidates += "$env:ProgramFiles(x86)\nodejs\npm.cmd"
    $g = Get-Command npm -ErrorAction SilentlyContinue
    if ($g) { $candidates += $g.Source }
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

function Resolve-NodeExe {
    $candidates = @()
    if ($env:ProgramFiles) { $candidates += "$env:ProgramFiles\nodejs\node.exe" }
    $candidates += "$env:ProgramFiles(x86)\nodejs\node.exe"
    $g = Get-Command node -ErrorAction SilentlyContinue
    if ($g) { $candidates += $g.Source }
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

function Resolve-DshCmd {
    $candidates = @()
    # 优先 npm 实际全局安装目录（npm install -g 的写入位置，升级后保持一致）
    $g = Get-Command npm -ErrorAction SilentlyContinue
    if ($g) {
        $prefix = (& $g.Source config get prefix 2>$null | Select-Object -First 1)
        if ($prefix) { $candidates += (Join-Path ($prefix.Trim()) 'dsh.cmd') }
    }
    if ($env:ProgramFiles) { $candidates += "$env:ProgramFiles\nodejs\dsh.cmd" }
    $g2 = Get-Command dsh -ErrorAction SilentlyContinue
    if ($g2) { $candidates += $g2.Source }
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

# ---------------- 版本获取 ----------------
function Get-NodeVersion {
    if (-not $script:nodeExe) { return '未检测到' }
    $v = & $script:nodeExe --version 2>$null | Select-Object -First 1
    if ($v) { return ($v -join '').Trim() } else { return '读取失败' }
}

function Get-DshVersion {
    if (-not $script:dshCmd) { return '未安装' }
    $v = & $script:dshCmd --version 2>$null | Select-Object -First 1
    if ($v) { return ($v -join '').Trim() } else { return '读取失败' }
}

function Get-LatestVersion {
    if (-not $script:npmCmd) { return '未知' }
    $v = & $script:npmCmd view @deepseek-ai/dsh version 2>$null | Select-Object -First 1
    if ($v) { return ($v -join '').Trim() } else { return '未知' }
}

function Test-NodeCompat {
    $nv = Get-NodeVersion
    if ($nv -notmatch '^v?(\d+)\.(\d+)') { return $false }
    $major = [int]$Matches[1]; $minor = [int]$Matches[2]
    return (($major -gt 22) -or ($major -eq 22 -and $minor -ge 19))
}

# ---------------- 后台任务 ----------------
$script:bgJob = $null      # 安装/升级任务
$script:latestJob = $null  # 最新版本查询任务
$script:bgLabel = ''
$script:autoLaunch = $false
$script:expectedVersion = $null
$script:launcherDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:pidFile = Join-Path $script:launcherDir 'dsh.pid'
$script:dshPid = $null

function Invoke-NpmAsync([string[]]$npmArgs, [string]$label) {
    if (-not $script:npmCmd) {
        $script:log.AppendText("`r`n>>> 错误: 未找到 npm 命令，请先安装 Node.js`r`n")
        [System.Windows.Forms.MessageBox]::Show('未找到 npm 命令，请先安装 Node.js (https://nodejs.org)', 'DSH 启动器', 'OK', 'Warning') | Out-Null
        return
    }
    $script:bgLabel = $label
    Set-ButtonsEnabled $false
    $script:log.AppendText("`r`n>>> $label ...`r`n")
    $script:bgJob = Start-Job -ScriptBlock {
        param($npm, $node, $argsArr, $wd)
        $nodeDir = Split-Path -Parent $node
        $env:PATH = "$nodeDir;$env:PATH"
        Set-Location $wd
        $out = & $npm @argsArr 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message }
            else { $_ }
        } | Out-String
        $code = $LASTEXITCODE
        return "EXITCODE=$code`r`n$out"
    } -ArgumentList $script:npmCmd, $script:nodeExe, $npmArgs, (Get-Location).Path
}

function Refresh-LatestAsync {
    if ($script:latestJob) { return }
    if (-not $script:npmCmd) { $script:lblLatest.Text = '最新版本: 未知'; return }
    $script:lblLatest.Text = '最新版本: 检查中...'
    $script:latestJob = Start-Job -ScriptBlock {
        param($npm, $node)
        $nodeDir = Split-Path -Parent $node
        $env:PATH = "$nodeDir;$env:PATH"
        $v = & $npm view @deepseek-ai/dsh version 2>$null
        return ($v | Out-String).Trim()
    } -ArgumentList $script:npmCmd, $script:nodeExe
}

# ---------------- 状态刷新 ----------------
function Refresh-Status {
    # 安装/升级完成后重新探测环境，确保 dshCmd 等路径为最新
    $script:npmCmd = Resolve-NodeNpm
    $script:nodeExe = Resolve-NodeExe
    $script:dshCmd = Resolve-DshCmd
    $nv = Get-NodeVersion
    $script:lblNode.Text = "Node.js:  $nv"
    if ($nv -notmatch '^v?(\d+)\.(\d+)') {
        $script:lblNode.ForeColor = [System.Drawing.Color]::OrangeRed
    } else {
        $major = [int]$Matches[1]; $minor = [int]$Matches[2]
        if (($major -gt 22) -or ($major -eq 22 -and $minor -ge 19)) {
            $script:lblNode.ForeColor = [System.Drawing.Color]::Green
        } else {
            $script:lblNode.ForeColor = [System.Drawing.Color]::OrangeRed
        }
    }
    $dv = Get-DshVersion
    $script:lblDsh.Text = "DSH:  $dv"
    if ($dv -eq '未安装') { $script:lblDsh.ForeColor = [System.Drawing.Color]::OrangeRed }
    else { $script:lblDsh.ForeColor = [System.Drawing.Color]::Green }
    Refresh-LatestAsync
}

function Set-ButtonsEnabled([bool]$enabled) {
    $script:btnStart.Enabled = $enabled
    $script:btnRestart.Enabled = $enabled
    $script:btnUpgrade.Enabled = $enabled
    $script:btnQuit.Enabled = $enabled
}

# ---------------- 启动 / 升级 ----------------
function Launch-DshWeb {
    if (-not $script:nodeExe) {
        [System.Windows.Forms.MessageBox]::Show('未检测到 Node.js，无法启动 dsh。请先安装 Node.js。', 'DSH 启动器', 'OK', 'Warning') | Out-Null
        return
    }
    if (-not (Test-NodeCompat)) {
        [System.Windows.Forms.MessageBox]::Show("当前 Node.js 版本过低 ($(Get-NodeVersion))，`r`nDeepSeek Harness 需要 Node.js v22.19+。`r`n请升级 Node.js 后再启动。", 'DSH 启动器', 'OK', 'Warning') | Out-Null
        return
    }
    $nodeDir = Split-Path -Parent $script:nodeExe
    $inner = "`$Host.UI.RawUI.WindowTitle = 'dsh web (DSH Launcher)'; `$env:PATH = '$nodeDir;' + `$env:PATH; & '$($script:dshCmd)' web"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc) -PassThru
    $script:dshPid = $p.Id
    try { Set-Content -Path $script:pidFile -Value $p.Id -Encoding ascii } catch { }
    $script:log.AppendText("`r`n>>> 已启动 dsh web（PID $($p.Id)），关闭该窗口即可停止服务。`r`n")
}

function Start-Dsh {
    if (-not $script:dshCmd) {
        if (-not $script:nodeExe) {
            [System.Windows.Forms.MessageBox]::Show('未检测到 Node.js。DeepSeek Harness 依赖 Node.js (v22.19+)，`r`n请先到 https://nodejs.org 安装后，再重新打开本工具。', 'DSH 启动器', 'OK', 'Warning') | Out-Null
            return
        }
        $r = [System.Windows.Forms.MessageBox]::Show("未检测到 DeepSeek Harness (dsh)。`r`n是否立即自动安装？`r`n（将执行: npm install -g @deepseek-ai/dsh）", 'DSH 启动器', 'YesNo', 'Question')
        if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
            $script:autoLaunch = $true
            Invoke-NpmAsync @('-g', 'install', '@deepseek-ai/dsh') '正在安装 DeepSeek Harness'
        }
        return
    }
    if (-not (Test-NodeCompat)) {
        [System.Windows.Forms.MessageBox]::Show("当前 Node.js 版本过低 ($(Get-NodeVersion))，`r`nDeepSeek Harness 需要 Node.js v22.19+。`r`n请升级 Node.js 后再启动。", 'DSH 启动器', 'OK', 'Warning') | Out-Null
        return
    }
    Launch-DshWeb
}

function Update-Dsh {
    if (-not $script:dshCmd) {
        $r = [System.Windows.Forms.MessageBox]::Show("未检测到 DeepSeek Harness (dsh)。`r`n是否立即自动安装？", 'DSH 启动器', 'YesNo', 'Question')
        if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
            if (-not $script:nodeExe) {
                [System.Windows.Forms.MessageBox]::Show('未检测到 Node.js，请先安装 Node.js 后再试。', 'DSH 启动器', 'OK', 'Warning') | Out-Null
                return
            }
            $script:autoLaunch = $false
            Invoke-NpmAsync @('-g', 'install', '@deepseek-ai/dsh') '正在安装 DeepSeek Harness'
        }
        return
    }
    $script:log.AppendText("`r`n>>> 正在检查最新版本...`r`n")
    [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
    $latest = Get-LatestVersion
    [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
    $installed = Get-DshVersion
    if ($latest -and $latest -notin @('', '未知', '读取失败') -and $latest -eq $installed) {
        $script:log.AppendText(">>> 当前已是最新版本 $latest`r`n")
        [System.Windows.Forms.MessageBox]::Show("当前已是最新版本: $latest", 'DSH 启动器', 'OK', 'Information') | Out-Null
        return
    }
    $msg = "将升级 DSH 到最新版本。`r`n当前版本: $installed`r`n最新版本: $latest`r`n`r`n提示: 请先关闭正在运行的 dsh 窗口，避免文件被占用。是否继续？"
    $r = [System.Windows.Forms.MessageBox]::Show($msg, '升级 DSH', 'YesNo', 'Warning')
    if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
        $script:autoLaunch = $false
        # 显式指定版本 + 强制在线校验，避免 npm 本地缓存/镜像延迟导致 @latest 解析到旧版
        if ($latest -and $latest -notin @('', '未知', '读取失败')) {
            $script:expectedVersion = $latest
            Invoke-NpmAsync @('-g', 'install', '--prefer-online', "@deepseek-ai/dsh@$latest") '正在升级 DeepSeek Harness'
        } else {
            Invoke-NpmAsync @('-g', 'install', '--prefer-online', '@deepseek-ai/dsh@latest') '正在升级 DeepSeek Harness'
        }
    }
}

# ---------------- 停止 / 重启 ----------------
function Test-DshRunning {
    if (Test-Path $script:pidFile) {
        $saved = (Get-Content $script:pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($saved -and $saved.Trim() -match '^\d+$' -and (Get-Process -Id ([int]$saved.Trim()) -ErrorAction SilentlyContinue)) {
            return $true
        }
    }
    $hits = Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match '@deepseek-ai\\dsh' }
    return [bool]$hits
}

function Stop-Dsh {
    $stopped = $false
    $targetPid = $null
    if (Test-Path $script:pidFile) {
        $saved = (Get-Content $script:pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($saved -and $saved.Trim() -match '^\d+$') { $targetPid = [int]$saved.Trim() }
    }
    # 1) 优雅关闭 dsh 窗口（按唯一窗口标题 FindWindow + WM_CLOSE，等同点窗口 X）
    $hwnd = [Win32.NativeMethods]::FindWindow($null, 'dsh web (DSH Launcher)')
    if ($hwnd -ne [IntPtr]::Zero) {
        [void][Win32.NativeMethods]::PostMessage($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
        $script:log.AppendText(">>> 已向 dsh 窗口发送关闭请求，等待退出...`r`n")
        $deadline = (Get-Date).AddSeconds(8)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 500
            $left = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match '@deepseek-ai\\dsh' })
            $winAlive = if ($targetPid) { [bool](Get-Process -Id $targetPid -ErrorAction SilentlyContinue) } else { $false }
            if ($left.Count -eq 0 -and -not $winAlive) { break }
        }
        $stopped = $true
    }
    # 2) 若窗口进程仍存活 → 强杀进程树
    if ($targetPid -and (Get-Process -Id $targetPid -ErrorAction SilentlyContinue)) {
        & taskkill.exe /PID $targetPid /T /F 2>$null | Out-Null
        $stopped = $true
    }
    # 3) 兜底: 清理残留的 dsh node 进程
    $hits = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match '@deepseek-ai\\dsh' })
    foreach ($h in $hits) {
        & taskkill.exe /PID $h.ProcessId /T /F 2>$null | Out-Null
        $stopped = $true
    }
    Start-Sleep -Milliseconds 500
    $left = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match '@deepseek-ai\\dsh' })
    if ($left.Count -gt 0) {
        $script:log.AppendText(">>> 注意: 仍有 dsh 进程未能停止`r`n")
    } elseif ($stopped) {
        $script:log.AppendText(">>> dsh 已停止`r`n")
    } else {
        $script:log.AppendText(">>> 未发现正在运行的 dsh`r`n")
    }
    try { if (Test-Path $script:pidFile) { Remove-Item $script:pidFile -Force -ErrorAction SilentlyContinue } } catch { }
    $script:dshPid = $null
    return $stopped
}

function Restart-Dsh {
    $script:log.AppendText("`r`n>>> 正在重启 dsh...`r`n")
    Stop-Dsh | Out-Null
    Start-Sleep -Milliseconds 800
    if (-not $script:dshCmd) {
        Start-Dsh   # 未安装时走自动安装流程
    } else {
        Launch-DshWeb
    }
}

# ---------------- UI 构建 ----------------
$script:npmCmd = Resolve-NodeNpm
$script:nodeExe = Resolve-NodeExe
$script:dshCmd = Resolve-DshCmd

$form = New-Object System.Windows.Forms.Form
$form.Text = 'DeepSeek Harness 启动器'
$form.ClientSize = New-Object System.Drawing.Size(520, 480)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::White

# 标题
$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = 'DeepSeek Harness 启动器'
$lblTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 16, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(46, 72, 108)
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object System.Drawing.Point(20, 12)
$form.Controls.Add($lblTitle)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = '检测 / 启动 / 重启 / 升级 DeepSeek Harness (dsh)'
$lblSub.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$lblSub.ForeColor = [System.Drawing.Color]::Gray
$lblSub.AutoSize = $true
$lblSub.Location = New-Object System.Drawing.Point(22, 46)
$form.Controls.Add($lblSub)

# 状态组
$grp = New-Object System.Windows.Forms.GroupBox
$grp.Text = '环境状态'
$grp.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
$grp.Location = New-Object System.Drawing.Point(20, 72)
$grp.Size = New-Object System.Drawing.Size(480, 84)
$form.Controls.Add($grp)

function New-StatusLabel($x, $y, $text) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $l.AutoSize = $true
    $l.Location = New-Object System.Drawing.Point($x, $y)
    return $l
}

$script:lblNode   = New-StatusLabel 14 22 'Node.js:  检测中...'
$script:lblDsh    = New-StatusLabel 14 48 'DSH:      检测中...'
$script:lblLatest = New-StatusLabel 270 22 '最新版本: 检查中...'
$grp.Controls.Add($script:lblNode)
$grp.Controls.Add($script:lblDsh)
$grp.Controls.Add($script:lblLatest)

# 日志
$script:log = New-Object System.Windows.Forms.TextBox
$script:log.Multiline = $true
$script:log.ReadOnly = $true
$script:log.ScrollBars = 'Vertical'
$script:log.WordWrap = $false
$script:log.BackColor = [System.Drawing.Color]::FromArgb(28, 30, 34)
$script:log.ForeColor = [System.Drawing.Color]::FromArgb(178, 226, 157)
$script:log.BorderStyle = 'FixedSingle'
$script:log.Font = New-Object System.Drawing.Font('Consolas', 9)
$script:log.Location = New-Object System.Drawing.Point(20, 170)
$script:log.Size = New-Object System.Drawing.Size(480, 180)
$form.Controls.Add($script:log)

# 按钮
$script:btnStart = New-Object System.Windows.Forms.Button
$script:btnStart.Text = '启动 DSH'
$script:btnStart.Size = New-Object System.Drawing.Size(112, 44)
$script:btnStart.Location = New-Object System.Drawing.Point(20, 368)
$script:btnStart.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
$script:btnStart.BackColor = [System.Drawing.Color]::FromArgb(24, 160, 110)
$script:btnStart.ForeColor = [System.Drawing.Color]::White
$script:btnStart.FlatStyle = 'Flat'
$script:btnStart.Add_Click({ Start-Dsh })
$form.Controls.Add($script:btnStart)

$script:btnRestart = New-Object System.Windows.Forms.Button
$script:btnRestart.Text = '重启 DSH'
$script:btnRestart.Size = New-Object System.Drawing.Size(112, 44)
$script:btnRestart.Location = New-Object System.Drawing.Point(142, 368)
$script:btnRestart.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
$script:btnRestart.BackColor = [System.Drawing.Color]::FromArgb(46, 134, 222)
$script:btnRestart.ForeColor = [System.Drawing.Color]::White
$script:btnRestart.FlatStyle = 'Flat'
$script:btnRestart.Add_Click({ Restart-Dsh })
$form.Controls.Add($script:btnRestart)

$script:btnUpgrade = New-Object System.Windows.Forms.Button
$script:btnUpgrade.Text = '升级 DSH'
$script:btnUpgrade.Size = New-Object System.Drawing.Size(112, 44)
$script:btnUpgrade.Location = New-Object System.Drawing.Point(264, 368)
$script:btnUpgrade.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
$script:btnUpgrade.BackColor = [System.Drawing.Color]::FromArgb(230, 126, 34)
$script:btnUpgrade.ForeColor = [System.Drawing.Color]::White
$script:btnUpgrade.FlatStyle = 'Flat'
$script:btnUpgrade.Add_Click({ Update-Dsh })
$form.Controls.Add($script:btnUpgrade)

$script:btnQuit = New-Object System.Windows.Forms.Button
$script:btnQuit.Text = '退出'
$script:btnQuit.Size = New-Object System.Drawing.Size(112, 44)
$script:btnQuit.Location = New-Object System.Drawing.Point(386, 368)
$script:btnQuit.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11)
$script:btnQuit.BackColor = [System.Drawing.Color]::FromArgb(120, 126, 132)
$script:btnQuit.ForeColor = [System.Drawing.Color]::White
$script:btnQuit.FlatStyle = 'Flat'
$script:btnQuit.Add_Click({ $form.Close() })
$form.Controls.Add($script:btnQuit)

$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Text = '提示: 「重启 DSH」会先停止正在运行的 dsh 再重新启动；未安装时点击「启动 DSH」会自动安装。'
$lblHint.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
$lblHint.ForeColor = [System.Drawing.Color]::Gray
$lblHint.AutoSize = $true
$lblHint.Location = New-Object System.Drawing.Point(20, 425)
$form.Controls.Add($lblHint)

# ---------------- 定时器（轮询后台任务） ----------------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 250
$timer.Add_Tick({
    if ($script:bgJob) {
        if ($script:bgJob.State -eq 'Completed') {
            $out = (Receive-Job $script:bgJob -Keep | Out-String).Trim()
            Remove-Job $script:bgJob -Force
            $script:bgJob = $null
            $script:log.AppendText("$out`r`n")
            if ($out -match '(?m)^EXITCODE=0') {
                $script:log.AppendText(">>> $($script:bgLabel) 成功`r`n")
                Refresh-Status
                if ($script:expectedVersion) {
                    $now = Get-DshVersion
                    if ($now -eq $script:expectedVersion) {
                        $script:log.AppendText(">>> 版本校验通过: $now`r`n")
                    } else {
                        $script:log.AppendText(">>> 注意: 当前版本仍是 $now（期望 $($script:expectedVersion)），`r`n>>> 可能是 npm 镜像缓存延迟导致未真正升级，请稍后重试。`r`n")
                    }
                    $script:expectedVersion = $null
                }
                if ($script:autoLaunch) {
                    $script:autoLaunch = $false
                    Start-Dsh
                }
            } else {
                $script:log.AppendText(">>> $($script:bgLabel) 失败，请查看上方错误输出`r`n")
                $script:autoLaunch = $false
            }
            Set-ButtonsEnabled $true
        } elseif ($script:bgJob.State -eq 'Failed') {
            $out = (Receive-Job $script:bgJob -Keep | Out-String).Trim()
            Remove-Job $script:bgJob -Force
            $script:bgJob = $null
            $script:log.AppendText("$out`r`n>>> $($script:bgLabel) 异常失败`r`n")
            $script:autoLaunch = $false
            Set-ButtonsEnabled $true
        }
    }
    if ($script:latestJob) {
        if ($script:latestJob.State -eq 'Completed') {
            $v = (Receive-Job $script:latestJob -Keep | Out-String).Trim()
            Remove-Job $script:latestJob -Force
            $script:latestJob = $null
            if ($v) { $script:lblLatest.Text = "最新版本: $v" }
        }
    }
})
$timer.Start()

$form.Add_FormClosed({
    if ($script:bgJob) { Stop-Job $script:bgJob -ErrorAction SilentlyContinue; Remove-Job $script:bgJob -Force -ErrorAction SilentlyContinue }
    if ($script:latestJob) { Stop-Job $script:latestJob -ErrorAction SilentlyContinue; Remove-Job $script:latestJob -Force -ErrorAction SilentlyContinue }
    $timer.Stop()
})

# 初始状态
$form.Add_Shown({
    Refresh-Status
    if (-not $script:dshCmd) {
        $script:log.AppendText(">>> 未检测到 DeepSeek Harness (dsh)，点击「启动 DSH」可自动安装。`r`n")
    } else {
        if (Test-DshRunning) {
            $script:log.AppendText(">>> DeepSeek Harness 已就绪，且检测到 dsh 正在运行，可使用「重启 DSH」。`r`n")
        } else {
            $script:log.AppendText(">>> DeepSeek Harness 已就绪，点击「启动 DSH」开始。`r`n")
        }
    }
})

[void]$form.ShowDialog()
