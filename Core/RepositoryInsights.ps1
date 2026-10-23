#Requires -Version 5.1
# Read-only GitHub/GitLab repository intelligence.
# Returns normalized, bounded metadata; never passes credentials to the browser.

function Get-KeystoneKnownBranches {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)
    return @($Session.ProviderObj.GetBranches([string]$Session.ProjectPath) | Where-Object { $_ } | Select-Object -Unique)
}

function Assert-KeystoneKnownBranch {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)][string]$Branch)
    if ($Branch.Length -gt 200 -or $Branch -cnotin @(Get-KeystoneKnownBranches -Session $Session)) {
        throw 'Select an existing branch from this repository.'
    }
    return $Branch
}

function Get-KeystoneRepositoryBranches {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)
    $current = if ($Session.LastBranch) { [string]$Session.LastBranch } else { [string]$Session.DefaultBranch }
    $names = @(Get-KeystoneKnownBranches -Session $Session | Select-Object -First 150)
    $out = foreach ($name in $names) {
        [pscustomobject]@{
            Name=[string]$name
            IsDefault=([string]$name -ceq [string]$Session.DefaultBranch)
            IsCurrent=([string]$name -ceq $current)
        }
    }
    return @($out)
}

function Get-KeystoneRepositoryHistory {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session,[string]$Branch,[ValidateRange(1,50)][int]$Limit=30)
    if (-not $Branch) { $Branch = if ($Session.LastBranch) { [string]$Session.LastBranch } else { [string]$Session.DefaultBranch } }
    [void](Assert-KeystoneKnownBranch -Session $Session -Branch $Branch)
    $encoded = [uri]::EscapeDataString($Branch)
    $provider = $Session.ProviderObj
    if ($Session.Provider -eq 'GitHub') {
        $raw = $provider.InvokeApi('GET',"repos/$($Session.ProjectPath)/commits?sha=$encoded&per_page=$Limit")
        $items = foreach ($c in @($raw)) {
            if (-not $c -or -not $c.sha) { continue }
            $msg = [string]$c.commit.message
            [pscustomobject]@{
                Sha=[string]$c.sha
                Title=(($msg -split '\r?\n')[0])
                Author=[string]$c.commit.author.name
                Date=[string]$c.commit.author.date
                Url=[string]$c.html_url
            }
        }
    } elseif ($Session.Provider -eq 'GitLab') {
        $project = $provider.EncodePath([string]$Session.ProjectPath)
        $raw = $provider.InvokeApi('GET',"projects/$project/repository/commits?ref_name=$encoded&per_page=$Limit")
        $items = foreach ($c in @($raw)) {
            if (-not $c -or -not $c.id) { continue }
            [pscustomobject]@{
                Sha=[string]$c.id
                Title=[string]$c.title
                Author=[string]$c.author_name
                Date=[string]$c.created_at
                Url=[string]$c.web_url
            }
        }
    } else { throw 'Unsupported repository provider.' }
    return @($items | Select-Object -First $Limit)
}

