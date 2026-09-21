<#
.SYNOPSIS
  构建 LanStash Windows 应用，运行单元测试并输出到 dist 目录。
  无需命令行参数，所有打包选项都在交互菜单中选择。

.DESCRIPTION
  交互式打包脚本，参照 macOS 端 package.sh 的风格。
  支持非交互模式，通过环境变量 LANSTASH_NON_INTERACTIVE 控制。
#>

param()

$ErrorActionPreference = 'Stop'

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot    = Resolve-Path "$ScriptDir\.."
$ProductName = 'LanStash'
$DistRoot    = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir 'dist'))
$DistDir     = Join-Path $DistRoot (Get-Date -Format 'yyyyMMdd-HHmmss')
$Solution    = Join-Path $ScriptDir 'LanStash.slnx'
$AppProject  = Join-Path $ScriptDir 'src\LanStash.App\LanStash.App.csproj'
$TestProject = Join-Path $ScriptDir 'tests\LanStash.Tests\LanStash.Tests.csproj'

$Configuration = 'Release'
$TargetPlatform = 'x64'
$RunTests = $true
$SelfContained = $true
$LaunchAfter = $false

function Write-Fail {
    param([string]$Message)
    Write-Host "错误：$Message" -ForegroundColor Red
    exit 1
}

function Ask-Choice {
    param(
        [string]$Title,
        [int]$DefaultChoice,
        [string[]]$Options
    )

    while ($true) {
        Write-Host ""
        Write-Host $Title
        for ($i = 0; $i -lt $Options.Length; $i++) {
            $suffix = ''
            if (($i + 1) -eq $DefaultChoice) { $suffix = ' [默认]' }
            Write-Host ("  {0}) {1}{2}" -f ($i + 1), $Options[$i], $suffix)
        }
        Write-Host -NoNewline "请选择 [$DefaultChoice]，输入 q 可退出："

        $choice = Read-Host
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "$DefaultChoice" }

        if ($choice -eq 'q' -or $choice -eq 'Q') {
            Write-Host "已取消打包。"
            exit 0
        }

        $num = 0
        if ([int]::TryParse($choice, [ref]$num) -and $num -ge 1 -and $num -le $Options.Length) {
            return $num
        }

        Write-Host "输入无效，请输入 1-$($Options.Length)，或输入 q 退出。" -ForegroundColor Red
    }
}

function Configure-Package {
    while ($true) {
        Write-Host ""
        Write-Host "========================================"
        Write-Host "  LanStash Windows 打包工具"
        Write-Host "========================================"
        Write-Host "直接按回车会使用每一步的默认选项。"

        $choice = Ask-Choice "1/4 选择构建类型" 1 @(
            "Release（推荐，运行更快）",
            "Debug（用于开发调试）"
        )
        switch ($choice) {
            1 { $script:Configuration = 'Release' }
            2 { $script:Configuration = 'Debug' }
        }

        $choice = Ask-Choice "2/4 选择目标平台" 1 @(
            "x64（推荐，适用于大多数 Windows 设备）",
            "arm64（适用于 ARM 设备）",
            "同时构建 x64 和 arm64"
        )
        switch ($choice) {
            1 { $script:TargetPlatform = 'x64' }
            2 { $script:TargetPlatform = 'arm64' }
            3 { $script:TargetPlatform = 'both' }
        }

        $choice = Ask-Choice "3/4 是否运行单元测试" 1 @(
            "运行测试（推荐）",
            "跳过测试，直接打包"
        )
        switch ($choice) {
            1 { $script:RunTests = $true }
            2 { $script:RunTests = $false }
        }

        $choice = Ask-Choice "4/4 打包完成后" 1 @(
            "只生成安装包，不启动",
            "直接启动 LanStash"
        )
        switch ($choice) {
            1 { $script:LaunchAfter = $false }
            2 { $script:LaunchAfter = $true }
        }

        Write-Host ""
        Write-Host "打包设置"
        Write-Host "  构建类型：$script:Configuration"
        Write-Host "  目标平台：$script:TargetPlatform"
        if ($script:RunTests) { Write-Host "  单元测试：运行" }
        else { Write-Host "  单元测试：跳过" }
        if ($script:LaunchAfter) { Write-Host "  完成操作：启动应用" }
        else { Write-Host "  完成操作：仅生成安装包" }

        $choice = Ask-Choice "确认以上设置" 1 @(
            "开始打包",
            "重新选择",
            "退出"
        )
        switch ($choice) {
            1 { return }
            2 { continue }
            3 {
                Write-Host "已取消打包。"
                exit 0
            }
        }
    }
}

