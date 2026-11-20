# AdHoc Relay, the server, on Windows: a service of this computer - Remote Desktop, SSH, VNC, a web server -, or of its network,
# reached by the client through a relay, with nothing to forward on the routers. The client uses its own program of that
# service, as with any address: Remote Desktop Connection, ssh, a VNC viewer, a browser. Nothing is installed there.
#
#   adhoc-relay-server.cmd                                                     a double click: asks, as a menu; the answers kept
#   powershell -ExecutionPolicy Bypass -File adhoc-relay-server.ps1 -Meet 'Tr7kQ2xZp4Lm9sWd👉router.example.org:40000👉' -Forward 3389
#
# The line of the password ends in 👉: an answer comes. It asks the relay for a port of meeting - the password and its id,
# 8 random bytes of this start -, prints the line for the client, the relay and that port, and from then on knocks at the port
# every 20 s and dials it, a try of up to 10 s after another, from one local port. Each connection that meets is joined to the server by .NET, both ways, the bytes as
# they are; the next one is awaited at once. A line with no 👉 at the end - Fx2pL8wNq7Rk3mZa👉router.example.org:41000 - is of a
# fixed port: no asking, its key alone knocks at it. A relay whose address changes has its address kept by others: the line
# names them, each with a key of reading, then the port of the relay -
# Fx2pL8wNq7Rk3mZa🌐Rk8mP2qLx3Vb7NtY👉203.0.113.7:40000🌐Hx4nT7wAc5Jd2QeL👉198.51.100.9:40000🌐41000 -, and the address is read
# there, again every 30 s. The signs may be typed as > and @. Windows PowerShell 5.1, as Windows has it, or PowerShell 7: nothing to
# install.

param([string]$Meet, [string]$Forward, [string]$Parse)

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
    foreach ($n in 'service', 'forward', 'meet', 'password') { if ($k[$n]) { $text += "$n = $($k[$n])`r`n" } }
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
    $l = [Console]::In.ReadLine()
    if ($null -eq $l) { exit 0 }
    return $l.Trim()
}

