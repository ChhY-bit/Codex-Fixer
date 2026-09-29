param(
    [switch]$Status,
    [switch]$Fix
)
$ErrorActionPreference = 'Stop'

# ============================================================
#  Codex 一站式修复工具
#  问题 1: 代理环境变量 (HTTP_PROXY / HTTPS_PROXY)
#  问题 2: requires_openai_auth 认证模式
#  问题 3: 模型目录 context_window 上下文窗口
# ============================================================

# ---------- 路径解析（跨平台，无绝对路径硬编码） ----------
$homeDir   = if ($env:CODEX_HOME) { $env:CODEX_HOME } elseif ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $homeDir '.codex' }
$configPath = Join-Path $codexHome 'config.toml'
$isWin = ($env:OS -eq 'Windows_NT')
$commonPorts = 7897, 7890, 7891, 7899, 1080, 10808, 2080, 8888

# ---------- 基础工具 ----------
function Read-Raw($p) { if (Test-Path $p) { [IO.File]::ReadAllText($p) } else { $null } }
function Write-Raw($p, $t) { [IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($false))) }
function Pause-It { try { Read-Host '按回车继续' } catch {} }

# ---------- 问题 1: 代理 ----------
function Get-ProxyCandidates {
    $c = New-Object System.Collections.Generic.List[string]
    if ($isWin) {
        try {
            $reg = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
            if ($reg.ProxyEnable -and $reg.ProxyServer -and ($reg.ProxyServer -match '(\d+\.\d+\.\d+\.\d+:\d+)')) { $c.Add($Matches[1]) }
        } catch {}
    }
    $listen = @()
    try { $listen = Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { $_.LocalAddress -in '127.0.0.1','0.0.0.0','::1' } | Select-Object -ExpandProperty LocalPort -Unique } catch {}
    foreach ($port in $listen) { if ($commonPorts -contains $port) { $c.Add("127.0.0.1:$port") } }
    $c | Select-Object -Unique
}

function Invoke-WithSpinner {
    param([string]$Label, [scriptblock]$Work, $ArgumentList = @())
    # 进程内异步 Runspace：无进程创建开销，BeginInvoke 立即返回，动画全程连续
    $ps = [System.Management.Automation.PowerShell]::Create()
    $null = $ps.AddScript($Work.ToString())
    foreach ($a in $ArgumentList) { $null = $ps.AddArgument($a) }
    $handle = $ps.BeginInvoke()
    $frames = @('|', '/', '-', '\')
    $i = 0
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $handle.IsCompleted -and $sw.Elapsed.TotalSeconds -lt 30) {
        Write-Host ("`r  [{0}] $Label {1,5:N1}s " -f $frames[$i % 4], $sw.Elapsed.TotalSeconds) -NoNewline
        Start-Sleep -Milliseconds 120
        $i++
    }
    if (-not $handle.IsCompleted) { $ps.Stop(); $out = $false }
    else {
        $res = @($ps.EndInvoke($handle))
        $out = if ($res.Count -gt 0) { $res[0] } else { $false }
    }
    $ps.Dispose()
    Write-Host ("`r" + (' ' * ($Label.Length + 20)) + "`r") -NoNewline
    $out
}

function Test-Direct {
    Invoke-WithSpinner -Label '直连 api.openai.com' -Work {
        try {
            $tcp = New-Object Net.Sockets.TcpClient
            $ok = $tcp.ConnectAsync('api.openai.com', 443).Wait(5000)
            $tcp.Close(); $ok
        } catch { $false }
    }
}

function Test-ProxyHttp($addr) {
    Invoke-WithSpinner -Label "测试代理 $addr" -Work {
        param($a)
        try {
            $null = Invoke-WebRequest -Uri 'https://api.openai.com/v1/models' -Proxy "http://$a" -TimeoutSec 12 -UseBasicParsing -ErrorAction Stop
            $true
        } catch {
            # 收到任何 HTTP 状态码（401/403/404 等）都说明代理链路已连通
            ($null -ne $_.Exception.Response)
        }
    } -ArgumentList $addr
}

