#Requires -Version 5.1
# AI with explicit consent ("Explain this file"): the preview shows exactly what would be sent
# and sends nothing; the send needs the matching consent token and goes out byte for byte as
# previewed; excluded, deleted, binary and Sentinel-flagged files are never sent. The gateway
# and the provider are scripted, so no network is used.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ('gp-consent-' + [guid]::NewGuid().ToString('N'))
$names = @('GANGPLANK_AI_URL','LLM_URL','OPENAI_BASE_URL','GANGPLANK_AI_MODEL','LLM_MODEL','OPENAI_MODEL','GANGPLANK_AI_ALLOWED_HOSTS','GANGPLANK_AI_TOKEN','LLM_TOKEN','OPENAI_API_KEY','GENAI_TOKEN')
$saved = @{}
foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n); [Environment]::SetEnvironmentVariable($n,$null) }
try {
    [void](New-Item -ItemType Directory -Path $temp -Force)
    Import-Module (Join-Path $root 'Gangplank.psm1') -Force -WarningAction SilentlyContinue
    . (Join-Path $PSScriptRoot 'TestIsolation.ps1')
    & (Get-Module Gangplank) {
        param($Temp)
        function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "FAILED: $Message" } }
        function Get-Code([scriptblock]$Block) { try { $null = & $Block; return '' } catch { return ([string]$_.Exception.Message -split '\|')[0] } }
        Initialize-GangplankLogging -LogDir (Join-Path $Temp 'Logs') -Level ERROR
        Initialize-GangplankConfig -ConfigPath (Join-Path $Temp 'config/gangplank-config.json')
        Set-GangplankFairleadKeyReader -Reader { param($Target) 'fl-test-key-1' }
        $script:GangplankAuditPath = Join-Path $Temp 'Logs/audit.jsonl'

        Invoke-Expression @'
