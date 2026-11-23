# AdHoc Relay, the server, on Windows: a service of this computer - Remote Desktop, SSH, VNC, a web server -, or of its network,
# reached by the client through a relay, with nothing to forward on the routers. The client uses its own program of that
# service, as with any address: Remote Desktop Connection, ssh, a VNC viewer, a browser. Nothing is installed there.
#
#   adhoc-relay-server.cmd                                                     a double click: asks, as a menu; the answers kept
#   powershell -ExecutionPolicy Bypass -File adhoc-relay-server.ps1 -Meet 'Tr7kQ2xZp4Lm9sWd👉router.example.org:40000👉' -Forward 3389
#   powershell -ExecutionPolicy Bypass -File adhoc-relay-server.ps1 -Meet 'Tr7kQ2xZp4Lm9sWd👉router.example.org:40000👉' -Forward 3389 -Token K7QM2XHP9RTA4WZD
#
# The line is a key, 👉, the relay and its first port, 👉 - of the password, of a fixed port, of a user: all alike. No key travels:
# the script binds a port of meeting at the relay - the id of its key, its own id, 8 random bytes of this start, and 8 bytes of
# HMAC-SHA256 the key makes of them and of the address the relay sees it at -, prints the line for the client, the relay and that
# port, and from then on knocks at the port - with the key of its knocks, 16 bytes of HMAC of the port and that address - and
# dials it, a try after another, from one local port; how often it knocks, how long a try is and how often it binds anew the
# relay says in its answer - 20 s, 31 s and 30 minutes unless set otherwise there. Each connection that meets is joined to the
# server by .NET, both ways, the bytes as they are; the next one is awaited at once. It binds anew, and at once when the relay
# refuses its knock: this computer is behind another address then. A relay whose address changes has its address kept by others:
# the line names them, each with a key of reading, then the first port of the relay -
# Fx2pL8wNq7Rk3mZa🌐Rk8mP2qLx3Vb7NtY👉203.0.113.7:40000🌐Hx4nT7wAc5Jd2QeL👉198.51.100.9:40000🌐40000👉 -, and the address is read
# there, again every 30 s; an answer the key of reading did not sign is not taken. The signs may be typed as > and @. Windows
# PowerShell 5.1, as Windows has it, or PowerShell 7: nothing to install.
#
# With a token, 16 letters and digits, the client is AdHoc Relay Client, and the two meet directly when they can:
# the knocks carry the key of a call of the token, 8 bytes of SHA-256 of "adhoc-relay call" and the token; a call the relay sends
# on is answered with where this server can be reached - by STUN at the first port of the relay, in its LAN, over IPv6 -, and
# the client is dialed there from the local port of the knocks, a new SYN each 300 ms, 3 s. Each connection, through the relay
# or directly, begins with the token: one without it is cut off, the program of the client that dials the line itself too.

param([string]$Meet, [string]$Forward, [string]$Token, [string]$Parse, [string]$Vector)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

# ── the window: each kind of news with its sign and colour ──

$Tones = @{ good = 'Green'; news = 'Cyan'; wait = 'Yellow'; warn = 'DarkYellow'; bad = 'Red'; quiet = 'DarkGray'; key = 'Yellow'; name = 'White' }
function Say([string]$sign, [string]$tone, [string]$text) {
    Write-Host " $sign " -NoNewline
    Write-Host $text -ForegroundColor $Tones[$tone]
}

# ── what to open: the servers people reach most, and any port ──

$RDP = 3389
$Services = @(
    @('🪟', 'Remote Desktop of Windows', '3389', 'Remote Desktop Connection ( mstsc ): a long, strong password on the account is a must'),
    @('🔐', 'SSH', '22', 'ssh -p <port> <relay>'),
    @('🖼️', 'VNC', '5900', 'a VNC viewer'),
    @('🌐', 'A web server', '80', 'a browser: http://<relay>:<port>'),
    @('✏️', 'Another port', '', 'of this computer, or address:port of its network: you type which')
)

# ── what the menu keeps beside the script: key = value ──

$KeptFile = Join-Path $PSScriptRoot 'adhoc-relay-server.settings'

function Load-Kept {
    $k = @{}
    if (Test-Path $KeptFile) {
        foreach ($l in Get-Content $KeptFile -Encoding UTF8) { if ($l -match '^\s*(\w+)\s*=\s*(\S.*?)\s*$') { $k[$Matches[1]] = $Matches[2] } }
    }
    return $k
}

function Save-Kept($k) {
    $text = "# AdHoc Relay, the server: what the menu offers on Enter`r`n"
    foreach ($n in 'service', 'forward', 'meet', 'password', 'token') { if ($k[$n]) { $text += "$n = $($k[$n])`r`n" } }
    try { [IO.File]::WriteAllText($KeptFile, $text) } catch { Say '💾' quiet "Not kept for the next start: $($_.Exception.Message)" }
}

# ── the keys and lines typed ──

function Read-Key {
    if ([Console]::IsInputRedirected) {
        $c = [Console]::In.Read()
        if ($c -lt 0) { exit 0 }
        return [string][char]$c
    }
    $k = [Console]::ReadKey($true)
    # Ctrl+C comes as a key here: it ends the script, as anywhere else
    if ($k.Key -eq 'C' -and ($k.Modifiers -band [ConsoleModifiers]::Control)) { exit 0 }
    if ($k.Key -eq 'Enter') { return "`n" }
    return [string]$k.KeyChar
}

function Read-Line([string]$prompt) {
    Write-Host " $prompt " -NoNewline -ForegroundColor Cyan
    # the window of the console gives what is pasted as it is; [Console]::In reads it through the code page of the console, and a
    # line pasted from the page of the relay comes with ?? for its 👉 and 🌐
    if ([Console]::IsInputRedirected) { $l = [Console]::In.ReadLine() } else { $l = $Host.UI.ReadLine() }
    if ($null -eq $l) { exit 0 }
    return $l.Trim()
}

# Where the connections go, of what was typed: a port alone - of this computer -, or address:port. $null - neither. The digits
# of ASCII, 5 at most: \d takes those of other scripts too, and a number too long is no [int]
function Target([string]$t) {
    $t = $t.Trim()
    if ($t -match '^[0-9]{1,5}$' -and [int]$t -gt 0 -and [int]$t -lt 65536) { return "127.0.0.1:$t" }
    if ($t -match '^([^\s:]+):([0-9]{1,5})$' -and [int]$Matches[2] -gt 0 -and [int]$Matches[2] -lt 65536) { return $t }
    return $null
}

# The signs of the lines: 👉, 🌐, 👀, ✏️ - typed as > @ ? !
$Arrow = [char]::ConvertFromUtf32(0x1F449); $Globe = [char]::ConvertFromUtf32(0x1F310); $Eyes = [char]::ConvertFromUtf32(0x1F440)
$Pen = "$([char]0x270F)$([char]0xFE0F)"

# A line with the signs of the keyboard: what makes an emoji coloured, or the colour of skin, left out.
function Plain([string]$t) {
    $t = $t -replace '\uFE0F|\uD83C[\uDFFB-\uDFFF]', ''
    return $t.Replace($Arrow, '>').Replace($Globe, '@').Replace($Eyes, '?').Replace([string][char]0x270F, '!').Trim()
}

# The line as people see it: the signs of the keyboard as emoji.
function Pretty([string]$t) { return $t.Replace('>', $Arrow).Replace('@', $Globe).Replace('?', $Eyes).Replace('!', $Pen) }

# A port: 1…65535, as a number is written - the digits of ASCII, no zeros in front: one form for every program that takes lines.
function Port-Ok([string]$s) { return $s -match '^[1-9][0-9]{0,4}$' -and [int]$s -le 65535 }