# Where the connections go, of what was typed: a port alone - of this computer -, or address:port. $null - neither.
function Target([string]$t) {
    $t = $t.Trim()
    if ($t -match '^\d+$' -and [int]$t -gt 0 -and [int]$t -lt 65536) { return "127.0.0.1:$t" }
    if ($t -match '^([^\s:]+):(\d+)$' -and [int]$Matches[2] -gt 0 -and [int]$Matches[2] -lt 65536) { return $t }
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

# A port: 1…65535.
function Port-Ok([string]$s) { return $s -match '^\d{1,5}$' -and [int]$s -ge 1 -and [int]$s -le 65535 }

# The relay as its owner gave it - the page of AdHoc Relay copies it so -, one of
#   <password>👉<point>[:<port of requests>]👉                            a port of meeting given at each start: an answer comes
#   <key>👉<point>:<port>                                                 a fixed port: its key alone opens it
#   <password>🌐<read>👉<keeper>:<its port>[🌐<read>👉<keeper>:<its port>...]🌐<port of requests>👉
#                                                                        a relay whose address changes: read from its keepers, in turn
#   <key>🌐<read>👉<keeper>:<its port>[🌐...]🌐<port>                       the same, of a fixed port
# or the relay alone, <point>[:<port of requests>], its password asked then. As @{ key; fixed; port; host } or @{ key;
# fixed; port; reads = @( @(key of reading, keeper, its port of requests), ... ) }: key $null when the line has none. $null - no
# such line.
function Point([string]$t) {
    $t = Plain $t
    $p = @{ key = $null; fixed = $false; reads = $null; host = $null; port = 40000 }
    $rest = $t
    $read = $false
    if ($t.IndexOfAny([char[]]'>@') -ge 0) {
        $ask = $t.EndsWith('>')
        if ($ask) { $t = $t.Substring(0, $t.Length - 1) }
        $i = $t.IndexOfAny([char[]]'>@')
        if ($i -lt 0) { return $null }
        if ($i -gt 0) { $p.key = $t.Substring(0, $i) }
        $read = $t[$i] -eq '@'
        $rest = $t.Substring($i + 1)
        $p.fixed = -not $ask
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
    if ($p.fixed -and -not $Matches[2]) { return $null }
    $p.host = $Matches[1]
    if ($Matches[2]) {
        if (-not (Port-Ok $Matches[2])) { return $null }
        $p.port = [int]$Matches[2]
    }
    return $p
}

# A password or a key: 16 letters and digits.
function Key-Ok([string]$k) { return $k -cmatch '^[A-Za-z0-9]{16}$' }

# The line without its key, as the menu keeps it, the signs of the keyboard: > first, or @ before each read and the port; > last
# when it asks for a port.
function Rest-Of($p) {
    if ($p.reads) { $where = (($p.reads | ForEach-Object { "@$($_[0])>$($_[1]):$($_[2])" }) -join '') + "@$($p.port)" }
    else { $where = ">$($p.host):$($p.port)" }
    if ($p.fixed) { return $where }
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

$Lines = "such as Tr7kQ2xZp4Lm9sWd${Arrow}router.example.org:40000${Arrow}, Fx2pL8wNq7Rk3mZa${Arrow}router.example.org:41000 - a fixed port -, or Fx2pL8wNq7Rk3mZa${Globe}Rk8mP2qLx3Vb7NtY${Arrow}203.0.113.7:40000${Globe}41000 - its address read there"

# what it makes of a line, and nothing more: docs/lines.tsv
if ($PSBoundParameters.ContainsKey('Parse')) { Parsed $Parse; exit 0 }

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
        if ($p.fixed) { $key = Read-Line 'The key of its fixed port, 16 letters and digits:' } else { $key = Read-Line 'Its password, 16 letters and digits:' }
        if (-not (Key-Ok $key)) {
            if ($p.fixed) { Say '💡' warn 'The key of a fixed port is 16 letters and digits' } else { Say '💡' warn 'The password of a relay is 16 letters and digits' }
        }
    }
    $k.service = "$service"
    if ($service -eq 5) { $k.forward = $to }
    $k.meet = Pretty $meet # kept as people see it: the emoji
    $k.password = $key
    Save-Kept $k
    Write-Host
    return @($to, "$key$meet")
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

if ($Forward -or $Meet) {
    if (-not ($Forward -and $Meet)) { Fail '-Meet and -Forward go together' }
    $to = Target $Forward
    if (-not $to) { Fail '-Forward <port> or <address:port>, such as 3389 or 192.168.1.5:80' }
    $given = $Meet
} else {
    $to, $given = Menu
}
$p = Point $given
if (-not $p -or -not (Key-Ok $p.key)) { Fail "-Meet <the line of the relay>, $Lines" }
$fixed = $p.fixed
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
$id = New-Object byte[] 8
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($id)
# the knock: the password and the id; at a fixed port its key alone
if ($fixed) { [byte[]]$knock = [Text.Encoding]::ASCII.GetBytes($p.key) }
else { [byte[]]$knock = [Text.Encoding]::ASCII.GetBytes($p.key) + $id }

# The answer of $length bytes from $to to what was sent there, within a second; $null - none.
function Answer($to, [int]$length) {
    $until = [DateTime]::UtcNow.AddSeconds(1)
    while ([DateTime]::UtcNow -lt $until) {
        try {
            $from = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
            $got = $udp.Receive([ref]$from)
            if ($got.Length -eq $length -and $from.Equals($to)) { return , $got }
        } catch { return $null }
    }
    return $null
}

# Where the relay is now: @{ ip; port - to ask or knock at -; name - in the line for the client }. Its name looked up
# again; or, of a changing address, read from its keepers in turn - an answer written within 2 minutes taken at once, else the
# freshest. $null - not found.
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
        [byte[]]$read = [Text.Encoding]::ASCII.GetBytes($r[0])
        $got = $null
        for ($i = 0; $i -lt 3 -and -not $got; $i++) {
            [void]$udp.Send($read, $read.Length, $to)
            $got = Answer $to 5
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

# A port of meeting from the relay: the password and the id to its port of requests, up to 10 times. The same id gets
# the port it holds again. 0 - no answer.
function Ask($at) {
    $to = New-Object Net.IPEndPoint($at.ip, [int]$at.port)
    for ($i = 0; $i -lt 10; $i++) {
        [void]$udp.Send($knock, $knock.Length, $to)
        $got = Answer $to 2
        if ($got) { return $got[0] * 256 + $got[1] }
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
if ($fixed) { $port = $at.port } else { $port = Ask $at }
if (-not $port) { Fail "No port of meeting from $($at.name):$($at.port): a wrong password, a wrong first port or this address is blocked for wrong knocks" }

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
    if ($isRdp) { Say '🖥️' news "Remote Desktop Connection ( mstsc ) of the client: as the computer, $line" }
    elseif ($toPort -eq '22') { Say '🔐' news "On the client: ssh -p $port <user>@$($at.name)" }
    elseif ($toPort -eq '80') { Say '🌐' news "A browser of the client: http://$line" }
    else { Say '🔗' news "A program of the client reaches $to at $line" }
    Write-Host
}
Show
if ($fixed) { Say '💡' quiet 'A fixed port answers no knock: if the client gets nothing, check the key with the owner of the relay' }
Say '👀' wait 'Waiting for whoever connects…'

# the connections joined now: each way a copy of .NET, on its own; a way that ended tells the other side, a pair that ended goes
$pairs = New-Object Collections.ArrayList
function Tend {
    foreach ($q in @($pairs)) {
        if ($q.up.IsCompleted -and -not $q.upShut) { try { $q.there.Client.Shutdown('Send') } catch { }; $q.upShut = $true }
        if ($q.down.IsCompleted -and -not $q.downShut) { try { $q.came.Shutdown('Send') } catch { }; $q.downShut = $true }
        if ($q.upShut -and $q.downShut) {
            $q.came.Close(); $q.there.Close()
            $pairs.Remove($q)
            Say '👋' quiet 'Gone, the one who came'
        }
    }
}

function Join-To($came) {
    $there = Dial-Server
    if (-not $there) { $came.Close(); Say '❌' bad "Someone came; nothing answers at $to"; return }
    Say '✅' good "Someone came: joined to $to"
    $came.NoDelay = $true
    $there.NoDelay = $true
    $a = New-Object Net.Sockets.NetworkStream($came, $false)
    $b = $there.GetStream()
    [void]$pairs.Add(@{ came = $came; there = $there; up = $a.CopyToAsync($b, 65536); down = $b.CopyToAsync($a, 65536); upShut = $false; downShut = $false })
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

# A local port for the knocks and the dialing both: free for UDP and for TCP; 0 - none now.
function Pick {
    for ($i = 0; $i -lt 20; $i++) {
        $u = New-Object Net.Sockets.UdpClient(0)
        $n = ([Net.IPEndPoint]$u.Client.LocalEndPoint).Port
        $t = New-Object Net.Sockets.Socket('InterNetwork', 'Stream', 'Tcp')
        try { $t.SetSocketOption('Socket', 'ReuseAddress', $true); $t.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::Any, $n))); $free = $true }
        catch { $free = $false }
        $t.Close()
        if (-not $free) { $u.Close(); continue }
        try { [void]$u.Client.IOControl(-1744830452, [byte[]](0, 0, 0, 0), $null) } catch { }
        if ($script:knocker) { $script:knocker.Close() }
        $script:knocker = $u
        $script:from = $n
        return $n
    }
    return 0
}
# The knock goes every $KnockEvery seconds - the relay keeps the port open `wait` seconds after it, 60 by default: two may be lost -,
# and at once at a new address, after a meeting, or when the port refused: the fewer packets with the key, the less there is to
# watch. A try of dialing waits up to $TryFor seconds - Windows sends its SYN again within it -, the next comes at once: the relay
# notes where the side that waits is for 5 s, and its tries note it anew.
$KnockEvery = 20; $TryFor = 3
$knocked = [DateTime]::MinValue
# the port of meeting is not sure at the address of now: asked again at the next look
$unsure = $false
$look = [DateTime]::UtcNow.AddSeconds(30)
while ($true) {
    $dial = New-Object Net.IPEndPoint($at.ip, [int]$port)
    # knocks and dials till someone comes, from one local port: the NAT keeps one mapping; the next one from a new local port
    $met = $false
    while (-not $met -and [DateTime]::UtcNow -lt $look) {
        Tend
        if (-not $from -and -not (Pick)) { Say '❌' bad 'No free local port'; Start-Sleep 1; continue }
        if (([DateTime]::UtcNow - $knocked).TotalSeconds -ge $KnockEvery) {
            [void]$knocker.Send($knock, $knock.Length, $dial)
            $knocked = [DateTime]::UtcNow
        }
        $started = [DateTime]::UtcNow
        $tcp = New-Object Net.Sockets.Socket('InterNetwork', 'Stream', 'Tcp')
        $tcp.SetSocketOption('Socket', 'ReuseAddress', $true)
        $tcp.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::Any, $from)))
        $from = $tcp.LocalEndPoint.Port
        $try = $tcp.BeginConnect($dial, $null, $null)
        # a second at a time: the connections joined are tended meanwhile
        for ($w = 0; $w -lt $TryFor -and -not $try.IsCompleted -and [DateTime]::UtcNow -lt $look; $w++) { [void]$try.AsyncWaitHandle.WaitOne(1000); Tend }
        # a meeting that came at the end of the try is under way - the SYN of the client here, its answer not yet back -: closed now,
        # it would end the connection the client already has. It is given the time to come
        if (-not $try.IsCompleted -and (Meeting $tcp)) { [void]$try.AsyncWaitHandle.WaitOne(2000) }
        if ($try.IsCompleted) {
            try { $tcp.EndConnect($try); $met = $true }
            # refused: the port is not open - the knock was lost, or came too late -: knocked again at once
            catch { $knocked = [DateTime]::MinValue }
        }
        # the meeting closed the port: the next try knocks at once
        if ($met) { Join-To $tcp; $from = 0; $knocked = [DateTime]::MinValue; break }
        $tcp.Close()
        # refused at once, or the network is down: a pause, not a storm of tries
        $rest = 2000 - ([DateTime]::UtcNow - $started).TotalMilliseconds
        if ($rest -gt 0) { Start-Sleep -Milliseconds ([int]$rest) }
    }
    if ($met) { continue }
    # every 30 s: where the relay is now - a dynamic address moves; its name looked up again, or its address read again
    $look = [DateTime]::UtcNow.AddSeconds(30)
    $now = Locate
    if (-not $now) {
        if ($p.reads) { Say '⚠️' warn "No address of the relay from $keepers now: knocking on at the one of before" }
        else { Say '⚠️' warn "The relay $($p.host): no such address now: knocking on at the one of before" }
        continue
    }
    $moved = -not $now.ip.Equals($at.ip) -or $now.port -ne $at.port
    if (-not $moved -and -not $unsure) { continue }
    $was = "$($at.name):$port"
    $at = $now
    $knocked = [DateTime]::MinValue
    if ($fixed) { $port = $at.port }
    else {
        $got = Ask $at
        if ($got) { $port = $got; $unsure = $false }
        else { $unsure = $true; Say '⚠️' warn "No port of meeting from $($at.name):$($at.port) now: knocking at $port there, asking again in 30 s" }
    }
    if ("$($at.name):$port" -ne $was) {
        Say '🔀' news 'The relay moved: the line for the client is new'
        Show
        Say '👀' wait 'Waiting for whoever connects…'
    } elseif ($moved) {
        Say '🔀' quiet "The relay moved to $($at.ip): the line for the client stays"
    }
}
