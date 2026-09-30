<#
.SYNOPSIS
下载并安装指定版本的 Zig，把它的目录追加到 GITHUB_PATH。

.DESCRIPTION
CI 上装 Zig 只需解压一个 zip。版本号是硬约束：build.zig 与 src-zig 都按 Zig 0.16 的 API 写，
不锁版本迟早会在某次 CI 里换到破坏性更新的 0.17。
下载地址从 ziglang.org 的 index.json 取（而不是拼文件名），并校验其 sha256。
#>
param(
    [Parameter(Mandatory)][string]$Version
)

$ErrorActionPreference = 'Stop'

$index = Invoke-RestMethod -Uri 'https://ziglang.org/download/index.json'
$entry = $index.$Version.'x86_64-windows'
if ($null -eq $entry) { throw "ziglang.org 的 index.json 里没有 $Version 的 x86_64-windows 产物。" }

$archive = Join-Path $env:RUNNER_TEMP "zig-$Version.zip"
Invoke-WebRequest -Uri $entry.tarball -OutFile $archive
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
if ($hash -ne $entry.shasum) { throw "Zig $Version 的 sha256 不匹配：$hash != $($entry.shasum)" }

$root = Join-Path $env:RUNNER_TEMP "zig-$Version"
if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
Expand-Archive -LiteralPath $archive -DestinationPath $root
$exe = Get-ChildItem -LiteralPath $root -Recurse -Filter 'zig.exe' | Select-Object -First 1
if ($null -eq $exe) { throw "解压后的 Zig $Version 里没有 zig.exe。" }

& $exe.FullName version
if ($LASTEXITCODE -ne 0) { throw 'zig.exe 无法运行。' }
$exe.Directory.FullName | Out-File -FilePath $env:GITHUB_PATH -Append -Encoding utf8
Write-Host "Zig $Version 已安装到 $($exe.Directory.FullName)"