# The relay as its owner gave it - the page of AdHoc Relay copies it so -, one of
#   <key>👉<point>[:<its first port>]👉                                    the key, and where it binds a port: the relay
#   <key>🌐<read>👉<keeper>:<its port>[🌐<read>👉<keeper>:<its port>...]🌐<its first port>👉
#                                                                        a relay whose address changes: read from its keepers, in turn
# or the relay alone, <point>[:<its first port>], its key asked then. The key: the password, the key of a fixed port, of a user
# - the relay answers the port of each. The 👉 at the end may be left out. As @{ key; port; host } or @{ key; port; reads = @(
# @(key of reading, keeper, its first port), ... ) }: key $null when the line has none. $null - no such line.
function Point([string]$t) {
    $t = Plain $t
    $p = @{ key = $null; reads = $null; host = $null; port = 40000 }
    $rest = $t
    $read = $false
    if ($t.IndexOfAny([char[]]'>@') -ge 0) {
        if ($t.EndsWith('>')) { $t = $t.Substring(0, $t.Length - 1) }
        $i = $t.IndexOfAny([char[]]'>@')
        if ($i -lt 0) { return $null }
        if ($i -gt 0) { $p.key = $t.Substring(0, $i) }
        $read = $t[$i] -eq '@'
        $rest = $t.Substring($i + 1)
    }
    # 🌐 between the parts: where to read the address, each a read key 👉 a keeper and its port; after the last 🌐 the port
    if ($read) {
        $parts = $rest -split '@'
        if ($parts.Count -lt 2 -or -not (Port-Ok $parts[-1])) { return $null }
        $p.port = [int]$parts[-1]
        $reads = @()
        foreach ($r in $parts[0..($parts.Count - 2)]) {
            if ($r.Trim() -cnotmatch '^([A-Za-z0-9]{16})>([^\s:@=,!?>]+):(\d+)$') { return $null }
            if (-not (Port-Ok $Matches[3])) { return $null }
            $reads += , @($Matches[1], $Matches[2], [int]$Matches[3])
        }
        $p.reads = $reads
        return $p
    }
    if ($rest -notmatch '^([^\s:@=,!?>]+)(?::(\d+))?$') { return $null }
    $p.host = $Matches[1]
    if ($Matches[2]) {
        if (-not (Port-Ok $Matches[2])) { return $null }
        $p.port = [int]$Matches[2]
    }
    return $p
}

# A password or a key: 16 letters and digits. A token is the same.
function Key-Ok([string]$k) { return $k -cmatch '^[A-Za-z0-9]{16}$' }

# A new token: 16 letters and digits of the random bytes of the system, those mistaken for one another left out - as the relay
# makes its keys. Each character alike: a byte past the last whole run of the letters is left out, not folded onto the first
function New-Token {
    $abc = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'
    $whole = 256 - 256 % $abc.Length
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $b = New-Object byte[] 1
    $t = ''
    try { while ($t.Length -lt 16) { $rng.GetBytes($b); if ($b[0] -lt $whole) { $t += $abc[$b[0] % $abc.Length] } } } finally { $rng.Dispose() }
    return $t
}

# The line without its key, as the menu keeps it, the signs of the keyboard: > first, or @ before each read and the port; > last.
function Rest-Of($p) {
    if ($p.reads) { $where = (($p.reads | ForEach-Object { "@$($_[0])>$($_[1]):$($_[2])" }) -join '') + "@$($p.port)" }
    else { $where = ">$($p.host):$($p.port)" }
    return "$where>"
}

# What a whole line is, as docs/lines.tsv writes it - the line whole, the signs of the keyboard, the ports put in where the line
# has none -, or `error`: what every program takes alike.
function Parsed([string]$t) {
    $p = Point $t
    if (-not $p -or -not (Key-Ok $p.key)) { return 'error' }
    return "$($p.key)$(Rest-Of $p)"
}

# The keys of reading hidden, for the screen.
function Hidden([string]$t) { return (Pretty $t) -creplace ([regex]::Escape($Globe) + '[A-Za-z0-9]{16}'), "$Globe****************" }

$Lines = "such as Tr7kQ2xZp4Lm9sWd${Arrow}router.example.org:40000${Arrow}, or Tr7kQ2xZp4Lm9sWd${Globe}Rk8mP2qLx3Vb7NtY${Arrow}203.0.113.7:40000${Globe}40000${Arrow} - its address read there"

# what it makes of a line, and nothing more: docs/lines.tsv
if ($PSBoundParameters.ContainsKey('Parse')) { Parsed $Parse; exit 0 }

$Ascii = [Text.Encoding]::ASCII

# the id of a key, 8 bytes: what this server names its key by - the key itself never travels
function Kid([string]$key) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return , [byte[]]($sha.ComputeHash($Ascii.GetBytes("AdHoc Relay id$key"))[0..7]) } finally { $sha.Dispose() }
}
# what a key says of some bytes: the first bytes of HMAC-SHA256, 8 unless asked
function Said([byte[]]$words, [string]$key, [int]$n = 8) {
    $hmac = New-Object Security.Cryptography.HMACSHA256(, $Ascii.GetBytes($key))
    try { return , [byte[]]($hmac.ComputeHash($words)[0..($n - 1)]) } finally { $hmac.Dispose() }
}
function Same([byte[]]$a, [byte[]]$b) { return [Linq.Enumerable]::SequenceEqual($a, $b) }

# What this server says, each made in one place - for the relay, and for `-Vector`. A bind: of the key, the id of this start
# and the address the relay sees this computer at, 4 bytes. The key of the knocks of a port: the port as its 2 bytes. A read:
# with 8 random bytes; and what the read key says of them and the 5 bytes answered - the address, the minutes
function Bind-Packet([string]$key, [byte[]]$id, [byte[]]$as) { return , [byte[]]((Kid $key) + $id + (Said ([byte[]]($Ascii.GetBytes('bind') + $id + $as)) $key)) }
function Knock-Key([string]$key, [byte[]]$id, [byte[]]$port, [byte[]]$as) { return , (Said ([byte[]]($Ascii.GetBytes('knock') + $id + $port + $as)) $key 16) }
function Read-Packet([string]$key, [byte[]]$nonce) { return , [byte[]]((Kid $key) + $nonce) }
function Read-Said([string]$key, [byte[]]$nonce, [byte[]]$five) { return , (Said ([byte[]]($Ascii.GetBytes('read') + $nonce + $five)) $key) }
# what the key says of an answer to a bind: made for another address - of the address the relay sees; bound - of the port, its 2
# bytes, that address and the times of the relay, 3 bytes
function Seen-Said([string]$key, [byte[]]$id, [byte[]]$as) { return , (Said ([byte[]]($Ascii.GetBytes('seen') + $id + $as)) $key) }
function Bound-Said([string]$key, [byte[]]$id, [byte[]]$port, [byte[]]$as, [byte[]]$times) { return , (Said ([byte[]]($Ascii.GetBytes('bound') + $id + $port + $as + $times)) $key) }

