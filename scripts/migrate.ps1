$ErrorActionPreference = 'Stop'

$envFile = Join-Path (Split-Path -Parent $PSScriptRoot) '.env.local'
$migrationDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) 'db\migrations'

if (-not (Test-Path -LiteralPath $envFile -PathType Leaf)) {
    throw 'ENV_FILE_NOT_FOUND'
}
if (-not (Test-Path -LiteralPath $migrationDirectory -PathType Container)) {
    throw 'MIGRATION_DIRECTORY_NOT_FOUND'
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

function Invoke-PsqlQuery([string]$query) {
    $result = & $psql.Source -w -X -A -t -q -v ON_ERROR_STOP=1 -c $query
    if ($LASTEXITCODE -ne 0) {
        throw "MIGRATION_QUERY_FAILED_EXIT_$LASTEXITCODE"
    }
    return $result
}

try {
    $migrationFiles = Get-ChildItem -LiteralPath $migrationDirectory -Filter '*.sql' -File |
        Sort-Object -Property Name
    if ($migrationFiles.Count -eq 0) {
        throw 'MIGRATION_FILES_NOT_FOUND'
    }

    foreach ($migrationFile in $migrationFiles) {
        $version = [System.IO.Path]::GetFileNameWithoutExtension($migrationFile.Name)
        $migrationTables = Invoke-PsqlQuery @"
SELECT n.nspname
FROM pg_catalog.pg_class AS c
JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
WHERE c.relname = 'schema_migrations'
  AND c.relkind = 'r'
  AND n.nspname IN ('public', 'sm_secure')
ORDER BY n.nspname
"@

        $isApplied = $false
        foreach ($schema in $migrationTables) {
            $applied = Invoke-PsqlQuery "SELECT EXISTS (SELECT 1 FROM `"$schema`".schema_migrations WHERE version = '$version')"
            if ($applied -contains 't') {
                $isApplied = $true
                break
            }
        }

        if ($isApplied) {
            continue
        }

        & $psql.Source -w -X -v ON_ERROR_STOP=1 -f $migrationFile.FullName
        if ($LASTEXITCODE -ne 0) {
            throw "MIGRATION_FAILED_EXIT_$LASTEXITCODE"
        }
    }
    Write-Output 'MIGRATION_APPLIED'
} finally {
    Remove-Item Env:PGPASSWORD, Env:PGUSER, Env:PGHOST, Env:PGPORT, Env:PGDATABASE, Env:PGSSLMODE `
        -ErrorAction SilentlyContinue
}