function Get-KeystoneRepositoryComparison {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)][string]$Base,[Parameter(Mandatory)][string]$Head)
    [void](Assert-KeystoneKnownBranch -Session $Session -Branch $Base)
    [void](Assert-KeystoneKnownBranch -Session $Session -Branch $Head)
    $be = [uri]::EscapeDataString($Base)
    $he = [uri]::EscapeDataString($Head)
    $provider = $Session.ProviderObj
    $files = @()
    $ahead = $null
    $behind = $null
    if ($Session.Provider -eq 'GitHub') {
        $result = $provider.InvokeApi('GET',"repos/$($Session.ProjectPath)/compare/$be...$he")
        $ahead = $result.ahead_by
        $behind = $result.behind_by
        $files = @($result.files | Select-Object -First 100 | ForEach-Object {
            [pscustomobject]@{ Path=[string]$_.filename; Status=[string]$_.status; Additions=[int]$_.additions; Deletions=[int]$_.deletions }
        })
    } elseif ($Session.Provider -eq 'GitLab') {
        $project = $provider.EncodePath([string]$Session.ProjectPath)
        $result = $provider.InvokeApi('GET',"projects/$project/repository/compare?from=$be&to=$he")
        $files = @($result.diffs | Select-Object -First 100 | ForEach-Object {
            $kind = if ($_.new_file) { 'added' } elseif ($_.deleted_file) { 'removed' } elseif ($_.renamed_file) { 'renamed' } else { 'modified' }
            [pscustomobject]@{ Path=[string]$_.new_path; Status=$kind; Additions=$null; Deletions=$null }
        })
    } else { throw 'Unsupported repository provider.' }
    return [pscustomobject]@{
        Base=$Base; Head=$Head; AheadBy=$ahead; BehindBy=$behind
        Files=@($files); Truncated=(@($files).Count -ge 100)
        Explanation='Only file metadata is shown. A comparison is not a merge.'
    }
}

function Get-KeystoneRepositoryReviews {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)
    $provider = $Session.ProviderObj
    if ($Session.Provider -eq 'GitHub') {
        $raw = $provider.InvokeApi('GET',"repos/$($Session.ProjectPath)/pulls?state=open&per_page=30")
        $items = foreach ($pr in @($raw)) {
            if (-not $pr -or -not $pr.number) { continue }
            [pscustomobject]@{
                Number=[int]$pr.number; Title=[string]$pr.title
                Source=[string]$pr.head.ref; Target=[string]$pr.base.ref
                Author=[string]$pr.user.login; Url=[string]$pr.html_url
            }
        }
    } elseif ($Session.Provider -eq 'GitLab') {
        $project = $provider.EncodePath([string]$Session.ProjectPath)
        $raw = $provider.InvokeApi('GET',"projects/$project/merge_requests?state=opened&per_page=30")
        $items = foreach ($mr in @($raw)) {
            if (-not $mr -or -not $mr.iid) { continue }
            [pscustomobject]@{
                Number=[int]$mr.iid; Title=[string]$mr.title
                Source=[string]$mr.source_branch; Target=[string]$mr.target_branch
                Author=[string]$mr.author.username; Url=[string]$mr.web_url
            }
        }
    } else { throw 'Unsupported repository provider.' }
    return @($items | Select-Object -First 30)
}

function Get-KeystoneRepositoryInsights {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)
    $current = if ($Session.LastBranch) { [string]$Session.LastBranch } else { [string]$Session.DefaultBranch }
    $branches = @(Get-KeystoneRepositoryBranches -Session $Session)
    $reviews = @(Get-KeystoneRepositoryReviews -Session $Session)
    $notes = New-Object System.Collections.Generic.List[string]
    if ($current -ne $Session.DefaultBranch) {
        $comparison = Get-KeystoneRepositoryComparison -Session $Session -Base $Session.DefaultBranch -Head $current
        if ($null -ne $comparison.BehindBy -and [int]$comparison.BehindBy -gt 0) {
            [void]$notes.Add("This branch is $($comparison.BehindBy) commit(s) behind the default branch. Review updates before combining.")
        }
        if ($null -ne $comparison.AheadBy -and [int]$comparison.AheadBy -gt 0) {
            [void]$notes.Add("This branch has $($comparison.AheadBy) commit(s) not on the default branch.")
        }
    }
    if ($reviews.Count -gt 0) { [void]$notes.Add("$($reviews.Count) open review request(s) need attention.") }
    if ($notes.Count -eq 0) { [void]$notes.Add('No outstanding branch divergence or reviews were identified in this limited check.') }
    return [pscustomobject]@{
        Project=[string]$Session.ProjectPath; Branch=$current
        BranchCount=$branches.Count; OpenReviewCount=$reviews.Count
        Suggestions=@($notes.ToArray())
        Scope='Live provider metadata only; not a complete repository security or dependency audit.'
    }
}