# `-Vector "<what> <of what>"`: the bytes of a case of docs/vectors.tsv, hex - what any program that speaks to the relay makes
# of the same keys
if ($PSBoundParameters.ContainsKey('Vector')) {
    $parts = @(-split $Vector)
    $what = $parts[0]; $k = "$($parts[1])"; $a = @($parts | Select-Object -Skip 2)
    function Bytes([string]$hex) { return , [byte[]]@(for ($i = 0; $i -lt $hex.Length; $i += 2) { [Convert]::ToByte($hex.Substring($i, 2), 16) }) }
    function Address([string]$t) { return , [Net.IPAddress]::Parse($t).GetAddressBytes() }
    [byte[]]$out = if ($what -eq 'kid' -and $a.Count -eq 0) { Kid $k }
    elseif ($what -eq 'bind' -and $a.Count -eq 2) { Bind-Packet $k (Bytes $a[0]) (Address $a[1]) }
    elseif ($what -eq 'knock' -and $a.Count -eq 3) { Knock-Key $k (Bytes $a[0]) ([byte[]](([int]$a[1] -shr 8), ([int]$a[1] -band 255))) (Address $a[2]) }
    elseif ($what -eq 'read' -and $a.Count -eq 1) { Read-Packet $k (Bytes $a[0]) }
    elseif ($what -eq 'answer' -and $a.Count -eq 3) { [byte[]]$five = (Address $a[1]) + [byte]$a[2]; $five + (Read-Said $k (Bytes $a[0]) $five) }
    elseif ($what -eq 'seen' -and $a.Count -eq 2) { (Address $a[1]) + (Seen-Said $k (Bytes $a[0]) (Address $a[1])) }
    elseif ($what -eq 'bound' -and $a.Count -eq 6) { [byte[]]$p2 = ([int]$a[1] -shr 8), ([int]$a[1] -band 255); [byte[]]$t3 = [byte]$a[3], [byte]$a[4], [byte]$a[5]; $p2 + (Address $a[2]) + $t3 + (Bound-Said $k (Bytes $a[0]) $p2 (Address $a[2]) $t3) }
    else { '-Vector "kid <key>" | "bind <key> <id> <address>" | "knock <key> <id> <port> <address>" | "read <key> <8 bytes>" | "answer <key> <8 bytes> <address> <minutes>" | "seen <key> <id> <address>" | "bound <key> <id> <port> <address> <knock> <dial> <rebind>"'; exit 1 }
    -join ($out | ForEach-Object { $_.ToString('x2') })
    exit 0
}

# ── the menu, when nothing was given ──

function Menu {
    $k = Load-Kept
    Write-Host
    Say '🔌' news 'What should the client reach through the relay?'
    Write-Host
    for ($i = 0; $i -lt $Services.Count; $i++) {
        $s = $Services[$i]
        $what = $s[3]
        if ($s[2]) { $what = "port $($s[2]) · $($s[3])" } elseif ($k.forward -and $k.service -eq "$($i + 1)") { $what = "last time $($k.forward)" }
        Write-Host '    ' -NoNewline; Write-Host ($i + 1) -NoNewline -ForegroundColor Yellow
        Write-Host "  $($s[0])  " -NoNewline; Write-Host ('{0,-27}' -f $s[1]) -NoNewline -ForegroundColor White
        Write-Host $what -ForegroundColor DarkGray
    }
    Write-Host
    if ($k.service) { Write-Host " Press 1-5 · Enter: $($k.service) as last time › " -NoNewline -ForegroundColor Cyan }
    else { Write-Host ' Press 1-5 › ' -NoNewline -ForegroundColor Cyan }
    while ($true) {
        $c = Read-Key
        if ($c -match '^[1-5]$') { $service = [int]$c; break }
        if ($c -eq "`n" -and $k.service) { $service = [int]$k.service; break }
    }
    $s = $Services[$service - 1]
    Write-Host "$service  $($s[0]) $($s[1])" -ForegroundColor Green
    if ($s[2]) { $to = "127.0.0.1:$($s[2])" }
    else {
        $last = $k.forward -and $k.service -eq '5'
        while ($true) {
            if ($last) { $typed = Read-Line "Which port: of this computer, such as 8080, or address:port of its network - Enter for $($k.forward):" }
            else { $typed = Read-Line 'Which port: of this computer, such as 8080, or address:port of its network:' }
            if (-not $typed -and $last) { $typed = $k.forward }
            $to = Target $typed
            if ($to) { break }
            Say '💡' warn 'A port, such as 8080, or an address and a port, such as 192.168.1.5:80'
        }
    }
    while ($true) {
        if ($k.meet) { $typed = Read-Line "The relay - Enter for $(Hidden $k.meet):" }
        else { $typed = Read-Line "The relay, as its owner gave it, such as Tr7kQ2xZp4Lm9sWd${Arrow}router.example.org:40000${Arrow}:" }
        if (-not $typed -and $k.meet) { $typed = $k.meet }
        $p = Point $typed
        if ($p) { break }
        Say '💡' warn "As its owner gave it - $Lines - or a name or an address, and :port when its owner gave one"
    }
    $meet = Rest-Of $p
    $key = $p.key
    if (-not $key -and $meet -eq (Plain $k.meet)) { $key = $k.password }
    while (-not (Key-Ok $key)) {
        $key = Read-Line 'Its password or key, 16 letters and digits:'
        if (-not (Key-Ok $key)) { Say '💡' warn 'The password of a relay, or a key of it, is 16 letters and digits' }
    }
    # the token: Enter keeps what was last time, a token or none
    Say '🎫' quiet 'With a token only AdHoc Relay Client gets in, given the token too, and directly when the two can. Without one, any program of the client, through the relay'
    while ($true) {
        if (Key-Ok $k.token) { $typed = Read-Line 'The token - Enter for the one of last time, - for none, + for a new one:' }
        else { $typed = Read-Line 'The token, 16 letters and digits - + for a new one, Enter for none:' }
        if (-not $typed) { $tk = $(if (Key-Ok $k.token) { $k.token } else { $null }) }
        elseif ($typed -eq '-') { $tk = $null }
        elseif ($typed -eq '+') { $tk = New-Token }
        else { $tk = $typed }
        if (-not $tk -or (Key-Ok $tk)) { break }
        Say '💡' warn 'A token is 16 letters and digits, as a key; + makes one'
    }
    $k.service = "$service"
    if ($service -eq 5) { $k.forward = $to }
    $k.meet = Pretty $meet # kept as people see it: the emoji
    $k.password = $key
    $k.token = $tk
    Save-Kept $k
    Write-Host
    return @($to, "$key$meet", $tk)
}

# ── the arguments, or the menu ──

Write-Host
Write-Host ' AdHoc Relay' -NoNewline -ForegroundColor White; Write-Host ' · the server' -ForegroundColor Cyan
Write-Host ' the client reaches a service of this server through a relay: no port forwarded on the routers' -ForegroundColor DarkGray

# a failure, said: a window opened by a double click stays to be read
function Fail([string]$text) {
    Say '❌' bad $text
    if (-not [Console]::IsInputRedirected) { Write-Host; Write-Host ' Press Enter to close this window.' -ForegroundColor Cyan; [void][Console]::In.ReadLine() }
    exit 1
}
# whatever else fails, unforeseen: said the same way - not a window that closes with its reason unread
trap { Fail "$_" }

if ($Forward -or $Meet) {
    if (-not ($Forward -and $Meet)) { Fail '-Meet and -Forward go together' }
    $to = Target $Forward
    if (-not $to) { Fail '-Forward <port> or <address:port>, such as 3389 or 192.168.1.5:80' }
    if ($Token -and -not (Key-Ok $Token)) { Fail '-Token <16 letters and digits>, such as K7QM2XHP9RTA4WZD' }
    $given = $Meet
} else {
    if ($Token) { Fail '-Token goes with -Meet and -Forward' }
    $to, $given, $Token = Menu
}
$p = Point $given
if (-not $p -or -not (Key-Ok $p.key)) { Fail "-Meet <the line of the relay>, $Lines" }
# with a token, the key of a call of it: what the knocks carry after the key of the knocks, and a call begins with - the first 8
# bytes of SHA-256 of "adhoc-relay call" and the token. The token itself goes only to the client, the first bytes of each
# connection
$Call = $null
if ($Token) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $Call = [byte[]]($sha.ComputeHash($Ascii.GetBytes("adhoc-relay call$Token"))[0..7]) } finally { $sha.Dispose() }
}
$isRdp = $to -match ":$RDP$"
$toHost, $toPort = $to -split ':(?=\d+$)'

Say '💤' warn 'To connect later, this computer must stay on and awake while this runs: asleep, it lets nobody in, and a minute later the relay gives its port to others'
Say '💤' warn 'Windows: Settings > System > Power, sleep Never. The screen may go dark'

