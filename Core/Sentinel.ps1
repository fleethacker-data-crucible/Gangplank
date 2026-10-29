#Requires -Version 5.1
# Gangplank Sentinel: conservative local pre-publication checks, no AI data transfer.
# Findings never contain matched secrets or personal data.

function Get-GangplankSentinelFindings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $findings = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @([pscustomobject]@{ Code='FILE_MISSING'; Severity='Block'; Detail='File no longer exists.' })
    }
    $file = Get-Item -LiteralPath $Path -Force
    if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        return @([pscustomobject]@{ Code='LINK_UNVERIFIED'; Severity='Block'; Detail='Linked files cannot be verified.' })
    }
    if ($file.Length -gt 5242880) {
        return @([pscustomobject]@{ Code='SIZE_UNVERIFIED'; Severity='Block'; Detail='File exceeds the 5 MB scan limit.' })
    }
    $name = $file.Name.ToLowerInvariant()
    if ($name -match '(^\.env($|\.)|^id_(rsa|ed25519)|^\.npmrc$|^\.pypirc$|^credentials($|\.)|^token($|\.)|\.p(12|fx|em|pk)$|\.key$|^secrets?\.json$)') {
        [void]$findings.Add([pscustomobject]@{ Code='SENSITIVE_FILENAME'; Severity='Block'; Detail='Filename suggests a secret or private credential.' })
    }
    $extensions = @('.txt','.ps1','.psm1','.json','.yaml','.yml','.py','.js','.jsx','.ts','.tsx','.cs','.html','.css','.xml','.config','.properties','.md','.sh','.bat','.cmd','.env','.csv','.sql','.log','.toml','.ini','.gitignore','.svg')
    if ($file.Extension.ToLowerInvariant() -notin $extensions -and $name -notin @('dockerfile','makefile','.gitignore','.gitattributes','.editorconfig','.env.example')) {
        [void]$findings.Add([pscustomobject]@{ Code='FORMAT_UNVERIFIED'; Severity='Block'; Detail='This format has not been scanned for embedded information.' })
        return @($findings.ToArray())
    }
    $content = [IO.File]::ReadAllText($file.FullName,[Text.Encoding]::UTF8)
    $rules = @(
        @{ Code='PRIVATE_KEY'; Severity='Block'; Pattern='-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----'; Detail='Private key detected.' },
        @{ Code='GITHUB_TOKEN'; Severity='Block'; Pattern='\b(?:gh[pousr]_[A-Za-z0-9_]{24,}|github_pat_[A-Za-z0-9_]{24,})\b'; Detail='Possible GitHub credential.' },
        @{ Code='AWS_ACCESS_KEY'; Severity='Block'; Pattern='\b(?:AKIA|ASIA)[0-9A-Z]{16}\b'; Detail='Possible AWS credential.' },
        @{ Code='DATA_MARKING'; Severity='Review'; Pattern='(?i)(?<![A-Za-z])(?:C[O]NTROLLED UNCLASSIFIED INFORMATION|C[U]I//[A-Z/-]+)(?![A-Za-z])'; Detail='Possible data-handling marking. Authorized handling review required.' },
        @{ Code='SSN_CANDIDATE'; Severity='Review'; Pattern='\b(?!000|666|9\d\d)\d{3}[- ]?(?!00)\d{2}[- ]?(?!0000)\d{4}\b'; Detail='Possible personal identifier; could be synthetic.' },
        @{ Code='EMAIL_CANDIDATE'; Severity='Info'; Pattern='\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b'; Detail='Email address present. Consider whether release is appropriate.' }
    )
    foreach ($rule in $rules) {
        if ([regex]::IsMatch($content,$rule.Pattern)) {
            [void]$findings.Add([pscustomobject]@{ Code=$rule.Code; Severity=$rule.Severity; Detail=$rule.Detail })
        }
    }
    return @($findings.ToArray())
}

function Get-GangplankSentinelDestination {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)
    if ($Session.Provider -eq 'GitHub') {
        $repo = $Session.ProviderObj.InvokeApi('GET',"repos/$($Session.ProjectPath)")
        if ($null -eq $repo.private -or -not $repo.visibility) { throw 'GitHub destination visibility cannot be verified.' }
        $visibility = [string]$repo.visibility
        if ($visibility -notin @('public','private','internal')) { throw 'Unrecognized GitHub repository visibility.' }
        return [pscustomobject]@{ Host='GitHub'; Visibility=$visibility; Public=($visibility -eq 'public'); Verified=$true }
    }
    if ($Session.Provider -eq 'GitLab') {
        $project = $Session.ProviderObj.EncodePath([string]$Session.ProjectPath)
        $remote = $Session.ProviderObj.InvokeApi('GET',"projects/$project")
        $visibility = [string]$remote.visibility
        if ($visibility -notin @('public','private','internal')) { throw 'GitLab destination visibility cannot be verified.' }
        return [pscustomobject]@{ Host='GitLab'; Visibility=$visibility; Public=($visibility -eq 'public'); Verified=$true }
    }
    throw 'Unsupported repository provider.'
}

function Test-GangplankSentinelPublication {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)][string[]]$Paths)
    $destination = Get-GangplankSentinelDestination -Session $Session
    $findings = New-Object System.Collections.Generic.List[object]
    $root = [IO.Path]::GetFullPath([string]$Session.LocalPath).TrimEnd('\','/')
    foreach ($path in @($Paths | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($path)) {
            [void]$findings.Add([pscustomobject]@{ Path=''; Code='PATH_INVALID'; Severity='Block'; Detail='Empty file path.' })
            continue
        }
        $full = [IO.Path]::GetFullPath((Join-Path $root ($path.Replace('/',[IO.Path]::DirectorySeparatorChar))))
        if (-not $full.StartsWith(($root + [IO.Path]::DirectorySeparatorChar),[StringComparison]::OrdinalIgnoreCase)) {
            [void]$findings.Add([pscustomobject]@{ Path=$path; Code='PATH_INVALID'; Severity='Block'; Detail='File is outside the workspace.' })
            continue
        }
        foreach ($finding in @(Get-GangplankSentinelFindings -Path $full)) {
            [void]$findings.Add([pscustomobject]@{ Path=$path; Code=$finding.Code; Severity=$finding.Severity; Detail=$finding.Detail })
        }
    }
    $all = @($findings.ToArray())
    $blocking = @($all | Where-Object { $_.Severity -in @('Block','Review') })
    return [pscustomobject]@{
        Destination=$destination
        Findings=$all
        Allowed=($blocking.Count -eq 0)
        RequiresPublicConfirmation=$destination.Public
        Note='Visibility and automated detection do not authorize handling or release of government information.'
    }
}
