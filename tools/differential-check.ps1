<#
.SYNOPSIS
差分与硬化回归：把 Zig 产物与一份 C++ 基线库放进同一个 JVM 逐字节比对。

.DESCRIPTION
C++ 原版源码已从仓库删除，基线库需要自己准备：
  1) 在 git 历史里找回 C++ 源码：git show <旧提交>:native/src/... ；
  2) 用 zig c++ 编一份（-ffp-contract=off 与原版 CMake 一致）；
  3) 差分语料不包含“对已退役实体发 updateCollisionEntitySection”这一组合——C++ 参考实现会崩溃，
     Zig 侧对该场景的修复由 HardeningProbe 单独回归。

需要 Java 21+（本脚本默认用 PATH 上的 java，可用 -Java 指定）。
#>
param(
    [Parameter(Mandatory)][string]$CppLibrary,
    [Parameter(Mandatory)][string]$ZigLibrary,
    [int[]]$Seeds = @(0, 1, 12345, 987654321),
    [string]$Java = 'java'
)

$ErrorActionPreference = 'Stop'
$harnessDir = $PSScriptRoot

foreach ($seed in $Seeds) {
    Write-Host "== 差分 seed=$seed"
    & $Java --enable-native-access=ALL-UNNAMED (Join-Path $harnessDir 'DifferentialHarness.java') $CppLibrary $ZigLibrary $seed
    if ($LASTEXITCODE -ne 0) { throw "差分比对失败（seed=$seed）。" }
}

Write-Host '== 硬化回归（Zig）'
& $Java --enable-native-access=ALL-UNNAMED (Join-Path $harnessDir 'HardeningProbe.java') $ZigLibrary
if ($LASTEXITCODE -ne 0) { throw '硬化回归失败。' }

Write-Host '== 硬化回归（C++ 基线，预期崩溃）'
# 崩溃判定不能只看退出码：JVM 在原生帧里收到访问违例时也是退出码 1，而断言失败同样是 1。
# 这里认 JVM 的致命错误输出，并在结束后清掉它落在工作目录里的 hs_err 报告。
$before = @(Get-ChildItem -Path . -Filter 'hs_err_pid*.log' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
$crashOutput = (& $Java --enable-native-access=ALL-UNNAMED (Join-Path $harnessDir 'HardeningProbe.java') $CppLibrary --expect-crash 2>&1 | Out-String)
@(Get-ChildItem -Path . -Filter 'hs_err_pid*.log' -ErrorAction SilentlyContinue |
    Where-Object { $before -notcontains $_.Name } |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force })
if ($crashOutput -notmatch 'A fatal error has been detected by the Java Runtime Environment') {
    throw 'C++ 基线未崩溃，说明基线库不是原始实现，或者上游缺陷已被修复。'
}

Write-Host '差分与硬化回归通过。' -ForegroundColor Green