# the server: said at once when nothing answers there; the meetings wait for it anyway
function Dial-Server {
    $c = New-Object Net.Sockets.TcpClient
    try {
        if ($c.ConnectAsync($toHost, [int]$toPort).Wait(5000)) { return $c }
    } catch { }
    $c.Close()
    return $null
}
$probe = Dial-Server
if ($probe) { $probe.Close(); Say '🔌' good "$to answers: whoever comes is joined to it" }
elseif ($isRdp) { Say '⚠️' warn "Nothing answers at ${to}: Remote Desktop is off on this computer. Windows Pro or above: Settings > System > Remote Desktop, on. Windows Home has none" }
else { Say '⚠️' warn "Nothing answers at $to yet: whoever comes waits for it" }
if ($isRdp) {
    Say '🔑' warn 'Whoever finds the port will try passwords: programs of the internet guess at every Remote Desktop they find, day and night'
    Say '🔑' warn 'The account you log in with needs a long password of its own, 16 characters or more, used nowhere else; not Administrator, admin or user'
}

# ── the meeting ──

function Resolve-IP([string]$name) {
    try { return [Net.Dns]::GetHostAddresses($name) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1 } catch { return $null }
}

# one socket for the requests and the reads: the NAT of this computer keeps one mapping for them. No error of an ICMP that came
# back: Windows would end the next receive with it. The knocks go from the port the dialing goes from: see Pick
$udp = New-Object Net.Sockets.UdpClient(0)
try { [void]$udp.Client.IOControl(-1744830452, [byte[]](0, 0, 0, 0), $null) } catch { }
$udp.Client.ReceiveTimeout = 1000
$random = [Security.Cryptography.RandomNumberGenerator]::Create()
$id = New-Object byte[] 8
$random.GetBytes($id)

# the address the relay sees this computer at, 4 bytes - a bind is made for it; none yet: 0.0.0.0. And the knock: the key of the
# knocks of the port, 16 bytes the key makes of the id, the port and that address - made at each bind
[byte[]]$as = 0, 0, 0, 0
[byte[]]$knock = @()

# The answer from $to to what was sent there that $taken takes, within a second; $null - none. What it does not take - of
# another length, not signed by the key - is passed over, and the wait goes on: a packet sent in the name of the relay by
# someone else, there before the answer, does not take its place
function Answer($to, [scriptblock]$taken) {
    $until = [DateTime]::UtcNow.AddSeconds(1)
    while ([DateTime]::UtcNow -lt $until) {
        try {
            $from = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
            $got = $udp.Receive([ref]$from)
            if ($from.Equals($to) -and (& $taken $got)) { return , $got }
        } catch { return $null }
    }
    return $null
}

# Where the relay is now: @{ ip; port - its first port -; name - in the line for the client }. Its name looked up again; or, of
# a changing address, read from its keepers in turn - an answer written within 2 minutes taken at once, else the freshest. A
# read: the id of the key of reading and 8 random bytes; the answer is taken only when that key signed it with them - the address
# of the relay from anyone else would send this server, and its binds, to another computer. $null - not found.
function Locate {
    if (-not $p.reads) {
        $ip = Resolve-IP $p.host
        if (-not $ip) { return $null }
        return @{ ip = $ip; port = $p.port; name = $p.host }
    }
    $best = $null
    foreach ($r in $p.reads) {
        $ip = Resolve-IP $r[1]
        if (-not $ip) { continue }
        $to = New-Object Net.IPEndPoint($ip, [int]$r[2])
        $got = $null
        for ($i = 0; $i -lt 3 -and -not $got; $i++) {
            $nonce = New-Object byte[] 8
            $random.GetBytes($nonce)
            [byte[]]$read = Read-Packet $r[0] $nonce
            # no way out now - the network of this computer is down -: none of it is an answer
            try { [void]$udp.Send($read, $read.Length, $to) } catch { break }
            $key = $r[0]
            $got = Answer $to { param([byte[]]$g) $g.Length -eq 13 -and (Same (Read-Said $key $nonce ([byte[]]$g[0..4])) ([byte[]]$g[5..12])) }
        }
        if (-not $got) { continue }
        # the address, the minutes since the relay last wrote it; its port is of the line
        $at = [Net.IPAddress]::new([byte[]]$got[0..3])
        $found = @{ ip = $at; port = $p.port; name = "$at"; age = [int]$got[4] }
        if ($found.age -le 2) { return $found }
        if (-not $best -or $found.age -lt $best.age) { $best = $found }
    }
    return $best
}

# The times of the relay, as its answer to a bind says them: how often to knock, seconds - the relay keeps the port open `wait`
# seconds after a knock, 60 by default: two may be lost -; how long a try of dialing is, seconds - Windows sends its SYN again
# within it, after 1, 3, 7 and 15 s, and the next try comes at once: the relay knows where the server waits a little longer than
# the longest time between two SYNs -; how often to bind anew, minutes. As they are by default till the first answer
$KnockEvery = 20; $TryFor = 31; $Rebind = 30

# A port of meeting bound at the relay, up to $tries requests - 10 at the start; 3 while it waits: the relay forgets where the
# server dials from soon, and nothing dials meanwhile. A bind: the id of the key, the id of this start, and what the key says
# of "bind", that id and the address the relay sees this computer at. Made for another address, the relay answers the address
# - 4 bytes -, and the bind is made again for it; else the port, 2 bytes, the address and the times of the relay, 3 bytes.
# Either way with 8 bytes the key makes of the answer: one the key did not sign is not taken - it would send this server, and
# the line it gives to its clients, to a port of someone else. The same id gets the port it holds again. The key of the knocks
# is made anew with them. 0 - no answer.
function Ask($at, [int]$tries = 10) {
    $to = New-Object Net.IPEndPoint($at.ip, [int]$at.port)
    # one request more than asked: the first may only learn the address
    for ($i = 0; $i -le $tries; $i++) {
        [byte[]]$bind = Bind-Packet $p.key $id $script:as
        try { [void]$udp.Send($bind, $bind.Length, $to) } catch { return 0 }
        $got = Answer $to {
            param([byte[]]$g)
            if ($g.Length -eq 12) { return Same (Seen-Said $p.key $id ([byte[]]$g[0..3])) ([byte[]]$g[4..11]) }
            return $g.Length -eq 17 -and (Same (Bound-Said $p.key $id ([byte[]]$g[0..1]) ([byte[]]$g[2..5]) ([byte[]]$g[6..8])) ([byte[]]$g[9..16]))
        }
        if (-not $got) { continue }
        if ($got.Length -eq 12) { $script:as = [byte[]]$got[0..3]; continue }
        $script:as = [byte[]]$got[2..5]
        # a time of 0 would knock, dial or bind without end: as by default then
        $script:KnockEvery = $(if ($got[6]) { [int]$got[6] } else { 20 })
        $script:TryFor = $(if ($got[7]) { [int]$got[7] } else { 31 })
        $script:Rebind = $(if ($got[8]) { [int]$got[8] } else { 30 })
        $script:knock = Knock-Key $p.key $id ([byte[]]$got[0..1]) $script:as
        if ($Call) { $script:knock = [byte[]]($script:knock + $Call) }
        return $got[0] * 256 + $got[1]
    }
    return 0
}

$keepers = ''
if ($p.reads) { $keepers = ($p.reads | ForEach-Object { "$($_[1]):$($_[2])" }) -join ', ' }
$at = Locate
while (-not $at) {
    if (-not $p.reads) { Fail "The relay $($p.host): no such address" }
    Say '❌' bad "No address of the relay from ${keepers}: a wrong key of reading, the relay has not written its address there yet, or this address is blocked for wrong keys. Again in 5 s"
    Start-Sleep 5
    $at = Locate
}
$port = Ask $at
if (-not $port) { Fail "No port of meeting from $($at.name):$($at.port): a wrong key, a wrong first port - the line of a fixed port has the first port of the relay too, copy it again - or this address is blocked for wrong keys" }