function Set-ProxyEnv($addr) {
    $val = "http://$addr"
    [Environment]::SetEnvironmentVariable('HTTP_PROXY',  $val, 'User')
    [Environment]::SetEnvironmentVariable('HTTPS_PROXY', $val, 'User')
    [Environment]::SetEnvironmentVariable('NO_PROXY', 'localhost,127.0.0.1,::1', 'User')
    $env:HTTP_PROXY = $val; $env:HTTPS_PROXY = $val
    Write-Host "  已写入用户级环境变量: HTTP_PROXY / HTTPS_PROXY = $val"
    Write-Host '  已写入 NO_PROXY = localhost,127.0.0.1,::1'
    if (-not $isWin) { Write-Host '  [提示] 非 Windows 平台若未生效，请在 shell 配置中手动 export' }
}

function Invoke-ProxyFix {
    $cur = [Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'User')
    Write-Host "当前用户级 HTTPS_PROXY: $(if ($cur) { $cur } else { '(未设置)' })"
    if (Test-Direct) { Write-Host '[结果] 可直连 api.openai.com，无需代理，跳过。'; return }
    Write-Host '[检查] 无法直连 api.openai.com，正在探测本地代理端口...'
    $cands = @(Get-ProxyCandidates)
    if (-not $cands) {
        if ($Fix) { Write-Host '[跳过] 未探测到代理端口 (非交互模式)'; return }
        $addr = Read-Host '未探测到常见代理端口，请手动输入代理地址 (如 127.0.0.1:7897，留空跳过)'
        if ($addr) { $cands = @($addr) } else { return }
    }
    $found = $null
    foreach ($c in $cands) { if (Test-ProxyHttp $c) { $found = $c; break } }
    if ($found) { Write-Host "[通过] $found 可访问 OpenAI"; Set-ProxyEnv $found }
    else { Write-Host '[失败] 候选代理均无法访问 OpenAI，请确认代理软件 (Clash 等) 已启动。'; Pause-It }
}

# ---------- 问题 2: 认证模式 ----------
function Get-AuthValue($raw) { if ($raw -match 'requires_openai_auth\s*=\s*(\w+)') { $Matches[1] } else { $null } }

function Invoke-AuthFix([bool]$val) {
    if (-not (Test-Path $configPath)) { Write-Host "[跳过] 找不到 $configPath"; return }
    $v = if ($val) { 'true' } else { 'false' }
    $raw = Read-Raw $configPath
    $cur = Get-AuthValue $raw
    if (-not $cur) { Write-Host '[跳过] config.toml 中没有 requires_openai_auth 字段 (可能当前是官方原生配置)'; return }
    if ($cur -eq $v) { Write-Host "当前值已是 $v，无需修改。"; return }
    Write-Raw $configPath ($raw -replace 'requires_openai_auth\s*=\s*\w+', "requires_openai_auth = $v")
    Write-Host "已将 requires_openai_auth 由 $cur 改为 $v。"
    # ChatGPT 账号模式下第三方模型会被 "not supported with a ChatGPT account" 校验拦截
    $authJson = Join-Path $codexHome 'auth.json'
    $backup   = Join-Path $codexHome 'auth.json.official-backup'
    $disabled = Join-Path $codexHome 'auth.json.disabled'
    if (-not $val) {
        if (Test-Path $authJson) {
            $mode = ''
            try { $mode = (Read-Raw $authJson | ConvertFrom-Json).auth_mode } catch {}
            if ($mode -eq 'chatgpt') {
                Copy-Item $authJson $backup -Force
                Move-Item $authJson $disabled -Force
                Write-Host '已停用 auth.json (ChatGPT 账号模式)，官方登录已备份至 auth.json.official-backup。'
            }
        } elseif (Test-Path $disabled) { Write-Host 'auth.json 已处于停用状态。' }
    } else {
        if ((Test-Path $backup) -and -not (Test-Path $authJson)) {
            Copy-Item $backup $authJson -Force
            Remove-Item $disabled -Force -ErrorAction SilentlyContinue
            Write-Host '已从备份恢复 auth.json (ChatGPT 官方登录)。'
        }
    }
}

