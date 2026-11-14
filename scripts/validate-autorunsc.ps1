param(
    [Parameter(Mandatory = $true)]
    [string] $AutorunscPath
)

$ErrorActionPreference = 'Stop'
$runPath = 'Software\Microsoft\Windows\CurrentVersion\Run'
$valueName = 'SmSecureValidation_' + [guid]::NewGuid().ToString('N')
$key = $null
$created = $false
$result = 1
$command1 = '"' + (Join-Path $env:SystemRoot 'System32\cmd.exe') + '" /d /c exit 0'
$command2 = '"' + (Join-Path $env:SystemRoot 'System32\cmd.exe') + '" /d /c exit 1'

function Get-TestRows {
    param([string] $Path, [string] $Name)
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo.FileName = $Path
    $process.StartInfo.Arguments = '-a l -c -nobanner'
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $process.StartInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    try {
        if (-not $process.Start()) { throw 'START_FAILED' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) {
            $process.Kill()
            $process.WaitForExit()
            throw 'TIMEOUT'
        }
        $output = $stdout.GetAwaiter().GetResult()
        $errors = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0 -or $errors.Length -ne 0) { throw 'COMMAND_FAILED' }
        if ($output.Contains([char]0xfffd)) { throw 'ENCODING_INVALID' }
        $output = $output.TrimStart([char]0xfeff)
        $header = @(($output -split "`r?`n", 2)[0] -split ',' | ForEach-Object { $_.Trim('"') })
        foreach ($required in @('Entry Location', 'Entry', 'Profile', 'Category', 'Image Path', 'Launch String')) {
            if ($header -cnotcontains $required) { throw 'HEADER_UNSUPPORTED' }
        }
        $lines = $output | ConvertFrom-Csv
        $rows = @($lines | Where-Object { $_.Entry -eq $Name })
        return $rows
    } finally {
        $process.Dispose()
    }
}

try {
    if (-not (Test-Path -LiteralPath $AutorunscPath -PathType Leaf)) { throw 'EXECUTABLE_NOT_FOUND' }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    Write-Output "elevated=$($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"
    Write-Output "test_value_name=$valueName"
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($runPath, $true)
    if ($null -eq $key) { throw 'RUN_KEY_UNAVAILABLE' }
    if ($null -ne $key.GetValue($valueName)) { throw 'VALUE_ALREADY_EXISTS' }

    $before = @(Get-TestRows -Path $AutorunscPath -Name $valueName)
    $created = $true
    $key.SetValue($valueName, $command1, [Microsoft.Win32.RegistryValueKind]::String)
    $first = @(Get-TestRows -Path $AutorunscPath -Name $valueName)

    if ($key.GetValue($valueName) -cne $command1) { throw 'VALUE_MODIFIED_EXTERNALLY' }
    $key.SetValue($valueName, $command2, [Microsoft.Win32.RegistryValueKind]::String)
    $second = @(Get-TestRows -Path $AutorunscPath -Name $valueName)

    if ($key.GetValue($valueName) -cne $command2) { throw 'VALUE_MODIFIED_EXTERNALLY' }
    $key.DeleteValue($valueName, $false)
    if ($null -ne $key.GetValue($valueName)) { throw 'VALUE_DELETE_FAILED' }
    $created = $false
    Write-Output 'test_value_cleanup=completed'
    $after = @(Get-TestRows -Path $AutorunscPath -Name $valueName)

    Write-Output "absent_before=$($before.Count -eq 0)"
    Write-Output "unique_first=$($first.Count -eq 1)"
    Write-Output "unique_second=$($second.Count -eq 1)"
    Write-Output "absent_after=$($after.Count -eq 0)"
    if ($first.Count -eq 1 -and $second.Count -eq 1) {
        foreach ($field in @('Entry Location', 'Entry', 'Profile', 'Category')) {
            $known = -not [string]::IsNullOrWhiteSpace($first[0].$field) -and
                -not [string]::IsNullOrWhiteSpace($second[0].$field)
            Write-Output "identity_${field}_known_and_equal=$($known -and $first[0].$field -ceq $second[0].$field)"
        }
        Write-Output "launch_string_changed=$($first[0].'Launch String' -cne $second[0].'Launch String')"
        Write-Output "image_path_known_and_equal=$(-not [string]::IsNullOrWhiteSpace($first[0].'Image Path') -and $first[0].'Image Path' -ceq $second[0].'Image Path')"
    }
    if ($before.Count -ne 0 -or $first.Count -ne 1 -or $second.Count -ne 1 -or $after.Count -ne 0) {
        throw 'TEST_ENTRY_NOT_OBSERVED_AS_EXPECTED'
    }
    $result = 0
} catch {
    $safeErrors = @(
        'START_FAILED', 'TIMEOUT', 'COMMAND_FAILED', 'ENCODING_INVALID', 'HEADER_UNSUPPORTED',
        'EXECUTABLE_NOT_FOUND', 'RUN_KEY_UNAVAILABLE', 'VALUE_ALREADY_EXISTS',
        'VALUE_MODIFIED_EXTERNALLY', 'VALUE_DELETE_FAILED', 'TEST_ENTRY_NOT_OBSERVED_AS_EXPECTED'
    )
    $code = $_.Exception.Message
    if ($safeErrors -notcontains $code) { $code = 'UNEXPECTED_ERROR' }
    Write-Output "validation_failed=$code"
} finally {
    if ($null -ne $key) {
        if ($created) {
            try {
                $current = $key.GetValue($valueName)
                if ($current -ceq $command1 -or $current -ceq $command2) {
                    $key.DeleteValue($valueName, $false)
                    Write-Output 'test_value_cleanup=completed'
                } elseif ($null -ne $current) {
                    Write-Output 'test_value_cleanup=not_removed_unexpected_value'
                    $result = 1
                }
            } catch {
                Write-Output 'test_value_cleanup=failed'
                $result = 1
            }
        }
        $key.Dispose()
    }
}
exit $result