# The line for the client, in a box and in the clipboard, and how its program takes it.
function Show {
    $line = "$($at.name):$port"
    $bar = '─' * ($line.Length + 4)
    Write-Host
    Say '📨' news 'Send this line to whoever connects:'
    Write-Host "    ╭$bar╮" -ForegroundColor DarkGray
    Write-Host '    │  ' -NoNewline -ForegroundColor DarkGray; Write-Host $line -NoNewline -ForegroundColor Green; Write-Host '  │' -ForegroundColor DarkGray
    Write-Host "    ╰$bar╯" -ForegroundColor DarkGray
    try { Set-Clipboard -Value $line; Say '📋' good 'It is in your clipboard already: just paste it into a message' } catch { }
    # with a token the program of the client dials AdHoc Relay Client, on its own computer: it listens at the port of meeting
    # there, unless told another
    $reach = $line; $reachHost = $at.name
    if ($Token) {
        # the first port of the relay, when it is not 40000: AdHoc Relay Client asks STUN there - as perl and as PowerShell take it
        $firstPl = ''; $firstPs = ''
        if ($at.port -ne 40000) { $firstPl = " --first $($at.port)"; $firstPs = " -First $($at.port)" }
        Say '🎫' news "The token, with the line: $Token - only AdHoc Relay Client gets in; a program that dials the line itself is cut off"
        Say '🧩' news "AdHoc Relay Client on the client: adhoc-relay-client.cmd -Meet $line -Token $Token -Listen $port$firstPs · Linux, macOS: perl adhoc-relay-client.pl --meet $line --token $Token --listen $port$firstPl"
        $reach = "127.0.0.1:$port"; $reachHost = '127.0.0.1'
    }
    if ($isRdp) { Say '🖥️' news "Remote Desktop Connection ( mstsc ) of the client: as the computer, $reach" }
    elseif ($toPort -eq '22') { Say '🔐' news "On the client: ssh -p $port <user>@$reachHost" }
    elseif ($toPort -eq '80') { Say '🌐' news "A browser of the client: http://$reach" }
    else { Say '🔗' news "A program of the client reaches $to at $reach" }
    Write-Host
}
Show
Say '👀' wait 'Waiting for whoever connects…'

# ── passing the bytes ──

# Both ways of a pair of connections at once, each on a thread of its own: Socket.Receive fills one buffer of 256 KB, allocated
# once, and Socket.Send sends that very slice of it, from an offset till all of it is gone - no stream over the sockets, no copy
# into another buffer, nothing allocated per read. .NET has nothing that passes one socket to another inside the system - its
# TransmitFile sends a file -, so one pass through this buffer is the least there is. A blocking way each: one that waits for its
# other end to take the bytes holds nothing of the other. A way that ends ends the sending of its other end only: a program that
# sends, ends its sending and waits for the answer gets it; a way that fails ends both connections, and so the other way too.
# The buffers of the sockets are left to the system: Windows and Linux grow them as the connection needs - to megabytes on a
# far one -, and a size set by a program turns that off. In C#, compiled once at the start: PowerShell itself would take its
# own time for each piece
$PassSource = @'
using System;
using System.Net.Sockets;
using System.Threading.Tasks;
public static class AdHocRelayPass {
    static void One(Socket from, Socket to) {
        byte[] buf = new byte[262144];
        bool ended = false;
        try {
            while (true) {
                int n = from.Receive(buf, 0, buf.Length, SocketFlags.None);
                if (n <= 0) { ended = true; break; }
                for (int off = 0; off < n; ) off += to.Send(buf, off, n - off, SocketFlags.None);
            }
        } catch (Exception) { }
        if (ended) { try { to.Shutdown(SocketShutdown.Send); } catch (Exception) { } return; }
        try { from.Shutdown(SocketShutdown.Both); } catch (Exception) { }
        try { to.Shutdown(SocketShutdown.Both); } catch (Exception) { }
    }
    public static Task Both(Socket a, Socket b) {
        Task up = Task.Factory.StartNew(() => One(a, b), TaskCreationOptions.LongRunning);
        Task down = Task.Factory.StartNew(() => One(b, a), TaskCreationOptions.LongRunning);
        return Task.WhenAll(up, down);
    }
}
'@
if (-not ('AdHocRelayPass' -as [type])) { Add-Type -TypeDefinition $PassSource }

# the connections joined now, each pair passed both ways by AdHocRelayPass; a pair that ended goes
$pairs = New-Object Collections.ArrayList
# a pair that ended sets it, from the thread of its way, and so does a connection that brought its token: the loop that waits
# wakes at once
$wake = New-Object Threading.ManualResetEventSlim
$wakeSet = [Delegate]::CreateDelegate([Action], $wake, 'Set')
# as many joined at once, no more: the port of meeting is open to anyone, and each one who comes and stays silent would hold a
# connection to the service for ever
$MaxJoined = 64
# with a token, the connections that met and are read for it: 16 bytes within 10 s, or cut off
$checking = New-Object Collections.ArrayList
function Tend {
    foreach ($c in @($checking)) {
        if ($c.read.IsCompleted) {
            $n = 0
            if ($c.read.Status -eq 'RanToCompletion') { $n = $c.read.Result }
            $c.got += $n
            if ($n -gt 0 -and $c.got -lt 16) {
                $c.read = $c.stream.ReadAsync($c.buf, $c.got, 16 - $c.got)
                $c.read.GetAwaiter().OnCompleted($wakeSet)
                continue
            }
            $checking.Remove($c)
            if ($c.got -eq 16 -and $Ascii.GetString($c.buf) -ceq $Token) { Join-To $c.sock $c.way }
            else { $c.sock.Close(); Say '🚫' warn "Someone came $($c.way) without the token: cut off" }
        } elseif ([DateTime]::UtcNow -gt $c.until) {
            $checking.Remove($c)
            $c.sock.Close()
            Say '🚫' warn "Someone came $($c.way) without the token: cut off"
        }
    }
    if ($pairs.Count -eq 0) { return }
    foreach ($q in @($pairs)) {
        if (-not $q.done.IsCompleted) { continue }
        $q.came.Close(); $q.there.Close()
        $pairs.Remove($q)
        Say '👋' quiet 'Gone, the one who came'
    }
}

# A connection that met, joined to the service. `way`: how it came, through the relay or directly - said with a token
function Join-To($came, [string]$way) {
    if ($pairs.Count -ge $MaxJoined) { $came.Close(); Say '⚠️' warn "$MaxJoined connections are joined already: one more turned away"; return }
    $there = Dial-Server
    if (-not $there) { $came.Close(); Say '❌' bad "Someone came; nothing answers at $to"; return }
    if ($Token) { Say '✅' good "Someone came ${way}: joined to $to" } else { Say '✅' good "Someone came: joined to $to" }
    $came.NoDelay = $true
    $there.NoDelay = $true
    # Keepalive on the connection that met: on, after 60 s of silence, a probe each 10 s. A client that is gone without a word
    # - a laptop closed - is found, and its connection to the service ended; and a session that is silent stays known to the
    # NATs on the way and to the relay, which forget a silent connection in minutes
    try { [void]$came.IOControl([Net.Sockets.IOControlCode]::KeepAliveValues, [byte[]](1, 0, 0, 0, 0x60, 0xEA, 0, 0, 0x10, 0x27, 0, 0), $null) } catch { }
    $done = [AdHocRelayPass]::Both($came, $there.Client)
    $done.GetAwaiter().OnCompleted($wakeSet)
    [void]$pairs.Add(@{ came = $came; there = $there; done = $done })
    # how many are joined now, of those there may be: said from the second on
    if ($pairs.Count -gt 1) { Say '👥' quiet "$($pairs.Count) of $MaxJoined connections joined now" }
}

# the local port the dialing goes from: kept till someone comes - the relay that moves too knows the server by it. The knocks
# go from a UDP socket bound to its number: a NAT that keeps the port shows the relay one port in both, and the relay knows the
# server by it - a client behind the same NAT is never taken for the server
$from = 0
$knocker = $null