# ---------- 问题 3: 上下文窗口 ----------
function Get-CatalogPath {
    $raw = Read-Raw $configPath
    $rel = if ($raw -match 'model_catalog_json\s*=\s*"([^"]+)"') { $Matches[1] } else { 'cc-switch-model-catalog.json' }
    if ([IO.Path]::IsPathRooted($rel)) { $rel } else { Join-Path $codexHome $rel }
}

function Invoke-ContextFix($val = 262144) {
    $p = Get-CatalogPath
    if (-not (Test-Path $p)) { Write-Host "[跳过] 未找到模型目录文件: $p (可能未接入第三方模型)"; return }
    try {
        $j = Read-Raw $p | ConvertFrom-Json
        $n = 0
        foreach ($m in $j.models) { $m.context_window = $val; $m.max_context_window = $val; $n++ }
        Write-Raw $p ($j | ConvertTo-Json -Depth 100)
        Write-Host "已将 $n 个模型的 context_window 调整为 $val。"
    } catch { Write-Host "[错误] 修改模型目录失败: $($_.Exception.Message)" }
}

# ---------- 状态展示 ----------
function Show-Status {
    Write-Host ''
    Write-Host '================ 当前状态 ================'
    Write-Host "Codex 配置目录 : $codexHome"
    if (Test-Path $configPath) {
        $raw = Read-Raw $configPath
        $auth = Get-AuthValue $raw
        $prov = if ($raw -match 'model_provider\s*=\s*"([^"]+)"') { $Matches[1] } else { '(默认官方)' }
        Write-Host "model_provider : $prov"
        Write-Host "认证模式       : requires_openai_auth = $(if ($auth) { $auth } else { '(未设置，官方原生配置)' })"
        $cat = Get-CatalogPath
        if (Test-Path $cat) {
            $j = Read-Raw $cat | ConvertFrom-Json
            $wins = ($j.models | ForEach-Object { "$($_.slug)=$($_.context_window)" }) -join ', '
            Write-Host "上下文窗口     : $wins"
        } else { Write-Host '上下文窗口     : (无模型目录，官方原生配置)' }
    } else { Write-Host 'config.toml    : 不存在' }
    $hp = [Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'User')
    Write-Host "代理环境变量   : HTTPS_PROXY = $(if ($hp) { $hp } else { '(未设置)' })"
    $authJson = Join-Path $codexHome 'auth.json'
    $backup   = Join-Path $codexHome 'auth.json.official-backup'
    $disabled = Join-Path $codexHome 'auth.json.disabled'
    if (Test-Path $authJson) { Write-Host '账号认证       : auth.json 生效中' }
    elseif (Test-Path $disabled) {
        $bk = if (Test-Path $backup) { '，官方登录有备份' } else { '' }
        Write-Host "账号认证       : 已停用 (API Key 模式$bk)"
    }
    else { Write-Host '账号认证       : 无 auth.json' }
    Write-Host '========================================='
}

# ---------- 问题 6: Agent 沙盒 ----------
function Invoke-SandboxFix {
    Write-Host '将执行: 结束 Codex 进程 + 重启沙盒服务 + 清除失败的设置标记'
    $confirm = Read-Host '确认执行? (回车确认 / 输入 n 取消)'
    if ($confirm -eq 'n') { Write-Host '已取消。'; return }
    Write-Host ''
    Stop-Process -Name codex, codex-computer-use-swift -Force -ErrorAction SilentlyContinue
    Start-Sleep 2
    Write-Host '已结束 Codex 进程。'
    $err = Join-Path $codexHome '.sandbox\setup_error.json'
    if (Test-Path $err) { Remove-Item $err -Force; Write-Host '已清除失败的沙盒设置标记 (setup_error.json)。' }
    try {
        Restart-Service 'CodexSandboxService.OpenAI.Codex' -Force -ErrorAction Stop
        Write-Host '已重启沙盒服务。'
    } catch {
        Write-Host '[提示] 沙盒服务重启失败 (需要管理员权限)，跳过。'
    }
    Write-Host ''
    $raw = Read-Raw $configPath
    if ($raw -match '(?m)^\s*sandbox\s*=\s*"elevated"') {
        Write-Host '检测到 sandbox = "elevated" (需管理员提权设置，常被企业 EDR 拦截导致"完成 Windows 设置"失败)。'
        $sub = Read-Host '是否切换为 unelevated 模式 (无需提权，绕过设置向导)? (回车切换 / 输入 n 保留)'
        if ($sub -ne 'n') {
            Write-Raw $configPath ($raw -replace '(?m)^(\s*sandbox\s*=\s*)"elevated"', '$1"unelevated"')
            Write-Host '已切换为 unelevated 模式。'
        }
    }
    Write-Host ''
    Write-Host '完成。请重新打开 Codex。'
    Write-Host '若仍提示"更新 Agent 沙盒": 检查 EDR 安全软件拦截日志，或将 Codex 安装目录加白。'
}

