# AdHoc Relay Client, on Windows: an ordinary program of this computer - a WebSocket client, ssh, Remote Desktop
# Connection, a browser - reaches a server that waits at a relay, directly when the two can, through the relay when they cannot.
# The program can only dial an address: it dials this utility, on this computer, and the utility does the rest for it.
#
#   adhoc-relay-client.cmd                                                     a double click: asks, as a menu; the answers kept
#   powershell -ExecutionPolicy Bypass -File adhoc-relay-client.ps1 -Meet router.example.org:41933 -Token K7QM2XHP9RTA4WZD -Listen 41933
#
# -Meet is the line the server shows for its client: the relay and the port of meeting. -Token is the token of the server, 16
# letters and digits, the server gives it with the line. -Listen is where the program of this computer connects: a port of
# 127.0.0.1, or address:port. -First is the first port of the relay, 40000 unless given: it answers STUN there. -Wait is how long
# the two dial each other before the relay is taken, 2.5 s unless given.
#
# For each connection that comes, on a thread of its own: it learns where it can be reached - the address and the port the relay
# sees, by STUN at its first port, none when its NAT changes the port; its LAN address; its IPv6 address -, and calls the server
# at the port of meeting: the key of a call - 8 bytes of SHA-256 of "adhoc-relay call" and the token - and those 30 bytes. The
# relay sends the call on to the server, and its 30 bytes back. Both dial each other from the local ports they called and
# knocked from: over IPv6 when both have it, in their LAN when both are behind one NAT, else at their public addresses - a new SYN
# each 300 ms, and at once after a refusal. The first connection made is kept; nothing within -Wait, nothing to call with, the
# call refused or not answered: the relay, at the port of meeting, as any client. Either way the token goes first, then the
# bytes as they are, both ways. Without a token: through the relay, nothing written - as the program itself would dial the line.
# Windows PowerShell 5.1, as Windows has it, or PowerShell 7: nothing to install.

param([string]$Meet, [string]$Token, [string]$Listen, [string]$First, [string]$Wait)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

# ── the window: each kind of news with its sign and colour ──

$Tones = @{ good = 'Green'; news = 'Cyan'; wait = 'Yellow'; warn = 'DarkYellow'; bad = 'Red'; quiet = 'DarkGray'; key = 'Yellow'; name = 'White' }
function Say([string]$sign, [string]$tone, [string]$text) {
    Write-Host " $sign " -NoNewline
    Write-Host $text -ForegroundColor $Tones[$tone]
}

# ── what the menu keeps beside the script: key = value ──

$KeptFile = Join-Path $PSScriptRoot 'adhoc-relay-client.settings'

function Load-Kept {
    $k = @{}
    if (Test-Path $KeptFile) {
        foreach ($l in Get-Content $KeptFile -Encoding UTF8) { if ($l -match '^\s*(\w+)\s*=\s*(\S.*?)\s*$') { $k[$Matches[1]] = $Matches[2] } }
    }
    return $k
}

function Save-Kept($k) {
    $text = "# AdHoc Relay Client: what the menu offers on Enter`r`n"
    foreach ($n in 'meet', 'token', 'listen', 'first') { if ($k[$n]) { $text += "$n = $($k[$n])`r`n" } }
    try { [IO.File]::WriteAllText($KeptFile, $text) } catch { Say '💾' quiet "Not kept for the next start: $($_.Exception.Message)" }
}

function Read-Line([string]$prompt) {
    Write-Host " $prompt " -NoNewline -ForegroundColor Cyan
    if ([Console]::IsInputRedirected) { $l = [Console]::In.ReadLine() } else { $l = $Host.UI.ReadLine() }
    if ($null -eq $l) { exit 0 }
    return $l.Trim()
}

# A port: 1…65535, as a number is written - the digits of ASCII, no zeros in front.
function Port-Ok([string]$s) { return $s -match '^[1-9][0-9]{0,4}$' -and [int]$s -le 65535 }

# The line of the server for its client: the relay - a name or an IPv4 address - and the port of meeting. @( host, port ); $null
# - no such line
function Meet-Of([string]$t) {
    if ($t.Trim() -notmatch '^([^\s:@=,!?>]+):([0-9]+)$' -or -not (Port-Ok $Matches[2])) { return $null }
    return @($Matches[1], [int]$Matches[2])
}