# The dialing has met someone and is finishing it: the state of the socket is SYN received or established. Windows: SIO_TCP_INFO,
# the state first; Linux: TCP_INFO, its first byte. Elsewhere, or when the system says nothing - no.
function Meeting($s) {
    try {
        if ($IsLinux) {
            $info = New-Object byte[] 256
            return $s.GetRawSocketOption(6, 11, $info) -gt 0 -and ($info[0] -eq 1 -or $info[0] -eq 3)
        }
        if ($env:OS -eq 'Windows_NT') {
            $info = New-Object byte[] 256
            $n = $s.IOControl([int]-671088601, [BitConverter]::GetBytes([int]0), $info) # SIO_TCP_INFO, 0xD8000027
            $state = [BitConverter]::ToInt32($info, 0)
            return $n -ge 4 -and ($state -eq 3 -or $state -eq 4)
        }
    } catch { }
    return $false
}

# ── the direct way, with a token ──

# Where this server can be reached from its local port now, @{ pub; lan; v6 }, each @( address, port ) or $null; learnt at each
# new local port. The sockets of the knocks of the local ports before, 6 s each: the relay sends a call to where the server
# dialed it from up to 5 s before - it cannot change that from the path of a packet -, and they answer it there too. The client
# that called, where it is dialed - @{ how; to; local; sock; at; done } each -, till $until
$me = $null
$old = New-Object Collections.ArrayList
$targets = @()
$until = [DateTime]::MinValue

# The error of a socket a failure carries, as its name: WouldBlock, ConnectionRefused; '' - none
function Why($e) {
    $x = $e.Exception
    while ($x) { if ($x -is [Net.Sockets.SocketException]) { return "$($x.SocketErrorCode)" }; $x = $x.InnerException }
    return ''
}

# The address and the port the relay sees a UDP socket at, by STUN at its first port: a Binding Request of RFC 8489, the answer
# its XOR-MAPPED-ADDRESS, 32 bytes. Up to $tries requests, $ms milliseconds each. @( address, port ); $null - no answer
function Stun($u, [int]$tries, [int]$ms) {
    $to = New-Object Net.IPEndPoint($at.ip, [int]$at.port)
    $tx = New-Object byte[] 12
    $random.GetBytes($tx)
    [byte[]]$ask = [byte[]](0, 1, 0, 0, 0x21, 0x12, 0xa4, 0x42) + $tx
    [byte[]]$kind = 0, 0x20, 0, 8, 0, 1
    $buf = New-Object byte[] 64
    for ($i = 0; $i -lt $tries; $i++) {
        try { [void]$u.Client.SendTo($ask, $to) } catch { return $null }
        $end = [DateTime]::UtcNow.AddMilliseconds($ms)
        while (($left = ($end - [DateTime]::UtcNow).TotalMilliseconds) -gt 0) {
            if (-not $u.Client.Poll([int]($left * 1000), [Net.Sockets.SelectMode]::SelectRead)) { break }
            [Net.EndPoint]$back = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
            try { $n = $u.Client.ReceiveFrom($buf, [ref]$back) } catch { continue }
            if ($n -ne 32 -or -not $back.Equals($to) -or -not (Same ([byte[]]$buf[8..19]) $tx) -or -not (Same ([byte[]]$buf[20..25]) $kind)) { continue }
            $ip = [Net.IPAddress]::new([byte[]](($buf[28] -bxor 0x21), ($buf[29] -bxor 0x12), ($buf[30] -bxor 0xa4), ($buf[31] -bxor 0x42)))
            return @("$ip", ((($buf[26] -bxor 0x21) * 256) + ($buf[27] -bxor 0x12)))
        }
    }
    return $null
}

# The address of this computer the way to the relay goes from; $null - none
function Lan-Of {
    $s = New-Object Net.Sockets.Socket('InterNetwork', 'Dgram', 'Udp')
    try { $s.Connect($at.ip, [int]$at.port); return "$(([Net.IPEndPoint]$s.LocalEndPoint).Address)" } catch { return $null } finally { $s.Close() }
}

# The IPv6 address of this computer the way out goes from; $null - none, of the link only, or of Teredo
function V6-Of {
    $s = New-Object Net.Sockets.Socket('InterNetworkV6', 'Dgram', 'Udp')
    try {
        $s.Connect([Net.IPAddress]::Parse('2001:db8::1'), 9)
        $a = ([Net.IPEndPoint]$s.LocalEndPoint).Address
        if ($a.IsIPv6LinkLocal -or $a.IsIPv6Teredo -or $a.IsIPv4MappedToIPv6 -or [Net.IPAddress]::IsLoopback($a)) { return $null }
        $a.ScopeId = 0
        return "$a"
    } catch { return $null } finally { $s.Close() }
}

# Where one can be reached, as the 30 bytes of a call and its answer - the public IPv4 and port, the LAN IPv4 and port, the IPv6
# and port, zeros for none -, and back
function Encode($w) {
    $b = New-Object byte[] 30
    foreach ($part in @(@('pub', 0, 4), @('lan', 6, 4), @('v6', 12, 16))) {
        $x = $w[$part[0]]
        if (-not $x) { continue }
        [Array]::Copy([Net.IPAddress]::Parse($x[0]).GetAddressBytes(), 0, $b, $part[1], $part[2])
        $b[$part[1] + $part[2]] = [byte]([int]$x[1] -shr 8); $b[$part[1] + $part[2] + 1] = [byte]([int]$x[1] -band 255)
    }
    return , $b
}
function Decode([byte[]]$b) {
    $w = @{ pub = $null; lan = $null; v6 = $null }
    foreach ($part in @(@('pub', 0, 4), @('lan', 6, 4), @('v6', 12, 16))) {
        [byte[]]$a = $b[$part[1]..($part[1] + $part[2] - 1)]
        if (-not ($a | Where-Object { $_ })) { continue }
        $w[$part[0]] = @("$([Net.IPAddress]::new($a))", ([int]$b[$part[1] + $part[2]] * 256 + $b[$part[1] + $part[2] + 1]))
    }
    return $w
}

# Where this server can be reached from the local port of the UDP socket $u: the public address and port, when its NAT keeps the
# local port - else none -, the LAN address, the IPv6 address. Two STUN requests of half a second: the knocks of this port wait
function Here($u, [int]$local) {
    $w = @{ pub = $null; lan = $null; v6 = $null }
    $pub = Stun $u 2 500
    if ($pub -and $pub[1] -eq $local) { $w.pub = $pub }
    $lan = Lan-Of
    if ($lan) { $w.lan = @($lan, $local) }
    $v6 = V6-Of
    if ($v6) { $w.v6 = @($v6, $local) }
    return $w
}

# Where to dial the other: IPv6 when both have it; behind one NAT - one public address - its LAN address, else its public one
function Targets($mine, $other) {
    $t = @()
    if ($mine.v6 -and $other.v6) { $t += @{ how = 'over IPv6'; to = $other.v6 } }
    if ($mine.pub -and $other.pub) {
        if ($mine.pub[0] -eq $other.pub[0]) { if ($other.lan) { $t += @{ how = 'in the LAN'; to = $other.lan } } }
        else { $t += @{ how = 'at its public address'; to = $other.pub } }
    }
    return , $t
}

# The targets as words: 203.0.113.5:51000 at its public address, [2001:db8::5]:51000 over IPv6
function Ways($ts) {
    return (@($ts) | ForEach-Object { $a = $_.to[0]; if ($a.Contains(':')) { $a = "[$a]" }; "${a}:$($_.to[1]) $($_.how)" }) -join ', '
}

# A TCP socket from the local port, dialing there, not waiting. $null - it could not
function Dial([int]$local, [string]$address, [int]$port) {
    $ip = [Net.IPAddress]::Parse($address)
    $s = New-Object Net.Sockets.Socket($ip.AddressFamily, 'Stream', 'Tcp')
    try {
        $s.SetSocketOption('Socket', 'ReuseAddress', $true)
        if ($ip.AddressFamily -eq 'InterNetworkV6') { $s.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::IPv6Any, $local))) }
        else { $s.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::Any, $local))) }
        $s.Blocking = $false
        try { $s.Connect($ip, $port) } catch { if ((Why $_) -notin 'WouldBlock', 'InProgress') { throw } }
        return $s
    } catch { $s.Close(); return $null }
}

