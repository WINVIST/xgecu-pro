param(
    [string]$ScratchRoot = $(if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() })
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

if ($env:OS -ne 'Windows_NT') { throw 'The Windows extractor must be built on Windows.' }
$cmake = (Get-Command cmake -ErrorAction Stop).Source
$version = '3.8.10'
$sourceUrl = "https://github.com/libarchive/libarchive/releases/download/v$version/libarchive-$version.zip"
$sourceSha256 = 'a15b2890f31c935e5fb5b4026e0c463ed03e87fa6365060659e761e97f401183'
$scratch = Join-Path $ScratchRoot ('xgecu-libarchive-' + [guid]::NewGuid().ToString('N'))
$archive = Join-Path $scratch "libarchive-$version.zip"
$sourceParent = Join-Path $scratch 'source'
$source = Join-Path $sourceParent "libarchive-$version"
$build = Join-Path $scratch 'build'
$utf8 = [System.Text.UTF8Encoding]::new($false)
New-Item -ItemType Directory -Path $scratch | Out-Null

# The digest pins the official GitHub release asset before any source is used.
Invoke-WebRequest -Uri $sourceUrl -OutFile $archive -TimeoutSec 180
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sourceSha256) {
    throw 'The libarchive source archive does not match its pinned SHA-256.'
}
Expand-Archive -LiteralPath $archive -DestinationPath $sourceParent

# Upstream's MSVC target merges this manifest. Keep its privilege and long-path
# settings; UTF-8 avoids locale-dependent failures on unselected RAR filenames.
$manifestPath = Join-Path $source 'tar\bsdtar.exe.manifest'
$manifest = [System.Xml.XmlDocument]::new()
$manifest.PreserveWhitespace = $true
$manifest.Load($manifestPath)
$namespaces = [System.Xml.XmlNamespaceManager]::new($manifest.NameTable)
$namespaces.AddNamespace('asm', 'urn:schemas-microsoft-com:asm.v1')
$namespaces.AddNamespace('v3', 'urn:schemas-microsoft-com:asm.v3')
$namespaces.AddNamespace('ws', 'http://schemas.microsoft.com/SMI/2016/WindowsSettings')
if ($manifest.SelectSingleNode('//v3:requestedExecutionLevel', $namespaces).GetAttribute('level') -ne 'asInvoker' -or
    $manifest.SelectSingleNode('//ws:longPathAware', $namespaces).InnerText -ne 'true') {
    throw 'The upstream application manifest lacks the expected privilege/long-path settings.'
}
$windowsSettings = $manifest.SelectSingleNode('/asm:assembly/v3:application/v3:windowsSettings', $namespaces)
if ($null -eq $windowsSettings) { throw 'The upstream application manifest has no windowsSettings.' }
$codePage = $manifest.CreateElement('activeCodePage', 'http://schemas.microsoft.com/SMI/2019/WindowsSettings')
$codePage.InnerText = 'UTF-8'
$windowsSettings.AppendChild($codePage) | Out-Null
$writerSettings = [System.Xml.XmlWriterSettings]::new()
$writerSettings.Encoding = $utf8
$writer = [System.Xml.XmlWriter]::Create($manifestPath, $writerSettings)
try { $manifest.Save($writer) } finally { $writer.Dispose() }

$definitions = @(
    '-DBUILD_SHARED_LIBS=OFF', '-DENABLE_TAR=ON', '-DENABLE_TAR_SHARED=OFF',
    '-DENABLE_TEST=OFF', '-DENABLE_CPIO=OFF', '-DENABLE_CAT=OFF', '-DENABLE_UNZIP=OFF',
    '-DENABLE_CNG=ON', '-DCMAKE_POLICY_DEFAULT_CMP0091=NEW',
    '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded', '-DMSVC_USE_STATIC_CRT=ON', '-DCMAKE_C_FLAGS=/utf-8'
)
foreach ($feature in @('ZLIB', 'BZip2', 'LZMA', 'ZSTD', 'LZ4', 'LZO', 'OPENSSL', 'NETTLE',
    'MBEDTLS', 'LIBB2', 'LIBXML2', 'BSDXML', 'EXPAT', 'WIN32_XMLLITE', 'PCREPOSIX', 'PCRE2POSIX', 'ICONV', 'MD', 'LIBGCC')) {
    $definitions += "-DENABLE_$feature=OFF"
}
& $cmake -S $source -B $build -A x64 @definitions
if ($LASTEXITCODE -ne 0) { throw "libarchive CMake configuration failed ($LASTEXITCODE)." }
& $cmake --build $build --config Release --target bsdtar --parallel
if ($LASTEXITCODE -ne 0) { throw "libarchive bsdtar build failed ($LASTEXITCODE)." }
$built = Join-Path $build 'bin\Release\bsdtar.exe'
if (-not (Test-Path -LiteralPath $built -PathType Leaf)) { throw "bsdtar was not produced at $built" }
& $built --version
if ($LASTEXITCODE -ne 0) { throw "The built bsdtar did not start ($LASTEXITCODE)." }

$stage = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src-tauri\resources\tools'))
$notices = Join-Path $stage 'notices'
New-Item -ItemType Directory -Path $notices -Force | Out-Null
Copy-Item -LiteralPath $built -Destination (Join-Path $stage 'bsdtar.exe')
Copy-Item -LiteralPath (Join-Path $source 'COPYING') -Destination (Join-Path $notices 'COPYING.txt')

# COPYING identifies source-specific terms as controlling. Include the leading
# notices from the library and command sources, including the UC Regents terms.
$sourceNotices = [System.Text.StringBuilder]::new()
foreach ($directory in @('libarchive', 'libarchive_fe', 'tar')) {
    foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $source $directory) -File | Sort-Object Name)) {
        if ($file.Extension -notin @('.c', '.h')) { continue }
        $header = [regex]::Match([System.IO.File]::ReadAllText($file.FullName), '\A(?:\s*/\*[\s\S]*?\*/|\s*//[^\r\n]*)*').Value.Trim()
        if ($header) { [void]$sourceNotices.AppendLine("$directory/$($file.Name)`n$header`n") }
    }
}
[System.IO.File]::WriteAllText((Join-Path $notices 'SOURCE-NOTICES.txt'), $sourceNotices.ToString(), $utf8)
$provenance = [ordered]@{
    name = 'bsdtar / libarchive'; version = $version; sourceUrl = $sourceUrl; sourceSha256 = $sourceSha256
    binarySha256 = (Get-FileHash -LiteralPath $built -Algorithm SHA256).Hash.ToLowerInvariant()
    sourceChanges = @('tar/bsdtar.exe.manifest: add activeCodePage UTF-8; retain asInvoker and longPathAware')
    configuration = $definitions
    licenses = 'See COPYING.txt and SOURCE-NOTICES.txt. BLAKE2 reference code is used under its CC0 option.'
}
[System.IO.File]::WriteAllText((Join-Path $notices 'PROVENANCE.json'), ($provenance | ConvertTo-Json -Depth 4) + "`n", $utf8)
if ($env:GITHUB_PATH) { [System.IO.File]::AppendAllText($env:GITHUB_PATH, "$stage`n", $utf8) }
if ($env:GITHUB_ENV) { [System.IO.File]::AppendAllText($env:GITHUB_ENV, "XGECU_EXTRACTOR_BUILD_PATH=$stage`n", $utf8) }
Write-Output "Staged bsdtar $version and license/source notices at $stage"
