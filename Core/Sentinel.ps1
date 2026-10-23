#Requires -Version 5.1
# Sentinel preliminary local-only classification. No source content is transmitted.
function Get-KeystoneSentinelFindings {
 [CmdletBinding()] param([Parameter(Mandatory)][string]$Path)
 $findings=New-Object System.Collections.Generic.List[object]
 if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){throw 'File not found.'}
 $file=Get-Item -LiteralPath $Path
 if(($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){return @([pscustomobject]@{Code='LINK_UNVERIFIED';Severity='Block';Detail='Linked file cannot be verified.'})}
 if($file.Length -gt 5242880){return @([pscustomobject]@{Code='SIZE_UNVERIFIED';Severity='Block';Detail='File exceeds 5 MB.'})}
 $extensions=@('.txt','.ps1','.psm1','.json','.yaml','.yml','.py','.js','.ts','.cs','.html','.xml','.config','.properties','.md','.sh','.bat','.cmd','.env','.csv','.sql','.log')
 if($file.Extension.ToLowerInvariant() -notin $extensions){return @([pscustomobject]@{Code='FORMAT_UNVERIFIED';Severity='Block';Detail='Unsupported file type.'})}
 $content=[IO.File]::ReadAllText($file.FullName)
 $rules=@(
 @{Code='PRIVATE_KEY';Severity='Block';Pattern='-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----';Detail='Private key marker.'},
 @{Code='GITHUB_TOKEN';Severity='Block';Pattern='\b(?:gh[pousr]_[A-Za-z0-9_]{24,}|github_pat_[A-Za-z0-9_]{24,})\b';Detail='Potential GitHub token.'},
 @{Code='AWS_ACCESS_KEY';Severity='Block';Pattern='\b(?:AKIA|ASIA)[0-9A-Z]{16}\b';Detail='Potential AWS access key.'},
 @{Code='CUI_MARKING';Severity='Review';Pattern='(?i)(?<![A-Za-z])(?:CONTROLLED UNCLASSIFIED INFORMATION|CUI//[A-Z/-]+)(?![A-Za-z])';Detail='Possible CUI marking.'},
 @{Code='SSN_CANDIDATE';Severity='Review';Pattern='\b(?!000|666|9\d\d)\d{3}[- ]?(?!00)\d{2}[- ]?(?!0000)\d{4}\b';Detail='Possible SSN, potentially synthetic.'},
 @{Code='EMAIL_CANDIDATE';Severity='Info';Pattern='\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b';Detail='Email address; context needed.'}
 )
 foreach($rule in $rules){if([regex]::IsMatch($content,$rule.Pattern)){[void]$findings.Add([pscustomobject]@{Code=$rule.Code;Severity=$rule.Severity;Detail=$rule.Detail})}}
 return @($findings.ToArray())
}
function Get-KeystoneSentinelDestination {
 [CmdletBinding()] param([Parameter(Mandatory)]$Session)
 if($Session.Provider -eq 'GitHub'){
  $repo=$Session.ProviderObj.InvokeApi('GET',"repos/$($Session.ProjectPath)")
  if($null -eq $repo.private -or -not $repo.visibility){throw 'GitHub visibility cannot be verified.'}
  $visibility=[string]$repo.visibility
  if($visibility -notin @('public','private','internal')){throw 'Unknown GitHub visibility.'}
  return [pscustomobject]@{Host='GitHub';Visibility=$visibility;Public=($visibility -eq 'public');Verified=$true}
 }
 return [pscustomobject]@{Host=[string]$Session.Provider;Visibility='unverified';Public=$false;Verified=$false}
}
function Test-KeystoneSentinelPublication {
 [CmdletBinding()] param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)][string[]]$Paths)
 $destination=Get-KeystoneSentinelDestination -Session $Session
 $findings=New-Object System.Collections.Generic.List[object]
 if(-not $destination.Verified){[void]$findings.Add([pscustomobject]@{Path='';Code='DESTINATION_UNVERIFIED';Severity='Block';Detail='Destination policy not verified.'})}
 foreach($path in $Paths){
  $full=Join-Path $Session.LocalPath ($path.Replace('/',[IO.Path]::DirectorySeparatorChar))
  if(-not (Test-Path -LiteralPath $full -PathType Leaf)){continue}
  foreach($finding in @(Get-KeystoneSentinelFindings -Path $full)){[void]$findings.Add([pscustomobject]@{Path=$path;Code=$finding.Code;Severity=$finding.Severity;Detail=$finding.Detail})}
 }
 $all=@($findings.ToArray())
 return [pscustomobject]@{Destination=$destination;Findings=$all;Allowed=(@($all|Where-Object {$_.Severity -in @('Block','Review')}).Count -eq 0);RequiresPublicConfirmation=$destination.Public}
}