# A dialing socket that nothing came back to yet: SYN sent. Windows: SIO_TCP_INFO, the state first; Linux: TCP_INFO, its first
# byte. When the system says nothing - as SYN sent
function Sent($s) {
    try {
        $info = New-Object byte[] 256
        if ($IsLinux) { if ($s.GetRawSocketOption(6, 11, $info) -gt 0) { return $info[0] -eq 2 } }
        elseif ($env:OS -eq 'Windows_NT') { if ($s.IOControl([int]-671088601, [BitConverter]::GetBytes([int]0), $info) -ge 4) { return [BitConverter]::ToInt32($info, 0) -eq 2 } }
    } catch { }
    return $true
}

# The dialing of a target: one socket; a new one each 300 ms while nothing came back, and at once after a refusal. The first SYN
# of one may reach the router of the other before that router saw the SYN of its own side; the next one meets. Connected: read
# for the token, as any connection
function Punch($t) {
    if ($t.done) { return }
    if ($t.sock) {
        $done = $t.sock.Poll(0, [Net.Sockets.SelectMode]::SelectWrite)
        if ($done -or $t.sock.Poll(0, [Net.Sockets.SelectMode]::SelectError)) {
            $s = $t.sock; $t.sock = $null
            if ($done -and [int]$s.GetSocketOption('Socket', 'Error') -eq 0) {
                $t.done = $true
                $s.Blocking = $true
                Check-Token $s "directly, $(Ways $t)"
                return
            }
            $s.Close()
        } elseif (([DateTime]::UtcNow - $t.at).TotalMilliseconds -ge 300 -and (Sent $t.sock)) { $t.sock.Close(); $t.sock = $null }
    }
    if (-not $t.sock) { $t.sock = Dial $t.local $t.to[0] $t.to[1]; $t.at = [DateTime]::UtcNow }
}

# A connection that met, read for its token before it is joined - the program of the client that dials the port of meeting itself
# sends none, nor does a guesser, nor a way of the client other than the one it kept
function Check-Token($s, [string]$way) {
    if ($pairs.Count + $checking.Count -ge $MaxJoined) { $s.Close(); Say '⚠️' warn "$MaxJoined connections are joined already: one more turned away"; return }
    $c = @{ sock = $s; way = $way; got = 0; buf = (New-Object byte[] 16); until = [DateTime]::UtcNow.AddSeconds(10) }
    $c.stream = New-Object Net.Sockets.NetworkStream($s, $false)
    $c.read = $c.stream.ReadAsync($c.buf, 0, 16)
    $c.read.GetAwaiter().OnCompleted($wakeSet)
    [void]$checking.Add($c)
}

# The calls the sockets of the knocks heard - 38 bytes from the port of meeting, the key of a call first -: each answered by the
# socket that heard it with where this server can be reached, and the client dialed where it can be, 3 s. $false - the socket of
# the knocks heard a refusal: the relay knows the key of the knocks from another address
function Calls {
    foreach ($s in @($knocker) + @($old | ForEach-Object { $_.sock })) {
        while ($true) {
            try {
                if (-not $s.Client.Poll(0, [Net.Sockets.SelectMode]::SelectRead)) { break }
                $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
                $got = $s.Receive([ref]$ep)
            } catch { if ($s -eq $knocker) { return $false }; break }
            if ($got.Length -ne 38 -or -not $me -or -not (Same ([byte[]]$got[0..7]) $Call)) { continue }
            [byte[]]$answer = Encode $me
            try { [void]$s.Send($answer, $answer.Length) } catch { }
            foreach ($t in $targets) { if ($t.sock) { $t.sock.Close() } }
            $script:targets = Targets $me (Decode ([byte[]]$got[8..37]))
            foreach ($t in $targets) { $t.local = $from; $t.sock = $null; $t.at = [DateTime]::MinValue; $t.done = $false }
            $script:until = [DateTime]::UtcNow.AddSeconds(3)
            if ($targets.Count) { Say '📞' quiet "A client called: dialing it, $(Ways $targets)" }
            else { Say '📞' quiet 'A client called: nowhere to dial it - it meets this server through the relay' }
        }
    }
    return $true
}

# With a token, a look at the calls and the dialings of the client that called; the sockets of the knocks before let go after
# their 6 s. $false - a knock refused
function Direct {
    $now = [DateTime]::UtcNow
    foreach ($o in @($old)) { if ($o.until -le $now) { $o.sock.Close(); $old.Remove($o) } }
    if ($targets.Count -and $now -ge $until) { foreach ($t in $targets) { if ($t.sock) { $t.sock.Close() } }; $script:targets = @() }
    if (-not (Calls)) { return $false }
    foreach ($t in $targets) { Punch $t }
    return $true
}