# Where the program of this computer connects: a port alone - of 127.0.0.1 -, or address:port. @( address, port ); $null - neither
function Listen-Of([string]$t) {
    $t = $t.Trim()
    if (Port-Ok $t) { return @('127.0.0.1', [int]$t) }
    if ($t -match '^([^\s:]+):([0-9]+)$' -and (Port-Ok $Matches[2])) { return @($Matches[1], [int]$Matches[2]) }
    return $null
}

# A token: 16 letters and digits, as a key of the relay.
function Token-Ok([string]$t) { return $t -cmatch '^[A-Za-z0-9]{16}$' }

# ── the menu, when nothing was given ──

function Menu {
    $k = Load-Kept
    Write-Host
    while ($true) {
        if ($k.meet) { $typed = Read-Line "The line of the server - Enter for $($k.meet):" }
        else { $typed = Read-Line 'The line of the server, the relay and the port of meeting, such as router.example.org:41933:' }
        if (-not $typed -and $k.meet) { $typed = $k.meet }
        $m = Meet-Of $typed
        if ($m) { break }
        Say '💡' warn 'As the server shows it: a name or an address of the relay, :, the port of meeting'
    }
    while ($true) {
        if (Token-Ok $k.token) { $typed = Read-Line 'Its token - Enter for the one of last time, - for none:' }
        else { $typed = Read-Line 'Its token, 16 letters and digits - Enter for none: through the relay:' }
        if (-not $typed) { $t = $(if (Token-Ok $k.token) { $k.token } else { $null }) }
        elseif ($typed -eq '-') { $t = $null }
        else { $t = $typed }
        if (-not $t -or (Token-Ok $t)) { break }
        Say '💡' warn 'A token is 16 letters and digits, as the server shows it'
    }
    $suggest = $(if ($k.listen) { $k.listen } else { "$($m[1])" })
    while ($true) {
        $typed = Read-Line "The port the program of this computer connects to, of 127.0.0.1, or address:port - Enter for ${suggest}:"
        if (-not $typed) { $typed = $suggest }
        $l = Listen-Of $typed
        if ($l) { break }
        Say '💡' warn 'A port, such as 3390, or an address and a port, such as 0.0.0.0:3390'
    }
    # the first port matters to the direct way alone: STUN is asked there
    $f = $(if ($k.first) { $k.first } else { '40000' })
    if ($t) {
        while ($true) {
            $typed = Read-Line "The first port of the relay, where it answers STUN - Enter for ${f}:"
            if (-not $typed) { $typed = $f }
            if (Port-Ok $typed) { $f = $typed; break }
            Say '💡' warn 'A port: 1…65535, as its owner gave it - 40000 unless set otherwise'
        }
    }
    $k.meet = "$($m[0]):$($m[1])"
    $k.token = $t
    $k.listen = $(if ($l[0] -eq '127.0.0.1') { "$($l[1])" } else { "$($l[0]):$($l[1])" })
    $k.first = $f
    Save-Kept $k
    Write-Host
    return @($k.meet, $t, $k.listen, $f)
}

# ── the arguments, or the menu ──

Write-Host
Write-Host ' AdHoc Relay Client' -ForegroundColor White
Write-Host ' a program of this computer reaches a server at a relay: directly when the two can, else through the relay' -ForegroundColor DarkGray

# a failure, said: a window opened by a double click stays to be read
function Fail([string]$text) {
    Say '❌' bad $text
    if (-not [Console]::IsInputRedirected) { Write-Host; Write-Host ' Press Enter to close this window.' -ForegroundColor Cyan; [void][Console]::In.ReadLine() }
    exit 1
}
# whatever else fails, unforeseen: said the same way - not a window that closes with its reason unread
trap { Fail "$_" }

if ($Meet -or $Listen) {
    if (-not ($Meet -and $Listen)) { Fail '-Meet and -Listen go together' }
} else {
    if ($Token -or $First -or $Wait) { Fail '-Token, -First and -Wait go with -Meet and -Listen' }
    $Meet, $Token, $Listen, $First = Menu
}
$m = Meet-Of $Meet
if (-not $m) { Fail '-Meet <relay>:<port of meeting>, such as router.example.org:41933' }
$l = Listen-Of $Listen
if (-not $l) { Fail '-Listen <port> or <address:port>, such as 41933 or 0.0.0.0:41933' }
if ($Token -and -not (Token-Ok $Token)) { Fail '-Token <16 letters and digits>, such as K7QM2XHP9RTA4WZD' }
if (-not $First) { $First = '40000' }
if (-not (Port-Ok $First)) { Fail '-First <the first port of the relay>, such as 40000' }
$seconds = 2.5
if ($Wait -and -not ([double]::TryParse($Wait, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$seconds) -and $seconds -gt 0 -and $seconds -le 60)) { Fail '-Wait <seconds>, such as 2.5' }