# ── 非交互模式 ────────────────────────────────────────────
if ($env:LANSTASH_NON_INTERACTIVE) {
    $buildType = if ($env:LANSTASH_BUILD_TYPE) { $env:LANSTASH_BUILD_TYPE } else { 'Release' }
    if ($buildType -notin @('Release', 'Debug')) {
        Write-Fail "不支持的构建类型：$buildType，请使用 Release 或 Debug"
    }
    $script:Configuration = $buildType

    $platform = if ($env:LANSTASH_TARGET_PLATFORM) { $env:LANSTASH_TARGET_PLATFORM } else { 'x64' }
    if ($platform -notin @('x64', 'arm64', 'both')) {
        Write-Fail "不支持的平台：$platform，请使用 x64 / arm64 / both"
    }
    $script:TargetPlatform = $platform

    $runTestsEnv = if ($env:LANSTASH_RUN_TESTS) { $env:LANSTASH_RUN_TESTS } else { '1' }
    if ($runTestsEnv -notin @('0', '1')) {
        Write-Fail "LANSTASH_RUN_TESTS 只能是 0 或 1"
    }
    $script:RunTests = ($runTestsEnv -eq '1')

    $launchEnv = if ($env:LANSTASH_LAUNCH_AFTER) { $env:LANSTASH_LAUNCH_AFTER } else { '0' }
    if ($launchEnv -notin @('0', '1')) {
        Write-Fail "LANSTASH_LAUNCH_AFTER 只能是 0 或 1"
    }
    $script:LaunchAfter = ($launchEnv -eq '1')
} else {
    Configure-Package
}

# 便携包包含既有版本的 .NET 与 Windows App Runtime，不安装或注册系统组件。
if ($env:LANSTASH_SELF_CONTAINED) {
    if ($env:LANSTASH_SELF_CONTAINED -notin @('0', '1')) {
        Write-Fail 'LANSTASH_SELF_CONTAINED 只能是 0 或 1'
    }
    $SelfContained = $env:LANSTASH_SELF_CONTAINED -eq '1'
}
$standaloneValue = $SelfContained.ToString().ToLowerInvariant()

# ── 前置检查 ──────────────────────────────────────────────
if (-not (Test-Path $Solution)) {
    Write-Fail "找不到解决方案文件：$Solution"
}

$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if (-not $dotnet) {
    Write-Fail '未找到 dotnet，请安装 .NET 10 SDK。'
}

# ── 源码信息 ──────────────────────────────────────────────
$gitDir = Join-Path $RepoRoot '.git'
if (Test-Path $gitDir) {
    $sourceCommit = & git -C $RepoRoot rev-parse --verify HEAD 2>$null
    $sourceBranch = & git -C $RepoRoot symbolic-ref --quiet --short HEAD 2>$null
    if (-not $sourceBranch) { $sourceBranch = 'detached' }
    $sourceState = 'clean'
    $dirty = & git -C $RepoRoot status --short 2>$null
    if ($dirty) { $sourceState = '包含未提交改动' }
    $shortCommit = if ($sourceCommit) { $sourceCommit.Substring(0, [Math]::Min(12, $sourceCommit.Length)) } else { 'unknown' }
    Write-Host "==> 源码：$sourceBranch @ $shortCommit（$sourceState）"
}

# ── 读取版本号 ────────────────────────────────────────────
$Version = '0.1.0'
$propsFile = Join-Path $ScriptDir 'Directory.Build.props'
if (Test-Path $propsFile) {
    $propsContent = Get-Content $propsFile -Raw
    if ($propsContent -match '<Version>([^<]+)</Version>') {
        $Version = $Matches[1]
    }
}
Write-Host "==> 版本：$Version"

# ── 恢复依赖 ──────────────────────────────────────────────
Write-Host '==> 恢复 NuGet 依赖'
& dotnet restore $Solution
if ($LASTEXITCODE -ne 0) { Write-Fail '依赖恢复失败。' }

# ── 运行单元测试 ──────────────────────────────────────────
if ($RunTests) {
    Write-Host '==> 运行单元测试'
    & dotnet test $TestProject --configuration Release --no-restore
    if ($LASTEXITCODE -ne 0) { Write-Fail '单元测试失败。' }
    Write-Host '==> 单元测试通过'
}