# ---------- 主流程 ----------
if ($Status) { Clear-Host; Show-Status; exit }

if ($Fix) {
    Clear-Host
    Write-Host '注意: -Fix 仅适用于已通过 cc-switch 切换到第三方模型的场景。'
    Write-Host '若要使用官方模型，请运行脚本选 1 设置代理，并选 3 保持/恢复官方模式。'
    Write-Host ''
    Write-Host '--- 步骤 1/3: 网络代理 ---'
    Invoke-ProxyFix
    Write-Host ''; Write-Host '--- 步骤 2/3: 认证模式 (false) ---'
    Invoke-AuthFix $false
    Write-Host ''; Write-Host '--- 步骤 3/3: 上下文窗口 (262144) ---'
    Invoke-ContextFix 262144
    Write-Host ''
    Show-Status
    exit
}

do {
    Clear-Host
    Show-Status
    Write-Host ''
    Write-Host ' 通用 (官方 / 第三方模型都需要):'
    Write-Host '  [1] 检测并设置网络代理  -- Codex 无法联网时用这个'
    Write-Host ''
    Write-Host ' 仅第三方模型需要 (cc-switch 路由):'
    Write-Host '  [2] 第三方模式修复  -- 切到国产模型后 (额度提示/发送失效/GLM报错)'
    Write-Host '  [3] 切回官方模式    -- 恢复 ChatGPT 账号登录'
    Write-Host ''
    Write-Host ' 高级:'
    Write-Host '  [4] 自定义上下文窗口 (默认 256k，报"使用上限"时调小)'
    Write-Host '  [5] 修复 Agent 沙盒   -- 提示"更新 Agent 沙盒以继续/无法发送"时用'
    Write-Host '  [6] 刷新状态'
    Write-Host '  [7] 退出'
    Write-Host ''
    Write-Host ' ! 重要: 会话绑定模型，切走即失效 -- 官方模型的旧对话切国产后无法续用，'
    Write-Host '          请开新对话 (需旧上下文就手动贴关键内容)。详见《Codex修复说明.md》'
    $choice = Read-Host '请输入数字并回车'
    switch ($choice) {
        '1' { Invoke-ProxyFix; Pause-It }
        '2' {
            Write-Host ''
            Write-Host '将执行: 认证模式 false + 停用 auth.json + 上下文窗口 256k'
            Write-Host '适用: 已通过 cc-switch 切换到第三方模型 (qwen/GLM/DeepSeek 等)'
            $confirm = Read-Host '确认执行? (回车确认 / 输入 n 取消)'
            if ($confirm -ne 'n') {
                Invoke-AuthFix $false
                Write-Host ''
                Invoke-ContextFix 262144
                Write-Host ''
                Write-Host '完成。请完全退出 Codex (含托盘) 后重新打开。'
                Write-Host '提醒: 官方模型的旧对话将无法续用，请新建对话开始工作。'
            } else { Write-Host '已取消。' }
            Pause-It
        }
        '3' { Invoke-AuthFix $true; Pause-It }
        '4' {
            $v = Read-Host '上下文窗口 token 数 (直接回车 = 262144)'
            if (-not $v) { $v = 262144 }
            Invoke-ContextFix ([int]$v); Pause-It
        }
        '5' { Invoke-SandboxFix; Pause-It }
        '6' { }
        '7' { exit }
        default { Write-Host '无效输入'; Pause-It }
    }
} while ($true)