# A local port for the knocks and the dialing both: free for UDP and for TCP; 0 - none now. With a token, where this server can be
# reached from it is learnt at once, and the socket of the knocks before answers calls 6 s more
function Pick {
    for ($i = 0; $i -lt 20; $i++) {
        # a port at random of the dynamic ones, 49152-65535: Windows keeps blocks of a hundred ports from TCP and from UDP - Hyper-V,
        # WSL, Docker reserve them -, and the ports it gives by itself, one after another, run into such a block now and then: a
        # port free for UDP, refused to TCP, many picks in a row
        $n = Get-Random -Minimum 49152 -Maximum 65536
        try { $u = New-Object Net.Sockets.UdpClient($n) } catch { continue }
        $t = New-Object Net.Sockets.Socket('InterNetwork', 'Stream', 'Tcp')
        try { $t.SetSocketOption('Socket', 'ReuseAddress', $true); $t.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::Any, $n))); $free = $true }
        catch { $free = $false }
        $t.Close()
        if (-not $free) { $u.Close(); continue }
        # a refusal of the relay is heard by this socket: the knock came from another address than the relay knows
        if ($script:knocker -and $Call) { [void]$old.Add(@{ sock = $script:knocker; until = [DateTime]::UtcNow.AddSeconds(6) }) }
        elseif ($script:knocker) { $script:knocker.Close() }
        $script:knocker = $u
        $script:from = $n
        if ($Call) { $script:me = Here $u $n }
        return $n
    }
    return 0
}
# The knock goes every $KnockEvery seconds, and at once at a new address, after a meeting, or when the port refused: the fewer
# packets with the key, the less there is to watch. A try of dialing waits up to $TryFor seconds, the next comes at once.
$knocked = [DateTime]::MinValue
# the port of meeting is not sure at the address of now: asked again at the next look. And every $Rebind minutes anyway: a relay that
# drops the SYN to a closed port, not refuses it, never says it forgot the port
$unsure = $false
$look = [DateTime]::UtcNow.AddSeconds(30)
$renew = [DateTime]::UtcNow.AddMinutes($Rebind)
# The port of meeting refused 3 times in a row, knocked at each time: the relay may know the port no more - it started again, or the
# server knocked not for long. It is asked again then, with the same id: the same port while the relay knows it, else a new one
$refusals = 0; $lost = $false
while ($true) {
    $dial = New-Object Net.IPEndPoint($at.ip, [int]$port)
    # knocks and dials till someone comes, from one local port: the NAT keeps one mapping; the next one from a new local port
    $met = $false
    # the port refused 3 times now: out of the loop once, to ask for it again - not after each try that follows
    $again = $false
    # the clock of this computer put back - set by the network at its start, a machine resumed -: what was to be done later is
    # due now, not in an hour
    if ($look -gt [DateTime]::UtcNow.AddSeconds(30)) { $look = [DateTime]::UtcNow }
    if ($renew -gt [DateTime]::UtcNow.AddMinutes($Rebind)) { $renew = [DateTime]::UtcNow }
    while (-not $met -and [DateTime]::UtcNow -lt $look) {
        Tend
        if (-not $from -and -not (Pick)) { Say '❌' bad 'No free local port'; Start-Sleep 1; continue }
        if ($knocked -gt [DateTime]::UtcNow) { $knocked = [DateTime]::MinValue }
        # A knock refused - the socket of the knocks, connected to the port of meeting, has it to read: the relay knows the key
        # of the knocks, but from another address than this computer has now. Bound again at once, for where it is
        # With a token what it heard may be a call too: answered
        if ($Call -and $knocker.Client.Connected) { if (-not (Direct)) { $lost = $true; $knocked = [DateTime]::MinValue; break } }
        else {
            try {
                if ($knocker.Client.Connected -and $knocker.Client.Poll(0, [Net.Sockets.SelectMode]::SelectRead)) {
                    $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
                    [void]$knocker.Receive([ref]$ep)
                }
            } catch { $lost = $true; $knocked = [DateTime]::MinValue; break }
        }
        if (([DateTime]::UtcNow - $knocked).TotalSeconds -ge $KnockEvery) {
            # no way out now - Wi-Fi joining again, the cable out, the computer waking -: no knock went, nothing is dialed after
            # it; again in a moment. The script waits on, it does not end
            try { $knocker.Connect($dial); [void]$knocker.Send($knock, $knock.Length); $knocked = [DateTime]::UtcNow }
            catch { Start-Sleep 2; continue }
        }
        $started = [DateTime]::UtcNow
        $tcp = New-Object Net.Sockets.Socket('InterNetwork', 'Stream', 'Tcp')
        try {
            $tcp.SetSocketOption('Socket', 'ReuseAddress', $true)
            $tcp.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::Any, $from)))
            $from = $tcp.LocalEndPoint.Port
            $try = $tcp.BeginConnect($dial, $null, $null)
        } catch {
            # the local port cannot be dialed from: a new one, with its knock
            $tcp.Close(); $from = 0; $knocked = [DateTime]::MinValue; Start-Sleep 1; continue
        }
        # till the try ends, $TryFor seconds at most - whole, past the look at the relay too: one cut short is one more try, and
        # its SYNs, those of the start a second apart, are most of them; the look waits for its end. The connections joined are
        # tended meanwhile - at once when a way of one ends. With a token the calls are looked at each 100 ms, and the client that
        # called is dialed each 20 ms
        $end = [DateTime]::UtcNow.AddSeconds($TryFor)
        $waits = [Threading.WaitHandle[]]@($try.AsyncWaitHandle, $wake.WaitHandle)
        while (-not $try.IsCompleted) {
            $ms = [int]($end - [DateTime]::UtcNow).TotalMilliseconds
            if ($ms -le 0) { break }
            $most = 1000
            if ($Call) { $most = $(if ($targets.Count) { 20 } else { 100 }) }
            if ($ms -gt $most) { $ms = $most }
            if ([Threading.WaitHandle]::WaitAny($waits, $ms) -eq 1) { $wake.Reset() }
            Tend
            if ($Call -and -not (Direct)) { $lost = $true; $again = $true; $knocked = [DateTime]::MinValue; break }
            # A try may be longer than the time between two knocks: knocked meanwhile as each is due - the NAT of this computer
            # must keep the mapping of the knocks -, and a knock refused heard then: bound again at once
            if (([DateTime]::UtcNow - $knocked).TotalSeconds -ge $KnockEvery) {
                try {
                    if ($knocker.Client.Poll(0, [Net.Sockets.SelectMode]::SelectRead)) {
                        $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
                        [void]$knocker.Receive([ref]$ep)
                    }
                } catch { $lost = $true; $again = $true; $knocked = [DateTime]::MinValue; break }
                try { [void]$knocker.Send($knock, $knock.Length); $knocked = [DateTime]::UtcNow } catch { }
            }
        }
        # a meeting that came at the end of the try is under way - the SYN of the client here, its answer not yet back -: closed now,
        # it would end the connection the client already has. It is given the time to come
        $began = (-not $try.IsCompleted) -and (Meeting $tcp)
        if ($began) { [void]$try.AsyncWaitHandle.WaitOne(2000) }
        if ($try.IsCompleted) {
            try { $tcp.EndConnect($try); $met = $true }
            # refused: the port is not open - the knock was lost, or came too late -: knocked again at once
            catch {
                $why = $null
                if ($_.Exception.InnerException) { $why = "$($_.Exception.InnerException.SocketErrorCode)" }
                # a connection of a meeting before still lives at this local port: it cannot dial the same port of the relay again
                if ($why -eq 'AddressAlreadyInUse') { $from = 0; $knocked = [DateTime]::MinValue }
                # the relay refused: knocked again at once; 3 times in a row - it may know the port no more. The network down is
                # no refusal: no knock with the key each 2 s for it
                elseif ($why -eq 'ConnectionRefused' -or $why -eq 'ConnectionReset') {
                    $knocked = [DateTime]::MinValue
                    if ($why -eq 'ConnectionRefused' -and ++$refusals -ge 3) { $refusals = 0; $lost = $true; $again = $true }
                }
            }
        } else {
            $refusals = 0 # the port is open, the server waits at it: the row of refusals is over
            # A meeting began and did not come - a SYN of someone who went no further. For the relay it is a meeting all the same:
            # the port is closed, and what it keeps of it is of this local port - a new try from it would be taken for that
            # meeting still. A new local port, and its knock, as after a meeting
            if ($began) { $from = 0; $knocked = [DateTime]::MinValue }
        }
        # the meeting closed the port: the next try knocks at once
        if ($met) {
            if ($Call) { Check-Token $tcp 'through the relay' } else { Join-To $tcp }
            $from = 0; $knocked = [DateTime]::MinValue; $refusals = 0; break
        }
        $tcp.Close()
        if ($again) { break }
        # refused at once, or the network is down: a pause, not a storm of tries - 2 s at most, whatever the clock says
        $rest = [Math]::Min(2000, 2000 - ([DateTime]::UtcNow - $started).TotalMilliseconds)
        if ($rest -gt 0 -and $wake.Wait([int]$rest)) { $wake.Reset() }
    }
    if ($met) { continue }
    # every 30 s, at the end of the try then: where the relay is now - a dynamic address moves; its name looked up again, or its
    # address read again
    $look = [DateTime]::UtcNow.AddSeconds(30)
    $now = Locate
    if (-not $now) {
        if ($p.reads) { Say '⚠️' warn "No address of the relay from $keepers now: knocking on at the one of before" }
        else { Say '⚠️' warn "The relay $($p.host): no such address now: knocking on at the one of before" }
        # at the address of before: a port the relay there forgot is asked again all the same - the relay may be reached while
        # the one that keeps its address is not
        $now = $at
    }
    $moved = -not $now.ip.Equals($at.ip) -or $now.port -ne $at.port
    if (-not $moved -and -not $unsure -and -not $lost -and [DateTime]::UtcNow -lt $renew) { continue }
    $lost = $false; $renew = [DateTime]::UtcNow.AddMinutes($Rebind)
    $was = "$($at.name):$port"
    $at = $now
    $knocked = [DateTime]::MinValue
    $got = Ask $at 3
    if ($got) { $port = $got; $unsure = $false }
    else { $unsure = $true; Say '⚠️' warn "No port of meeting from $($at.name):$($at.port) now: knocking at $port there, asking again in 30 s" }
    if ("$($at.name):$port" -ne $was) {
        Say '🔀' news $(if ($moved) { 'The relay moved: the line for the client is new' } else { 'A new port of meeting: the line for the client is new' })
        Show
        Say '👀' wait 'Waiting for whoever connects…'
    } elseif ($moved) {
        Say '🔀' quiet "The relay moved to $($at.ip): the line for the client stays"
    }
}