# the key of a call of the token: what a call begins with, and what the knocks of the server carry - the first 8 bytes of SHA-256
# of "adhoc-relay call" and the token. The token itself goes only to the server, the first bytes of each connection
$Ascii = [Text.Encoding]::ASCII
$Call = $null
if ($Token) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $Call = [byte[]]($sha.ComputeHash($Ascii.GetBytes("adhoc-relay call$Token"))[0..7]) } finally { $sha.Dispose() }
}

# where the program of this computer connects: an address of this computer, as digits
$at = $null
if (-not [Net.IPAddress]::TryParse($(if ($l[0] -eq 'localhost') { '127.0.0.1' } else { $l[0] }), [ref]$at)) { Fail '-Listen <port> or <address:port>: the address as digits, such as 0.0.0.0:41933' }
$listener = New-Object Net.Sockets.TcpListener($at, $l[1])
try { $listener.Start(64) } catch { Fail "Cannot listen at $($l[0]):$($l[1]): $($_.Exception.InnerException.Message)" }

Say '🔌' good "Listening at $($l[0]):$($l[1]): a program of this computer connects there, and reaches the server at $($m[0]):$($m[1])"
if ($Token) { Say '🎫' news "With the token: directly when the two can, else through the relay; STUN at $($m[0]):$First, $seconds s to meet directly" }
else { Say '🎫' warn 'No token: each connection goes through the relay, as the program itself would dial the line' }
Say '👀' wait 'Waiting for the program of this computer…'

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

# ── each connection, on a thread of its own ──