class GangplankFakeConsentGitHub : GitHubProvider {
    [string]$Head
    GangplankFakeConsentGitHub([string]$head) : base('https://api.github.com','test-token') { $this.Head = $head }
    [string] GetRefSha([string]$projectPath,[string]$branch) { return $this.Head }
}
'@
        function Write-File([string]$Dir,[string]$Name,[string]$Text) { [IO.File]::WriteAllText((Join-Path $Dir $Name),$Text) }

        $folder = Join-Path $Temp 'work'
        [void](New-Item -ItemType Directory -Path $folder -Force)
        Write-File $folder 'notes.md' "baseline notes`n"
        Write-File $folder 'gone.txt' "will be deleted`n"
        $baseline = Get-GangplankLocalFileMap -Root $folder
        Write-File $folder 'notes.md' "# Fictional notes`n`nThis is made-up text for the test.`n"
        Remove-Item -LiteralPath (Join-Path $folder 'gone.txt')
        Write-File $folder 'people.csv' "id,ssn`n1,123-45-6789`n"              # Sentinel: possible personal identifier (review)
        Write-File $folder '.env' "TOKEN=fake`n"                                # excluded by name
        [IO.File]::WriteAllBytes((Join-Path $folder 'logo.png'),[byte[]](0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,0,0,0))   # binary
        Write-File $folder 'big.md' ('x' * 10000)

        $session = [pscustomobject]@{
            Provider = 'GitHub'; ProviderObj = [GangplankFakeConsentGitHub]::new('head-1'); ProjectPath = 'team/demo'
            DefaultBranch = 'main'; LastBranch = 'work'; Branches = @('main','work'); LocalPath = $folder; BaselineSha = 'head-1'; BaselineMap = $baseline
        }

        # --- the preview shows everything and sends nothing --------------------------
        $script:Seen = New-Object System.Collections.Generic.List[object]
        $script:GangplankHttpTransport = {
            param($Request)
            $script:Seen.Add($Request)
            return [pscustomobject]@{ Status = 200; Headers = @{}; Text = '{"choices":[{"message":{"content":"It is a short fictional note."}}]}'; File = $null; NetworkError = '' }
        }
        $p = Get-GangplankAiExplainPreview -Session $session -Path 'notes.md'
        Assert ($script:Seen.Count -eq 0) 'The preview must not send anything'
        Assert ($p.User -match 'File: notes\.md' -and $p.User -match 'made-up text') 'The preview shows the file name and its text'
        Assert ($p.System.Length -gt 20) 'The preview shows the system text too'
        Assert ($p.Destination -match '^127\.0\.0\.1' -and $p.Loopback) ('The default destination is this PC, got ' + $p.Destination)
        Assert ($p.Consent -match '^[0-9A-F]{64}$' -and -not $p.Truncated) 'A consent token for a short file'

        # --- files that are never sent -------------------------------------------------
        Assert ((Get-Code { Get-GangplankAiExplainPreview -Session $session -Path 'gone.txt' }) -eq 'BAD_REQUEST') 'A deleted file is not sent'
        Assert ((Get-Code { Get-GangplankAiExplainPreview -Session $session -Path '.env' }) -eq 'BAD_REQUEST') 'An excluded file is not sent'
        $msg = ''
        try { [void](Get-GangplankAiExplainPreview -Session $session -Path 'people.csv') } catch { $msg = [string]$_.Exception.Message }
        Assert ($msg -match '^BAD_REQUEST\|.*SSN_CANDIDATE') ("Sentinel-flagged text is not sent: $msg")
        Assert ((Get-Code { Get-GangplankAiExplainPreview -Session $session -Path 'logo.png' }) -eq 'BAD_REQUEST') 'A binary file is not sent'
        Assert ((Get-Code { Get-GangplankAiExplainPreview -Session $session -Path 'nothing.txt' }) -eq 'NOT_FOUND') 'Only pending changes can be explained'
        foreach ($bad in @('../x.txt','C:/Windows/win.ini','/etc/passwd','')) { Assert ((Get-Code { Get-GangplankAiExplainPreview -Session $session -Path $bad }) -eq 'BAD_REQUEST') "Path refused: '$bad'" }
        Assert ($script:Seen.Count -eq 0) 'Refused files send nothing'

        # --- a long file is cut, and says so -------------------------------------------
        $long = Get-GangplankAiExplainPreview -Session $session -Path 'big.md'
        Assert ($long.Truncated -and $long.User.Length -le 6000) 'A long file is cut to fit and the preview says so'

        # --- the send needs the matching token and goes out as previewed ---------------
        Assert ((Get-Code { Invoke-GangplankAiExplain -Session $session -Path 'notes.md' -Consent '' }) -eq 'CONFLICT') 'No consent token, nothing sent'
        Assert ((Get-Code { Invoke-GangplankAiExplain -Session $session -Path 'notes.md' -Consent ('0' * 64) }) -eq 'CONFLICT') 'A wrong token, nothing sent'
        Assert ($script:Seen.Count -eq 0) 'Refusals send nothing'
        $answer = Invoke-GangplankAiExplain -Session $session -Path 'notes.md' -Consent $p.Consent
        Assert ($answer -eq 'It is a short fictional note.') 'The answer is returned as text'
        Assert ($script:Seen.Count -eq 1) 'Exactly one request was sent'
        $body = $script:Seen[0].Body | ConvertFrom-Json
        Assert ($body.messages[0].content -ceq $p.System -and $body.messages[1].content -ceq $p.User) 'What was sent is exactly what was previewed'
        Assert ((Get-Content -LiteralPath $script:GangplankAuditPath -Raw) -match 'ai\.explain') 'The send is audited'
        Assert ((Get-Content -LiteralPath $script:GangplankAuditPath -Raw) -notmatch 'made-up text') 'The audit log never holds file text'

        # --- a file that changed after the preview is refused ---------------------------
        Write-File $folder 'notes.md' "# Edited after the preview`n"
        $script:Seen.Clear()
        Assert ((Get-Code { Invoke-GangplankAiExplain -Session $session -Path 'notes.md' -Consent $p.Consent }) -eq 'CONFLICT') 'A changed file needs a new preview'
        Assert ($script:Seen.Count -eq 0) 'A stale consent sends nothing'

        $script:GangplankHttpTransport = $null
    } $temp
    Write-Host 'AI consent checks passed.' -ForegroundColor Green
} finally {
    foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n,$saved[$n]) }
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
