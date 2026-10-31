#Requires -Version 5.1
# Gangplank Sentinel: conservative local pre-publication checks, no AI data transfer.
# Findings never contain matched secrets or personal data.

# One list of what must never be published, shared by Smart Save's change list (Core/Workspace.ps1)
# and by Sentinel: secret-looking file names, and the block-level content rules.
$script:GangplankSecretNamePattern = '(^\.env($|\.)|^id_(rsa|ed25519)|^\.npmrc$|^\.pypirc$|^credentials($|\.)|^token($|\.)|\.p(12|fx|em|pk)$|\.key$|^secrets?\.json$)'
$script:GangplankBlockRules = @(
    @{ Code='PRIVATE_KEY'; Severity='Block'; Pattern='-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----'; Detail='Private key detected.' },
    @{ Code='GITHUB_TOKEN'; Severity='Block'; Pattern='\b(?:gh[pousr]_[A-Za-z0-9_]{24,}|github_pat_[A-Za-z0-9_]{24,})\b'; Detail='Possible GitHub credential.' },
    @{ Code='AWS_ACCESS_KEY'; Severity='Block'; Pattern='\b(?:AKIA|ASIA)[0-9A-Z]{16}\b'; Detail='Possible AWS credential.' }
)

function Test-GangplankSecretName {
    # True when a file name looks like a secret or private credential. Case-insensitive.
    param([AllowEmptyString()][string]$Name)
    return [bool]($Name.ToLowerInvariant() -match $script:GangplankSecretNamePattern)
}

function Test-GangplankSecretText {
    # True when text matches a block-level content rule (private key, GitHub token, AWS key).
    param([AllowEmptyString()][string]$Text)
    foreach ($rule in $script:GangplankBlockRules) { if ([regex]::IsMatch($Text,$rule.Pattern)) { return $true } }
    return $false
}

function Get-GangplankVerifiedBinaryType {
    # Images and PDF documents are identified by their first bytes, not by the extension alone.
    # Verified = the extension and the content agree; Mismatch = a known extension with other content.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    $types = @{ '.png' = 'PNG image'; '.jpg' = 'JPEG image'; '.jpeg' = 'JPEG image'; '.gif' = 'GIF image'; '.pdf' = 'PDF document' }
    if (-not $types.ContainsKey($ext)) { return [pscustomobject]@{ Verified = $false; Mismatch = $false; Type = '' } }
    $head = New-Object byte[] 8
    $stream = [IO.File]::OpenRead($Path)
    try { $read = $stream.Read($head,0,8) } finally { $stream.Dispose() }
    $hex = if ($read -gt 0) { (($head[0..($read - 1)] | ForEach-Object { '{0:X2}' -f $_ }) -join '') } else { '' }
    $ok = $false
    if ($ext -eq '.png') { $ok = $hex.StartsWith('89504E470D0A1A0A') }
    elseif ($ext -eq '.jpg' -or $ext -eq '.jpeg') { $ok = $hex.StartsWith('FFD8FF') }
    elseif ($ext -eq '.gif') { $ok = ($hex.StartsWith('474946383761') -or $hex.StartsWith('474946383961')) }
    elseif ($ext -eq '.pdf') { $ok = $hex.StartsWith('255044462D') }
    return [pscustomobject]@{ Verified = $ok; Mismatch = (-not $ok); Type = $types[$ext] }
}

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
    if (Test-GangplankSecretName -Name $name) {
        [void]$findings.Add([pscustomobject]@{ Code='SENSITIVE_FILENAME'; Severity='Block'; Detail='Filename suggests a secret or private credential.' })
    }
    $extensions = @('.txt','.ps1','.psm1','.json','.yaml','.yml','.py','.js','.jsx','.ts','.tsx','.cs','.html','.css','.xml','.config','.properties','.md','.sh','.bat','.cmd','.env','.csv','.sql','.log','.toml','.ini','.gitignore','.svg')
    if ($file.Extension.ToLowerInvariant() -notin $extensions -and $name -notin @('dockerfile','makefile','.gitignore','.gitattributes','.editorconfig','.env.example')) {
        $binary = Get-GangplankVerifiedBinaryType -Path $file.FullName
        if ($binary.Verified) {
            [void]$findings.Add([pscustomobject]@{ Code='BINARY_NOT_INSPECTED'; Severity='Review'; Detail=("A verified {0}. Its contents are not scanned for embedded information; publish it only if you know what it contains." -f $binary.Type) })
        } elseif ($binary.Mismatch) {
            [void]$findings.Add([pscustomobject]@{ Code='TYPE_MISMATCH'; Severity='Block'; Detail='The file content does not match its extension.' })
        } else {
            [void]$findings.Add([pscustomobject]@{ Code='FORMAT_UNVERIFIED'; Severity='Block'; Detail='This format has not been scanned for embedded information.' })
        }
        return @($findings.ToArray())
    }
    $content = [IO.File]::ReadAllText($file.FullName,[Text.Encoding]::UTF8)
    # Block rules are shared with Smart Save's change list (see $script:GangplankBlockRules); these are the review-level rules.
    $rules = @($script:GangplankBlockRules) + @(
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
    # -Acknowledgements: @{ path = reason }. A "Review" finding on that path is allowed once, with a reason of 5 to 300
    # characters; a "Block" finding never is. The caller records the reasons in the audit log.
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)][string[]]$Paths,[hashtable]$Acknowledgements = @{})
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
        $found = @(Get-GangplankSentinelFindings -Path $full)
        $acknowledged = $false
        if ($Acknowledgements.ContainsKey($path) -and @($found | Where-Object { $_.Severity -eq 'Review' }).Count -gt 0) {
            $reason = ([string]$Acknowledgements[$path]).Trim()
            if ($reason.Length -lt 5 -or $reason.Length -gt 300) { throw 'BAD_REQUEST|Give a short reason (5 to 300 characters) for each file you publish with a review finding.' }
            $acknowledged = $true
        }
        foreach ($finding in $found) {
            [void]$findings.Add([pscustomobject]@{ Path=$path; Code=$finding.Code; Severity=$finding.Severity; Detail=$finding.Detail; Acknowledged=($acknowledged -and $finding.Severity -eq 'Review') })
        }
    }
    $all = @($findings.ToArray())
    $blocking = @($all | Where-Object { $_.Severity -eq 'Block' -or ($_.Severity -eq 'Review' -and -not $_.Acknowledged) })
    return [pscustomobject]@{
        Destination=$destination
        Findings=$all
        Acknowledged=@($all | Where-Object { $_.Acknowledged })
        Allowed=($blocking.Count -eq 0)
        RequiresPublicConfirmation=$destination.Public
        Note='Visibility and automated detection do not authorize handling or release of government information.'
    }
}