# What a thread does with one connection of the program of this computer: the server met - directly, or through the relay -, the
# token written first, and the bytes passed both ways till both sides end, each end told the other. What it has to say goes to
# the window through `news`
$Work = {
    param($came, $c)
    $ErrorActionPreference = 'Stop'
    function Say([string]$sign, [string]$tone, [string]$text) { $c.news.Enqueue(@($sign, $tone, $text)) }
    function Same([byte[]]$a, [byte[]]$b) { return [Linq.Enumerable]::SequenceEqual($a, $b) }

    # The error of a socket a failure carries, as its name: WouldBlock, ConnectionRefused; '' - none
    function Why($e) {
        $x = $e.Exception
        while ($x) { if ($x -is [Net.Sockets.SocketException]) { return "$($x.SocketErrorCode)" }; $x = $x.InnerException }
        return ''
    }

    # The address and the port the relay sees a UDP socket at, by STUN at its first port: a Binding Request of RFC 8489, the
    # answer its XOR-MAPPED-ADDRESS, 32 bytes. Up to 3 requests, a second each. @( address, port ); $null - no answer
    function Stun($u) {
        $to = New-Object Net.IPEndPoint($c.ip, $c.first)
        $tx = New-Object byte[] 12
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($tx) } finally { $rng.Dispose() }
        [byte[]]$ask = [byte[]](0, 1, 0, 0, 0x21, 0x12, 0xa4, 0x42) + $tx
        [byte[]]$kind = 0, 0x20, 0, 8, 0, 1
        $buf = New-Object byte[] 64
        for ($i = 0; $i -lt 3; $i++) {
            try { [void]$u.Client.SendTo($ask, $to) } catch { return $null }
            $end = [DateTime]::UtcNow.AddSeconds(1)
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
        try { $s.Connect($c.ip, $c.first); return "$(([Net.IPEndPoint]$s.LocalEndPoint).Address)" } catch { return $null } finally { $s.Close() }
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

    # Where one can be reached, as the 30 bytes of a call and its answer - the public IPv4 and port, the LAN IPv4 and port, the
    # IPv6 and port, zeros for none -, and back
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

    # Where this computer can be reached from the local port of the UDP socket $u: the public address and port, when its NAT keeps
    # the local port - else none -, the LAN address, the IPv6 address
    function Here($u, [int]$local) {
        $w = @{ pub = $null; lan = $null; v6 = $null }
        $pub = Stun $u
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

    # A local port to call and dial from: free for UDP and for TCP. @( its UDP socket, the port ); $null - none now
    function Local-Port {
        for ($i = 0; $i -lt 20; $i++) {
            # a port at random of the dynamic ones, 49152-65535: Windows keeps blocks of a hundred ports from TCP and from UDP -
            # Hyper-V, WSL, Docker reserve them -, and the ports it gives by itself, one after another, run into such a block now
            # and then: a port free for UDP, refused to TCP, many picks in a row
            $n = Get-Random -Minimum 49152 -Maximum 65536
            try { $u = New-Object Net.Sockets.UdpClient($n) } catch { continue }
            $t = New-Object Net.Sockets.Socket('InterNetwork', 'Stream', 'Tcp')
            try { $t.SetSocketOption('Socket', 'ReuseAddress', $true); $t.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::Any, $n))); $free = $true }
            catch { $free = $false }
            $t.Close()
            if ($free) { return @($u, $n) }
            $u.Close()
        }
        return $null
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

    # A new local port, and where this computer can be reached from it. $false - nothing to call with: its NAT changes the port,
    # and no IPv6
    function Fresh {
        if ($script:u) { $script:u.Close() }
        $p = Local-Port
        if (-not $p) { $script:u = $null; return $false }
        $script:u, $script:local = $p
        $script:me = Here $script:u $script:local
        if (-not ($script:me.pub -or $script:me.v6)) { return $false }
        $script:u.Connect($c.ip, $c.port)
        $script:u.Client.ReceiveTimeout = 1000
        return $true
    }

    # The server met directly: @{ sock - the connection; why - how } - or @{ why - why not }. The local port calls: the key of a call and the 30
    # bytes to the port of meeting, a second for the answer, 6 s in all. Refused - the server does not dial the relay this moment
    # -: again a second later, from a new local port: the call before is bound to the local port of the server of that moment, and
    # each call from the same port would go there. The answer - where the server can be reached - is dialed from the local port,
    # each target a new SYN each 300 ms while nothing came back, and at once after a refusal, up to -Wait seconds; the first
    # connection made is kept
    function Direct {
        $nothing = 'nothing to call with: the NAT of this computer changes the port, and no IPv6'
        if (-not (Fresh)) { return @{ why = $(if ($script:u) { $nothing } else { 'no free local port' }) } }
        $why = 'the call got no answer: another token, or the server waits without one'
        $answer = $null
        $calling = [DateTime]::UtcNow.AddSeconds(6)
        while (-not $answer -and [DateTime]::UtcNow -lt $calling) {
            [byte[]]$ask = $c.call + (Encode $script:me)
            try {
                [void]$script:u.Send($ask, $ask.Length)
                $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
                $got = $script:u.Receive([ref]$ep)
                if ($got.Length -eq 30) { $answer = Decode $got }
            } catch {
                $e = Why $_
                if ($e -eq 'TimedOut') { continue }
                if ($e -notin 'ConnectionRefused', 'ConnectionReset') { Start-Sleep 1; continue }
                $why = 'the call was refused: the server does not dial the relay this moment'
                Start-Sleep 1
                if (-not (Fresh)) { return @{ why = $nothing } }
            }
        }
        $script:u.Close()
        if (-not $answer) { return @{ why = $why } }
        $targets = Targets $script:me $answer
        if (-not $targets.Count) { return @{ why = 'nowhere to dial: no IPv6 on both, and a NAT of the two changes the port' } }
        foreach ($t in $targets) { $t.sock = $null; $t.at = [DateTime]::MinValue; $t.done = $false }
        $met = $null
        $until = [DateTime]::UtcNow.AddSeconds($c.wait)
        while (-not $met -and [DateTime]::UtcNow -lt $until) {
            foreach ($t in $targets) {
                if ($t.done) { continue }
                if ($t.sock) {
                    $done = $t.sock.Poll(0, [Net.Sockets.SelectMode]::SelectWrite)
                    if ($done -or $t.sock.Poll(0, [Net.Sockets.SelectMode]::SelectError)) {
                        $s = $t.sock; $t.sock = $null
                        if ($done -and [int]$s.GetSocketOption('Socket', 'Error') -eq 0) { $t.done = $true; $met = @($s, $t); break }
                        # refused, or no way there: dialed again at once, while the time lasts
                        $s.Close()
                    } elseif (([DateTime]::UtcNow - $t.at).TotalMilliseconds -ge 300 -and (Sent $t.sock)) { $t.sock.Close(); $t.sock = $null }
                }
                if (-not $t.sock) { $t.sock = Dial $script:local $t.to[0] $t.to[1]; $t.at = [DateTime]::UtcNow }
            }
            if (-not $met) { Start-Sleep -Milliseconds 20 }
        }
        foreach ($t in $targets) { if ($t.sock) { $t.sock.Close() } }
        if (-not $met) { return @{ why = "the server dialed, $(Ways $targets); nothing connected within $($c.wait) s" } }
        $met[0].Blocking = $true
        return @{ sock = $met[0]; why = "directly, $(Ways $met[1])" }
    }

    $who = "$($came.Client.RemoteEndPoint)"
    $met = $null
    try {
        $way = $null
        if ($c.call) { $d = Direct; $met = $d.sock; $way = $d.why }
        if (-not $met) {
            $met = New-Object Net.Sockets.Socket('InterNetwork', 'Stream', 'Tcp')
            try {
                $try = $met.BeginConnect($c.ip, $c.port, $null, $null)
                if (-not $try.AsyncWaitHandle.WaitOne(10000)) { throw 'no answer within 10 s' }
                $met.EndConnect($try)
            } catch {
                $met.Close(); $came.Close()
                $reason = $(if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { "$_" })
                Say '❌' bad "${who}: the relay, $($c.host):$($c.port), let nobody in: $reason$(if ($way) { " - $way" })"
                return
            }
            $way = "through the relay$(if ($way) { " - $way" })"
        }
        Say '✅' good "$who met the server $way"
        $came.NoDelay = $true
        $met.NoDelay = $true
        # Keepalive on the connection to the server: on, after 60 s of silence, a probe each 10 s. A server that is gone without a
        # word is found; and a session that is silent stays known to the NATs on the way, which forget a silent connection in
        # minutes
        try { [void]$met.IOControl([Net.Sockets.IOControlCode]::KeepAliveValues, [byte[]](1, 0, 0, 0, 0x60, 0xEA, 0, 0, 0x10, 0x27, 0, 0), $null) } catch { }
        if ($c.token) { [void]$met.Send($c.token) }
        [AdHocRelayPass]::Both($came.Client, $met).Wait()
        Say '👋' quiet "$who ended"
    } catch {
        Say '❌' bad "${who}: $($_.Exception.Message)"
    } finally {
        if ($met) { $met.Close() }
        $came.Close()
    }
}