# ── 构建应用 ──────────────────────────────────────────────
$platforms = @()
if ($TargetPlatform -eq 'both') {
    $platforms = @('x64', 'arm64')
} else {
    $platforms = @($TargetPlatform)
}

if (-not (Test-Path $DistDir)) {
    New-Item -ItemType Directory -Path $DistDir -Force | Out-Null
}

$builtPackages = @()

foreach ($plat in $platforms) {
    $runtime = "win-$plat"
    $configLower = $Configuration.ToLower()
    $outDir = Join-Path $DistDir "$configLower-$plat"

    Write-Host "==> 构建 ${ProductName}（${Configuration}，${plat}）"

    $resolvedOutput = [System.IO.Path]::GetFullPath($outDir)
    if (-not $resolvedOutput.StartsWith($DistRoot + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        Write-Fail '输出路径必须位于 windows/dist 中。'
    }
    if (Test-Path -LiteralPath $resolvedOutput) { Write-Fail '输出目录已存在，请等待一秒后重新打包。' }

    & dotnet publish $AppProject `
        -c $Configuration `
        -r $runtime `
        -p:Platform=$plat `
        -p:LanStashUiSmoke=false `
        --self-contained $standaloneValue `
        -p:LanStashStandalone=$standaloneValue `
        -o $outDir

    if ($LASTEXITCODE -ne 0) { Write-Fail "$Configuration ($plat) 构建失败。" }

    # 资源缺失时不能交付“构建成功但无法启动”的包。
    foreach ($required in @('LanStash.App.exe', 'resources.pri')) {
        if (-not (Test-Path -LiteralPath (Join-Path $outDir $required))) {
            Write-Fail "发布产物缺少必需资源：$required"
        }
    }

    # 查找输出 exe
    $exe = Get-ChildItem -Path $outDir -Filter 'LanStash.App.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exe) {
        $size = '{0:N1} MB' -f ($exe.Length / 1MB)
        Write-Host "==> 构建产物：$($exe.FullName)（$size）"
    }

    @{
        version = $Version
        architecture = $plat
        configuration = $Configuration
        selfContained = $SelfContained
        sourceCommit = $sourceCommit
        sourceState = $sourceState
        testsRun = $RunTests
        createdUtc = [DateTime]::UtcNow.ToString('O')
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outDir 'build-info.json') -Encoding utf8

    # 打包为 zip
    $platLabel = if ($TargetPlatform -eq 'both') { $plat } else { $plat }
    $zipName = "$ProductName-$Version-$platLabel.zip"
    $zipPath = Join-Path $DistDir $zipName

    Write-Host "==> 生成压缩包：$zipName"
    if (Test-Path -LiteralPath $zipPath) { Write-Fail '压缩包已存在，不覆盖既有测试包。' }
    Compress-Archive -Path "$outDir\*" -DestinationPath $zipPath -CompressionLevel Optimal

    (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash | Set-Content -LiteralPath "$zipPath.sha256" -Encoding ascii
    $zipSize = '{0:N1} MB' -f ((Get-Item $zipPath).Length / 1MB)
    Write-Host "==> 压缩包已生成：$zipPath（$zipSize）"

    $builtPackages += [PSCustomObject]@{
        ZipPath = $zipPath
        OutDir = $outDir
        ExePath = if ($exe) { $exe.FullName } else { '' }
        Platform = $plat
    }
}

# 每次使用独立时间目录，保留旧包以便比较和回退。

# ── 启动应用 ──────────────────────────────────────────────
if ($LaunchAfter -and $builtPackages.Count -gt 0) {
    $firstPkg = $builtPackages[0]
    if ($firstPkg.ExePath -and (Test-Path $firstPkg.ExePath)) {
        Write-Host "==> 启动 ${ProductName}（$($firstPkg.Platform)）"
        Start-Process -FilePath $firstPkg.ExePath
    }
}

# ── 完成 ──────────────────────────────────────────────────
Write-Host ""
Write-Host "打包完成："
Write-Host "  版本：$Version"
foreach ($pkg in $builtPackages) {
    Write-Host "  压缩包：$($pkg.ZipPath)"
}
Write-Host "  构建类型：$Configuration"
Write-Host "  目标平台：$TargetPlatform"
