$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path $repositoryRoot '.env.local'
$testFile = Join-Path $repositoryRoot 'db\tests\001_initial_schema.sql'

if (-not (Test-Path -LiteralPath $envFile -PathType Leaf)) {
    throw 'ENV_FILE_NOT_FOUND'
}
if (-not (Test-Path -LiteralPath $testFile -PathType Leaf)) {
    throw 'DATABASE_TEST_FILE_NOT_FOUND'
}

$databaseLine = Get-Content -LiteralPath $envFile |
    Where-Object { $_ -match '^\s*DATABASE_URL\s*=' } |
    Select-Object -First 1
if ($null -eq $databaseLine) {
    throw 'DATABASE_URL_NOT_FOUND'
}

$connectionString = ($databaseLine -replace '^\s*DATABASE_URL\s*=\s*', '').Trim()
if (
    ($connectionString.StartsWith('"') -and $connectionString.EndsWith('"')) -or
    ($connectionString.StartsWith("'") -and $connectionString.EndsWith("'"))
) {
    $connectionString = $connectionString.Substring(1, $connectionString.Length - 2)
}

try {
    $uri = [System.Uri]::new($connectionString)
} catch {
    throw 'DATABASE_URL_INVALID'
}
if ($uri.Scheme -notin @('postgresql', 'postgres')) {
    throw 'DATABASE_URL_SCHEME_INVALID'
}

$userInfo = [System.Uri]::UnescapeDataString($uri.UserInfo)
$separator = $userInfo.IndexOf(':')
if ($separator -lt 1) {
    throw 'DATABASE_URL_CREDENTIALS_MISSING'
}

$env:PGUSER = $userInfo.Substring(0, $separator)
$env:PGPASSWORD = $userInfo.Substring($separator + 1)
$env:PGHOST = $uri.DnsSafeHost
$env:PGPORT = if ($uri.IsDefaultPort) { '5432' } else { [string]$uri.Port }
$env:PGDATABASE = [System.Uri]::UnescapeDataString($uri.AbsolutePath.TrimStart('/'))

$query = [System.Uri]::UnescapeDataString($uri.Query.TrimStart('?'))
if ($query -match '(?:^|&)sslmode=([^&]+)') {
    $env:PGSSLMODE = $Matches[1]
}

$psql = Get-Command psql -ErrorAction SilentlyContinue
if ($null -eq $psql) {
    throw 'PSQL_NOT_FOUND'
}

try {
    & $psql.Source -w -X -v ON_ERROR_STOP=1 -f $testFile
    if ($LASTEXITCODE -ne 0) {
        throw "DATABASE_TEST_FAILED_EXIT_$LASTEXITCODE"
    }
    Write-Output 'DATABASE_TESTS_PASSED'
} finally {
    Remove-Item Env:PGPASSWORD, Env:PGUSER, Env:PGHOST, Env:PGPORT, Env:PGDATABASE, Env:PGSSLMODE `
        -ErrorAction SilentlyContinue
}