# what the threads have to say, said here: the window is of this thread alone
$news = New-Object 'Collections.Concurrent.ConcurrentQueue[object]'
function Tell { $item = $null; while ($news.TryDequeue([ref]$item)) { Say $item[0] $item[1] $item[2] } }

# as many connections at once, no more: each one a thread
$Max = 64
$pool = [RunspaceFactory]::CreateRunspacePool(1, $Max)
$pool.Open()
$running = New-Object Collections.ArrayList
$tokenBytes = $null
if ($Token) { $tokenBytes = $Ascii.GetBytes($Token) }
while ($true) {
    Tell
    foreach ($r in @($running)) {
        if (-not $r.done.IsCompleted) { continue }
        try { [void]$r.ps.EndInvoke($r.done) } catch { Say '❌' bad "$($_.Exception.Message)" }
        $r.ps.Dispose()
        $running.Remove($r)
    }
    if (-not $listener.Pending()) { Start-Sleep -Milliseconds 50; continue }
    $came = $listener.AcceptTcpClient()
    if ($running.Count -ge $Max) { $came.Close(); Say '⚠️' warn "$Max connections at once already: one more turned away"; continue }
    # the relay looked up for each: a name of a changing address follows it
    try { $ip = [Net.Dns]::GetHostAddresses($m[0]) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1 } catch { $ip = $null }
    if (-not $ip) { $came.Close(); Say '❌' bad "The relay $($m[0]): no such address now"; continue }
    $c = @{ host = $m[0]; ip = $ip; port = $m[1]; first = [int]$First; wait = $seconds; call = $Call; token = $tokenBytes; news = $news }
    $ps = [PowerShell]::Create()
    $ps.RunspacePool = $pool
    [void]$ps.AddScript($Work.ToString()).AddArgument($came).AddArgument($c)
    [void]$running.Add(@{ ps = $ps; done = $ps.BeginInvoke() })
}
