#requires -Version 5.1
param(
    [switch]$Hidden,
    [switch]$Quit,
    [switch]$SelfTest,
    [switch]$DryRun,
    [int]$Seconds = 10,
    [string]$RenderTo,
    [ValidateSet('light', 'dark')][string]$RenderTheme = 'dark',
    [ValidateSet('default', 'tone', 'menu', 'menumany', 'form', 'toast', 'drawer', 'paused', 'nosensor')][string]$RenderState = 'default',
    [double]$RenderScale = 1
)

$ErrorActionPreference = 'Stop'
$ScriptPath = $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ScriptPath
$ConfigPath = Join-Path $Root 'settings.json'
$AppName = 'Lumen'

if ($Quit) {
    $ev = $null
    if ([Threading.EventWaitHandle]::TryOpenExisting('Local\Lumen.Quit', [ref]$ev)) {
        [void]$ev.Set()
        'Quit request sent.'
    }
    else {
        'Lumen is not running.'
    }
    exit 0
}

$CoreSource = @'
$BandLux = [double[]](0, 5, 20, 50, 100, 200, 400, 800, 1500, 3000)

function Get-BandPosition([double]$Lux) {
    if ([double]::IsNaN($Lux) -or $Lux -le $BandLux[0]) {
        return 0.0
    }
    $last = $BandLux.Length - 1
    if ($Lux -ge $BandLux[$last]) {
        return [double]$last
    }
    for ($i = 0; $i -lt $last; $i++) {
        if ($Lux -le $BandLux[$i + 1]) {
            $a = [Math]::Log10($BandLux[$i] + 1)
            $b = [Math]::Log10($BandLux[$i + 1] + 1)
            return $i + ([Math]::Log10($Lux + 1) - $a) / ($b - $a)
        }
    }
    return [double]$last
}

function Get-CurveValue([int[]]$Values, [double]$Lux) {
    $p = Get-BandPosition $Lux
    $i = [int][Math]::Floor($p)
    if ($i -ge $Values.Length - 1) {
        return [double]$Values[$Values.Length - 1]
    }
    return $Values[$i] + ($Values[$i + 1] - $Values[$i]) * ($p - $i)
}

function Get-Median([double[]]$Items) {
    if ($Items.Length -eq 0) {
        return [double]::NaN
    }
    $s = [double[]]($Items | Sort-Object)
    $m = [int][Math]::Floor($s.Length / 2)
    if ($s.Length % 2 -eq 1) {
        return $s[$m]
    }
    return ($s[$m - 1] + $s[$m]) / 2
}

function Get-NextBrightness([int]$Current, [int]$Target) {
    $d = $Target - $Current
    if ($d -eq 0) {
        return $Current
    }
    $gain = 0.14
    if ($d -gt 0) {
        $gain = 0.30
    }
    $step = [int][Math]::Max([double]1, [Math]::Ceiling([Math]::Abs($d) * $gain))
    if ($d -gt 0) {
        return [Math]::Min($Target, $Current + $step)
    }
    return [Math]::Max($Target, $Current - $step)
}

function Get-StepInterval([int]$Speed) {
    $table = 260, 170, 110, 70, 40
    $i = [Math]::Min(5, [Math]::Max(1, $Speed)) - 1
    return $table[$i]
}

function Limit-Values($Raw) {
    if ($null -eq $Raw) {
        return $null
    }
    $list = @($Raw)
    if ($list.Count -ne $BandLux.Length) {
        return $null
    }
    $out = New-Object int[] $list.Count
    for ($i = 0; $i -lt $list.Count; $i++) {
        $n = 0.0
        if (-not [double]::TryParse([string]$list[$i], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) {
            return $null
        }
        if ([double]::IsNaN($n)) {
            return $null
        }
        $out[$i] = [int][Math]::Round([Math]::Min([double]100, [Math]::Max([double]0, $n)))
    }
    return , $out
}

function Get-SmoothStep([double]$A, [double]$B, [double]$X) {
    $u = [Math]::Min([double]1, [Math]::Max([double]0, ($X - $A) / ($B - $A)))
    return $u * $u * (3 - 2 * $u)
}

function Get-TonedValue([int]$Value, [int[]]$Tone, [double]$Position) {
    $gain = [Math]::Pow(2, $Tone[1] / 100.0)
    $v = $Value + $Tone[0] * 0.4
    $v = 50 + ($v - 50) * $gain
    $v += $Tone[3] * 0.4 * (1 - (Get-SmoothStep 0 0.6 $Position))
    $v += $Tone[2] * 0.4 * (Get-SmoothStep 0.4 1 $Position)
    return [int][Math]::Round([Math]::Min([double]100, [Math]::Max([double]0, [double]$v)))
}

function Get-TonedValues([int[]]$Base, [int[]]$Tone) {
    $n = $Base.Length
    $out = New-Object int[] $n
    for ($i = 0; $i -lt $n; $i++) {
        $position = $i / [double]($n - 1)
        $out[$i] = Get-TonedValue $Base[$i] $Tone $position
    }
    return , $out
}

function Get-BaseForTarget([int]$Wanted, [int[]]$Tone, [double]$Position, [int]$Current) {
    $best = $Current
    $bestMiss = [Math]::Abs((Get-TonedValue $Current $Tone $Position) - $Wanted)
    for ($candidate = 0; $candidate -le 100; $candidate++) {
        $miss = [Math]::Abs((Get-TonedValue $candidate $Tone $Position) - $Wanted)
        if ($miss -lt $bestMiss) {
            $best = $candidate
            $bestMiss = $miss
        } elseif ($miss -eq $bestMiss) {
            if ([Math]::Abs($candidate - $Current) -lt [Math]::Abs($best - $Current)) {
                $best = $candidate
            }
        }
    }
    return $best
}

function Limit-Tone($Raw) {
    $out = New-Object int[] 4
    if ($null -eq $Raw) {
        return , $out
    }
    $list = @($Raw)
    for ($i = 0; $i -lt 4 -and $i -lt $list.Count; $i++) {
        $n = 0.0
        if ([double]::TryParse([string]$list[$i], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n) -and -not [double]::IsNaN($n)) {
            $out[$i] = [int][Math]::Round([Math]::Min([double]100, [Math]::Max([double]-100, $n)))
        }
    }
    return , $out
}

function Get-NameProblem([string]$Name, [string[]]$Taken) {
    $n = $Name.Trim()
    if ($n.Length -eq 0) {
        return 'Enter a profile name.'
    }
    if ($n.Length -gt 30) {
        return 'The name can be at most 30 characters long.'
    }
    if ($n -notmatch '[\p{L}\p{N}]') {
        return 'The name must contain a letter or a digit.'
    }
    foreach ($t in $Taken) {
        if ([string]::Equals($t, $n, [StringComparison]::CurrentCultureIgnoreCase)) {
            return 'A profile with this name already exists.'
        }
    }
    return ''
}

function Get-UniqueName([string]$Wanted, [string[]]$Taken) {
    $base = $Wanted.Trim()
    if ($base.Length -gt 30) {
        $base = $base.Substring(0, 30).Trim()
    }
    if ((Get-NameProblem $base $Taken) -eq '') {
        return $base
    }
    for ($n = 2; $n -lt 10000; $n++) {
        $suffix = " $n"
        $stem = $base
        if ($stem.Length + $suffix.Length -gt 30) {
            $stem = $stem.Substring(0, 30 - $suffix.Length).Trim()
        }
        if ((Get-NameProblem ($stem + $suffix) $Taken) -eq '') {
            return $stem + $suffix
        }
    }
    return $base
}

function Get-FitScale([double]$Width, [double]$Height, [double]$AreaWidth, [double]$AreaHeight) {
    if ($AreaWidth -le 0 -or $AreaHeight -le 0) {
        return 1.0
    }
    return [Math]::Min([double]1, [Math]::Min($AreaWidth / $Width, $AreaHeight / $Height))
}

function Get-TargetDecision([int]$Target, [int]$Candidate, [int]$Dir, [long]$Since, [long]$Now) {
    $d = $Candidate - $Target
    if ($d -eq 0) {
        return @($Target, 0, $Now)
    }
    $sign = [Math]::Sign($d)
    if ($sign -ne $Dir) {
        return @($Target, $sign, $Now)
    }
    $need = 6000
    if ([Math]::Abs($d) -ge 3) {
        $need = 1500
    }
    if ($Now - $Since -ge $need) {
        return @($Candidate, 0, $Now)
    }
    return @($Target, $Dir, $Since)
}
'@
. ([scriptblock]::Create($CoreSource))

$BuiltIn = [ordered]@{
    'Windows' = [int[]](10, 10, 25, 40, 48, 60, 78, 100, 100, 100)
    'Gentle' = [int[]](20, 20, 32, 43, 50, 59, 73, 90, 90, 90)
}
$FallbackProfile = 'Gentle'
$MaxProfiles = 50
$BackupPath = Join-Path $Root 'settings.backup.json'

function New-ProfileObject([string]$Name, [int[]]$Values, [int[]]$Tone, [bool]$Locked) {
    return @{
        Name = $Name
        Values = [int[]]$Values.Clone()
        Tone = [int[]]$Tone.Clone()
        Locked = $Locked
    }
}

if ($SelfTest) {
    $fail = 0
    function Assert($Cond, $Name) {
        if ($Cond) {
            "ok    $Name"
        } else {
            "FAIL  $Name"
            $script:fail++
        }
    }
    $v = $BuiltIn['Windows']
    Assert ((Get-CurveValue $v 0) -eq 10) 'lux 0 gives the first band'
    Assert ((Get-CurveValue $v 5) -eq 10) 'lux 5 gives the second band'
    Assert ((Get-CurveValue $v 800) -eq 100) 'lux 800 gives 100'
    Assert ((Get-CurveValue $v 99999) -eq 100) 'above the range gives the last band'
    Assert ((Get-CurveValue $v -5) -eq 10) 'negative lux gives the first band'
    Assert ((Get-CurveValue $v ([double]::NaN)) -eq 10) 'NaN gives the first band'
    $mid = Get-CurveValue $v 10
    Assert ($mid -gt 10 -and $mid -lt 25) "lux 10 lies between the bands ($mid)"
    Assert ((Get-Median ([double[]](5, 900, 6))) -eq 6) 'the median rejects a spike'
    Assert ((Get-Median ([double[]](1, 2, 3, 4))) -eq 2.5) 'median of an even count'
    Assert ((Get-NextBrightness 50 50) -eq 50) 'no step at the target'
    Assert ((Get-NextBrightness 50 51) -eq 51) 'one step up'
    Assert ((Get-NextBrightness 50 49) -eq 49) 'one step down'
    Assert ($null -eq (Limit-Values @(1, 2, 3))) 'too few values are rejected'
    Assert ($null -eq (Limit-Values @(1, 2, 3, 4, 5, 6, 7, 8, 9, 'x'))) 'text is rejected'
    $lim = Limit-Values @(-5, 0, 10.6, 100, 250, 1, 2, 3, 4, 5)
    Assert (($lim -join ',') -eq '0,0,11,100,100,1,2,3,4,5') "values are clamped to the range ($($lim -join ','))"
    $lim = Limit-Values @(0.4, 99.6, 100.4, 49.4, 49.6, 1, 2, 3, 4, 5)
    Assert (($lim -join ',') -eq '0,100,100,49,50,1,2,3,4,5') "fractions are rounded ($($lim -join ','))"

    $zero = [int[]](0, 0, 0, 0)
    Assert (((Get-TonedValues $v $zero) -join ',') -eq ($v -join ',')) 'zero tone does not change the curve'
    Assert ((Get-BaseForTarget 66 $zero 0.5 10) -eq 66) 'without tone the stored value equals the wanted value'
    $exposure = [int[]](40, 0, 0, 0)
    $stored = Get-BaseForTarget 66 $exposure 0.5 10
    Assert ((Get-TonedValue $stored $exposure 0.5) -eq 66) "with tone a reachable value is hit exactly (stored $stored)"
    $dark = [int[]](-100, 0, 0, 0)
    $stored = Get-BaseForTarget 100 $dark 0.5 10
    Assert ($stored -eq 100 -and (Get-TonedValue $stored $dark 0.5) -eq 60) 'an unreachable value stops at the nearest reachable one'
    $t = Get-TonedValues $v ([int[]](0, 0, 0, 100))
    Assert ($t[0] -eq 50 -and $t[9] -eq 100) "shadows +100 raise the 0 lx band by 40 and leave the 3000 lx band ($($t -join ','))"
    $t = Get-TonedValues $BuiltIn['Gentle'] ([int[]](0, 0, -100, 0))
    Assert ($t[9] -eq 50 -and $t[0] -eq 20) "highlights -100 lower the 3000 lx band by 40 and leave the 0 lx band ($($t -join ','))"
    $t = Get-TonedValues ([int[]](50, 50, 50, 50, 50, 50, 50, 50, 50, 50)) ([int[]](0, 100, 0, 0))
    Assert (($t -join ',') -eq '50,50,50,50,50,50,50,50,50,50') 'contrast leaves the value 50% unchanged'
    $t = Get-TonedValues ([int[]](30, 30, 30, 30, 30, 70, 70, 70, 70, 70)) ([int[]](0, -100, 0, 0))
    Assert ($t[0] -eq 40 -and $t[9] -eq 60) "contrast -100 halves the spread ($($t -join ','))"
    Assert (((Limit-Tone @(200, -300, 'x', 5.6)) -join ',') -eq '100,-100,0,6') 'tone values are clamped'
    Assert (((Limit-Tone $null) -join ',') -eq '0,0,0,0') 'missing tone means zeros'
    Assert ((Get-NameProblem '  ' @()) -ne '') 'an empty name is rejected'
    Assert ((Get-NameProblem ('x' * 31) @()) -ne '') 'a name that is too long is rejected'
    Assert ((Get-NameProblem ' night ' @('Night')) -ne '') 'a repeated name is rejected regardless of case'
    Assert ((Get-NameProblem 'Night' @('Day')) -eq '') 'a valid name is accepted'
    Assert ((Get-NameProblem ([string][char]0x200B) @()) -ne '') 'a name made of invisible characters is rejected'
    Assert ((Get-UniqueName 'Night' @('Day')) -eq 'Night') 'a free name is kept'
    Assert ((Get-UniqueName 'Night' @('night', 'Night 2')) -eq 'Night 3') 'a taken name gets the next number'
    $long = 'x' * 30
    $u = Get-UniqueName $long @($long)
    Assert ($u.Length -le 30 -and $u -ne $long -and (Get-NameProblem $u @($long)) -eq '') "a long taken name is shortened ($u)"
    Assert ((Get-FitScale 1000 720 1600 1000) -eq 1) 'the window fits: no scaling'
    Assert ([Math]::Abs((Get-FitScale 1000 720 1280 648) - 0.9) -lt 1e-9) 'the screen is too low: scaled to 0.9'
    $r = Get-TargetDecision 20 20 1 0 5000
    Assert ($r[0] -eq 20 -and $r[1] -eq 0) 'no difference: the target is unchanged'
    $r = Get-TargetDecision 20 30 0 0 1000
    Assert ($r[0] -eq 20 -and $r[1] -eq 1 -and $r[2] -eq 1000) 'a new difference starts the countdown'
    $r = Get-TargetDecision 20 30 1 1000 2400
    Assert ($r[0] -eq 20) 'large difference before 1.5 s: not yet'
    $r = Get-TargetDecision 20 30 1 1000 2500
    Assert ($r[0] -eq 30) 'large difference after 1.5 s: accepted'
    $r = Get-TargetDecision 22 20 -1 1000 6900
    Assert ($r[0] -eq 22) 'small difference before 6 s: not yet'
    $r = Get-TargetDecision 22 20 -1 1000 7000
    Assert ($r[0] -eq 20) 'small difference after 6 s: accepted (the end of the curve is reachable)'
    $r = Get-TargetDecision 20 18 1 1000 9000
    Assert ($r[0] -eq 20 -and $r[1] -eq -1 -and $r[2] -eq 9000) 'a change of direction restarts the countdown'

    $rnd = New-Object Random 20261113
    $bad = 0
    for ($n = 0; $n -lt 3000; $n++) {
        $vals = New-Object int[] 10
        for ($i = 0; $i -lt 10; $i++) {
            $vals[$i] = $rnd.Next(0, 101)
        }
        $tone = [int[]]($rnd.Next(-100, 101), $rnd.Next(-100, 101), $rnd.Next(-100, 101), $rnd.Next(-100, 101))
        $out = Get-TonedValues $vals $tone
        foreach ($o in $out) {
            if ($o -lt 0 -or $o -gt 100) {
                $bad++
            }
        }
        $more = [int[]]$tone.Clone()
        $more[0] = [Math]::Min(100, $tone[0] + $rnd.Next(1, 60))
        $out2 = Get-TonedValues $vals $more
        for ($i = 0; $i -lt 10; $i++) {
            if ($out2[$i] -lt $out[$i]) {
                $bad++
            }
        }
    }
    Assert ($bad -eq 0) "3000 random tone settings: result within 0-100, more exposure never darkens (errors: $bad)"
    $bad = 0
    for ($n = 0; $n -lt 400; $n++) {
        $tone = [int[]]($rnd.Next(-100, 101), $rnd.Next(-100, 101), $rnd.Next(-100, 101), $rnd.Next(-100, 101))
        $position = $rnd.Next(0, 10) / 9.0
        $wanted = $rnd.Next(0, 101)
        $current = $rnd.Next(0, 101)
        $stored = Get-BaseForTarget $wanted $tone $position $current
        $miss = [Math]::Abs((Get-TonedValue $stored $tone $position) - $wanted)
        if ($stored -lt 0 -or $stored -gt 100) {
            $bad++
        }
        for ($candidate = 0; $candidate -le 100; $candidate++) {
            if ([Math]::Abs((Get-TonedValue $candidate $tone $position) - $wanted) -lt $miss) {
                $bad++
                break
            }
        }
    }
    Assert ($bad -eq 0) "400 random band edits under tone: the stored value is in range and no other value gets closer (errors: $bad)"
    $bad = 0
    for ($n = 0; $n -lt 3000; $n++) {
        $vals = New-Object int[] 10
        for ($i = 0; $i -lt 10; $i++) {
            $vals[$i] = $rnd.Next(0, 101)
        }
        $lux = [Math]::Pow(10, $rnd.NextDouble() * 4.2) - 1
        $out = Get-CurveValue $vals $lux
        $p = Get-BandPosition $lux
        $i = [int][Math]::Floor($p)
        $j = [Math]::Min(9, $i + 1)
        $lo = [Math]::Min($vals[$i], $vals[$j])
        $hi = [Math]::Max($vals[$i], $vals[$j])
        if ($out -lt $lo - 1e-9 -or $out -gt $hi + 1e-9 -or $p -lt 0 -or $p -gt 9) {
            $bad++
        }
    }
    Assert ($bad -eq 0) "3000 random curves: result always between the neighbouring bands (errors: $bad)"

    $bad = 0
    for ($n = 0; $n -lt 500; $n++) {
        $vals = New-Object int[] 10
        $acc = 0
        for ($i = 0; $i -lt 10; $i++) {
            $acc = [Math]::Min(100, $acc + $rnd.Next(0, 25))
            $vals[$i] = $acc
        }
        $prev = -1.0
        for ($lux = 0.0; $lux -lt 4000; $lux += 37.3) {
            $out = Get-CurveValue $vals $lux
            if ($out -lt $prev - 1e-9) {
                $bad++
            }
            $prev = $out
        }
    }
    Assert ($bad -eq 0) "500 rising curves: result never falls as the light grows (errors: $bad)"

    $bad = 0
    for ($n = 0; $n -lt 2000; $n++) {
        $c = $rnd.Next(0, 101)
        $t = $rnd.Next(0, 101)
        $steps = 0
        while ($c -ne $t -and $steps -lt 200) {
            $nx = Get-NextBrightness $c $t
            if ([Math]::Abs($t - $nx) -ge [Math]::Abs($t - $c) -or $nx -lt 0 -or $nx -gt 100) {
                $bad++
                break
            }
            $c = $nx
            $steps++
        }
        if ($c -ne $t) {
            $bad++
        }
    }
    Assert ($bad -eq 0) "2000 random transitions: every step moves closer and ends at the target (errors: $bad)"

    $bad = 0
    for ($n = 0; $n -lt 300; $n++) {
        $target = $rnd.Next(5, 95)
        $dir = 0
        $since = 0
        for ($t = 0; $t -lt 60000; $t += 400) {
            $cand = $target + 1
            if (($t / 400) % 2 -eq 1) {
                $cand = $target - 1
            }
            $r = Get-TargetDecision $target $cand $dir $since $t
            if ($r[0] -ne $target) {
                $bad++
            }
            $dir = $r[1]
            $since = $r[2]
        }
        $want = $rnd.Next(0, 101)
        $dir = 0
        $since = 0
        $cur = $rnd.Next(0, 101)
        for ($t = 0; $t -le 7000; $t += 400) {
            $r = Get-TargetDecision $cur $want $dir $since $t
            $cur = $r[0]
            $dir = $r[1]
            $since = $r[2]
        }
        if ($cur -ne $want) {
            $bad++
        }
    }
    Assert ($bad -eq 0) "300 runs: 1% flicker does not move the target, a steady reading is accepted within 7 s (errors: $bad)"

    $bad = 0
    for ($n = 0; $n -lt 500; $n++) {
        $taken = @()
        for ($i = 0; $i -lt $rnd.Next(0, 12); $i++) {
            $taken += ('P' * $rnd.Next(1, 31))
        }
        $u = Get-UniqueName ('P' * $rnd.Next(1, 40)) $taken
        if ((Get-NameProblem $u $taken) -ne '') {
            $bad++
        }
    }
    Assert ($bad -eq 0) "500 random names: result always valid and free (errors: $bad)"

    "---"
    if ($fail -eq 0) {
        'RESULT: all tests passed'
        exit 0
    }
    "RESULT: failed tests: $fail"
    exit 1
}

function Find-Profile($Cfg, [string]$Name) {
    foreach ($p in $Cfg.Profiles) {
        if ($p.Name -eq $Name) {
            return $p
        }
    }
    foreach ($p in $Cfg.Profiles) {
        if ($p.Name -eq $FallbackProfile) {
            return $p
        }
    }
    return $Cfg.Profiles[0]
}

function Read-Config([bool]$FromFile = $true) {
    $cfg = @{
        Profiles = (New-Object Collections.ArrayList)
        Default = $FallbackProfile
        Speed = 3
        Enabled = $true
        Theme = ''
        Problem = ''
    }
    $none = [int[]](0, 0, 0, 0)
    foreach ($name in $BuiltIn.Keys) {
        [void]$cfg.Profiles.Add((New-ProfileObject $name $BuiltIn[$name] $none $true))
    }
    if ($FromFile -and (Test-Path -LiteralPath $ConfigPath)) {
        try {
            $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($raw -isnot [Management.Automation.PSCustomObject]) {
                throw 'The settings file has an invalid format.'
            }
            $taken = New-Object 'Collections.Generic.List[string]'
            foreach ($name in $BuiltIn.Keys) {
                $taken.Add($name)
            }
            $skipped = 0
            foreach ($p in @($raw.profiles)) {
                if ($null -eq $p) {
                    continue
                }
                if ($cfg.Profiles.Count -ge $MaxProfiles) {
                    $skipped++
                    continue
                }
                $name = ([string]$p.name).Trim()
                $vals = Limit-Values $p.values
                if ($null -eq $vals -or (Get-NameProblem $name $taken.ToArray()) -ne '') {
                    $skipped++
                    continue
                }
                [void]$cfg.Profiles.Add((New-ProfileObject $name $vals (Limit-Tone $p.tone) $false))
                $taken.Add($name)
            }
            if ($skipped -gt 0) {
                $cfg.Problem = 'skipped'
            }
            if ($null -eq $raw.profiles) {
                $old = Limit-Values $raw.values
                if ($null -ne $old) {
                    $same = $null
                    foreach ($name in $BuiltIn.Keys) {
                        if (($BuiltIn[$name] -join ',') -eq ($old -join ',')) {
                            $same = $name
                        }
                    }
                    if ($null -ne $same) {
                        $cfg.Default = $same
                    }
                    else {
                        [void]$cfg.Profiles.Add((New-ProfileObject 'My profile' $old $none $false))
                        $cfg.Default = 'My profile'
                    }
                }
            }
            if ($raw.default -is [string]) {
                foreach ($p in $cfg.Profiles) {
                    if ($p.Name -eq $raw.default) {
                        $cfg.Default = $raw.default
                    }
                }
            }
            $sp = 0.0
            if ([double]::TryParse([string]$raw.speed, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$sp) -and
                $sp -eq [Math]::Floor($sp) -and $sp -ge 1 -and $sp -le 5) {
                    $cfg.Speed = [int]$sp
                }
            if ($raw.enabled -is [bool]) {
                $cfg.Enabled = $raw.enabled
            }
            if ($raw.theme -is [string] -and ($raw.theme -eq 'light' -or $raw.theme -eq 'dark')) {
                $cfg.Theme = $raw.theme
            }
        } catch {
            $cfg.Problem = 'corrupt'
        }
    }
    return $cfg
}

function Save-Config($Cfg) {
    $custom = @()
    foreach ($p in $Cfg.Profiles) {
        if (-not $p.Locked) {
            $custom += [ordered]@{
                name = $p.Name
                values = @($p.Values)
                tone = @($p.Tone)
            }
        }
    }
    $json = [ordered]@{
        version  = 2
        profiles = $custom
        default  = $Cfg.Default
        speed    = $Cfg.Speed
        enabled  = $Cfg.Enabled
        theme    = $Cfg.Theme
    } | ConvertTo-Json -Depth 5
    $tmp = $ConfigPath + '.tmp'
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding $false))
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        [IO.File]::Move($tmp, $ConfigPath)
        return
    }
    try {
        [IO.File]::Replace($tmp, $ConfigPath, $null)
    }
    catch {
        [IO.File]::Copy($tmp, $ConfigPath, $true)
        [IO.File]::Delete($tmp)
    }
}

$EngineSource = @'
param($Shared, $CoreSource)
$ErrorActionPreference = 'Stop'
. ([scriptblock]::Create($CoreSource))

function Select-Panel($All) {
    $list = @($All)
    foreach ($item in $list) {
        if ($item.Active) {
            return $item
        }
    }
    return $list[0]
}
function Read-Brightness {
    $o = Select-Panel (Get-WmiObject -Namespace root\wmi -Class WmiMonitorBrightness -ErrorAction Stop)
    if ($null -eq $o) {
        throw 'No display with brightness control'
    }
    return [int]$o.CurrentBrightness
}

$clock = [Diagnostics.Stopwatch]::StartNew()
$sensor = $null
$methods = $null
$samples = New-Object 'System.Collections.Generic.List[double]'
$applied = -1
$settled = -1
$target = -1
$version = -1
$pendingDir = 0
$pendingSince = 0
$nextSample = 0
$nextStep = 0
$nextCheck = 0
$nextRetry = 0
$holdUntil = 0
$failUntil = 0
$nullReads = 0

try {
    while (-not $Shared.Quit) {
        $now = $clock.ElapsedMilliseconds
        $pause = 120
        if ($now -ge $failUntil) {
            try {
                if (($null -eq $sensor -or $null -eq $methods) -and $now -ge $nextRetry) {
                    $nextRetry = $now + 5000
                    if ($null -eq $sensor) {
                        [void][Windows.Devices.Sensors.LightSensor, Windows.Devices.Sensors, ContentType = WindowsRuntime]
                        $sensor = [Windows.Devices.Sensors.LightSensor]::GetDefault()
                        if ($null -ne $sensor) {
                            $sensor.ReportInterval = [uint32][Math]::Max(250, $sensor.MinimumReportInterval)
                        }
                    }
                    if ($null -eq $methods) {
                        $methods = Select-Panel (Get-WmiObject -Namespace root\wmi -Class WmiMonitorBrightnessMethods -ErrorAction SilentlyContinue)
                        if ($null -ne $methods) {
                            $applied = Read-Brightness
                            $settled = $applied
                        }
                    }
                }

                if ($null -eq $sensor) {
                    $Shared.Status = 'no-sensor'
                }
                elseif ($null -eq $methods) {
                    $Shared.Status = 'no-display'
                }
                else {
                    if ($now -ge $nextSample) {
                        $nextSample = $now + 400
                        $r = $sensor.GetCurrentReading()
                        if ($null -eq $r) {
                            $nullReads++
                        }
                        else {
                            $nullReads = 0
                            $samples.Add([double]$r.IlluminanceInLux)
                            while ($samples.Count -gt 5) {
                                $samples.RemoveAt(0)
                            }
                            $Shared.Lux = Get-Median ($samples.ToArray())
                        }
                    }

                    if ($nullReads -ge 12) {
                        $Shared.Status = 'no-reading'
                    }
                    elseif ($samples.Count -gt 0) {
                        $ver = $Shared.Version
                        $cand = [int][Math]::Round((Get-CurveValue $Shared.Values $Shared.Lux))
                        if ($ver -ne $version -or $target -lt 0) {
                            $version = $ver
                            $target = $cand
                            $pendingDir = 0
                        } else {
                            $dec = Get-TargetDecision $target $cand $pendingDir $pendingSince $now
                            $target = $dec[0]
                            $pendingDir = $dec[1]
                            $pendingSince = $dec[2]
                        }
                        $Shared.Target = $target

                        if ($now -ge $nextCheck -and ($applied -eq $target -or -not $Shared.Enabled)) {
                            $nextCheck = $now + 2000
                            $actual = Read-Brightness
                            if (-not $Shared.Enabled) {
                                $applied = $actual
                                $settled = $actual
                            }
                            elseif ($settled -lt 0) {
                                $settled = $actual
                            }
                            elseif ($actual -ne $settled) {
                                $Shared.External = $Shared.External + 1
                                $holdUntil = $now + 3000
                                $applied = $actual
                                $settled = $actual
                            }
                        }

                        if ($Shared.Enabled) {
                            if ($applied -ne $target -and $now -ge $holdUntil) {
                                $pause = 30
                                if ($now -ge $nextStep) {
                                    $nextStep = $now + (Get-StepInterval $Shared.Speed)
                                    if ($Shared.DryRun) {
                                        $applied = Read-Brightness
                                        $pause = 120
                                    } else {
                                        $next = Get-NextBrightness $applied $target
                                        [void]$methods.WmiSetBrightness(0, [byte]$next)
                                        $applied = $next
                                        $settled = -1
                                        $nextCheck = $now + 2000
                                    }
                                }
                            }
                            $Shared.Status = 'ok'
                        } else {
                            $Shared.Status = 'paused'
                        }
                        $Shared.Applied = $applied
                    }
                }
                $Shared.Error = ''
            } catch {
                $Shared.Error = $_.Exception.Message
                $Shared.Status = 'error'
                if ($null -ne $sensor) {
                    try {
                        $sensor.ReportInterval = 0
                    } catch { }
                }
                $sensor = $null
                $methods = $null
                $samples.Clear()
                $nullReads = 0
                $failUntil = $now + 5000
                $nextRetry = $failUntil
            }
        }
        Start-Sleep -Milliseconds $pause
    }
} finally {
    if ($null -ne $sensor) {
        try {
            $sensor.ReportInterval = 0
        } catch { }
    }
}
'@

function Start-Engine([int[]]$Values, [int]$Speed, [bool]$Enabled, [bool]$Dry) {
    $shared = [hashtable]::Synchronized(@{
            Values = [int[]]$Values.Clone()
            Speed = $Speed
            Enabled = $Enabled
            Version = 0
            Quit = $false
            DryRun = $Dry
            Lux = [double]::NaN
            Target = -1
            Applied = -1
            Status = 'starting'
            Error = ''
            External = 0
        })
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($EngineSource).AddArgument($shared).AddArgument($CoreSource)
    $handle = $ps.BeginInvoke()
    return @{
        Shared = $shared
        PowerShell = $ps
        Runspace = $rs
        Handle = $handle
    }
}

function Stop-Engine($Engine) {
    $Engine.Shared.Quit = $true
    if ($Engine.Handle.AsyncWaitHandle.WaitOne(3000)) {
        try {
            $Engine.PowerShell.Dispose()
        } catch { }
        try {
            $Engine.Runspace.Dispose()
        } catch { }
    } else {
        try {
            [void]$Engine.PowerShell.BeginStop($null, $null)
        } catch { }
    }
}

if ($DryRun) {
    $cfg = Read-Config
    $p = Find-Profile $cfg $cfg.Default
    "profile: $($p.Name)"
    $eng = Start-Engine (Get-TonedValues $p.Values $p.Tone) $cfg.Speed $cfg.Enabled $true
    try {
        for ($i = 0; $i -lt $Seconds; $i++) {
            Start-Sleep -Seconds 1
            $s = $eng.Shared
            '{0,2}s  status={1}  lux={2}  target={3}%  brightness={4}%  error="{5}"' -f ($i + 1), $s.Status, $s.Lux, $s.Target, $s.Applied, $s.Error
        }
    } finally {
        Stop-Engine $eng
    }
    exit 0
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

$Themes = @{
    dark  = @{
        Text = '#FFF5F5F7'
        Muted = '#B3EBEBF5'
        Line = '#1FFFFFFF'
        Fill = '#2EFFFFFF'
        Glass = '#12FFFFFF'
        Capsule = '#1FFFFFFF'
        Hover = '#17FFFFFF'
        Tip = '#FF1D1D20'
        Sheet = '#A61B1B1E'
        Accent = '#FFFFB340'
        AccentLine = '#FFFFB340'
        OnAccent = '#FF1F1300'
        Orange = '#FFFFB340'
        Red = '#FFFF6961'
        Focus = '#CCFFB340'
        Knob = '#FFFFFFFF'
        KnobEdge = '#00FFFFFF'
        WBase = '#FF141416'
        Scrim = '#73000000'
        EdgeHi = '#52FFFFFF'
        EdgeLo = '#0FFFFFFF'
        AreaHi = '#42FFB340'
        AreaLo = '#00FFB340'
        GlowA = '#3DFFB340'
        GlowB = '#17FFFFFF'
        Shadow = 0.5
        KnobShadow = 0.45
    }
    light = @{
        Text = '#FF1D1D1F'
        Muted = '#D13C3C43'
        Line = '#1F000000'
        Fill = '#3D000000'
        Glass = '#80FFFFFF'
        Capsule = '#14000000'
        Hover = '#0F000000'
        Tip = '#FFFBFBFD'
        Sheet = '#99FAFAFC'
        Accent = '#FFFFB340'
        AccentLine = '#FFC47400'
        OnAccent = '#FF1F1300'
        Orange = '#FF9A5700'
        Red = '#FFC4001A'
        Focus = '#E6C47400'
        Knob = '#FFFFFFFF'
        KnobEdge = '#75000000'
        WBase = '#FFEDEDF1'
        Scrim = '#26000000'
        EdgeHi = '#FFFFFFFF'
        EdgeLo = '#66FFFFFF'
        AreaHi = '#47FFB340'
        AreaLo = '#00FFB340'
        GlowA = '#66FFC46B'
        GlowB = '#A6FFFFFF'
        Shadow = 0.18
        KnobShadow = 0.3
    }
}
$BrushKeys = 'Text', 'Muted', 'Line', 'Fill', 'Glass', 'Capsule', 'Hover', 'Tip', 'Sheet', 'Accent', 'AccentLine', 'OnAccent', 'Orange', 'Red', 'Focus', 'Knob', 'KnobEdge', 'WBase', 'Scrim'

$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Lumen" Width="940" Height="680" ResizeMode="CanMinimize"
        WindowStartupLocation="CenterScreen" Background="Transparent"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="14" Foreground="{DynamicResource Text}"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="64" GlassFrameThickness="-1" CornerRadius="0"
                  ResizeBorderThickness="0" UseAeroCaptionButtons="False"/>
  </WindowChrome.WindowChrome>

  <Window.Resources>
    <CubicEase x:Key="Out" EasingMode="EaseOut"/>

    <Style x:Key="FocusPill">
      <Setter Property="Control.Template"><Setter.Value><ControlTemplate>
        <Border Margin="-4" CornerRadius="22" BorderThickness="2" BorderBrush="{DynamicResource Focus}"/>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="FocusItem">
      <Setter Property="Control.Template"><Setter.Value><ControlTemplate>
        <Border Margin="-2" CornerRadius="13" BorderThickness="2" BorderBrush="{DynamicResource Focus}"/>
      </ControlTemplate></Setter.Value></Setter>
    </Style>

    <Style TargetType="ToolTip">
      <Setter Property="OverridesDefaultStyle" Value="True"/>
      <Setter Property="HasDropShadow" Value="False"/>
      <Setter Property="Placement" Value="Bottom"/>
      <Setter Property="VerticalOffset" Value="8"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ToolTip">
        <Border Background="{DynamicResource Tip}" BorderBrush="{DynamicResource Line}" BorderThickness="1" CornerRadius="10" Padding="10,6">
          <ContentPresenter TextElement.Foreground="{DynamicResource Text}"/>
        </Border>
      </ControlTemplate></Setter.Value></Setter>
    </Style>

    <Style x:Key="Small" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/><Setter Property="Foreground" Value="{DynamicResource Muted}"/>
    </Style>
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="FontSize" Value="13"/><Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{DynamicResource Muted}"/>
    </Style>
    <Style x:Key="Value" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe UI Variable Display, Segoe UI"/>
      <Setter Property="FontSize" Value="22"/><Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Typography.NumeralAlignment" Value="Tabular"/>
    </Style>

    <Style x:Key="Card" TargetType="ContentControl">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Padding" Value="24"/>
      <Setter Property="Tag" Value="28"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ContentControl">
            <Border Background="{DynamicResource Glass}" BorderBrush="{DynamicResource EdgeStroke}" BorderThickness="1"
                    CornerRadius="{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}">
              <ContentPresenter Margin="{TemplateBinding Padding}"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="MenuCard" TargetType="ContentControl">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Padding" Value="10"/>
      <Setter Property="Tag" Value="20"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ContentControl">
            <Grid>
              <Border Background="{DynamicResource Tip}" CornerRadius="{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}"
                      Effect="{DynamicResource CardShadow}"/>
              <Border x:Name="FrostClip" Visibility="Collapsed">
                <Rectangle x:Name="FrostFill" Margin="-52">
                  <Rectangle.Effect><BlurEffect Radius="48" RenderingBias="Performance"/></Rectangle.Effect>
                </Rectangle>
              </Border>
              <Border x:Name="FrostTint" Visibility="Collapsed" Background="{DynamicResource Sheet}"
                      CornerRadius="{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}"/>
              <Border BorderBrush="{DynamicResource EdgeStroke}" BorderThickness="1"
                      CornerRadius="{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}">
                <ContentPresenter Margin="{TemplateBinding Padding}"/>
              </Border>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Btn" TargetType="ButtonBase">
      <Setter Property="Background" Value="{DynamicResource Capsule}"/>
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="Padding" Value="16,0"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusPill}"/>
      <Setter Property="WindowChrome.IsHitTestVisibleInChrome" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ButtonBase">
            <Grid x:Name="g" RenderTransformOrigin="0.5,0.5">
              <Grid.RenderTransform><ScaleTransform/></Grid.RenderTransform>
              <Border Background="{TemplateBinding Background}" CornerRadius="18"/>
              <Border x:Name="hover" Background="{DynamicResource Hover}" CornerRadius="18" Opacity="0"/>
              <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"
                                TextElement.Foreground="{TemplateBinding Foreground}"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Trigger.EnterActions><BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="hover" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.12"/>
                </Storyboard></BeginStoryboard></Trigger.EnterActions>
                <Trigger.ExitActions><BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="hover" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.2"/>
                </Storyboard></BeginStoryboard></Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Trigger.EnterActions><BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="g" To="0.95" Duration="0:0:0.09" EasingFunction="{StaticResource Out}"
                    Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"/>
                  <DoubleAnimation Storyboard.TargetName="g" To="0.95" Duration="0:0:0.09" EasingFunction="{StaticResource Out}"
                    Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"/>
                </Storyboard></BeginStoryboard></Trigger.EnterActions>
                <Trigger.ExitActions><BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="g" To="1" Duration="0:0:0.22" EasingFunction="{StaticResource Out}"
                    Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"/>
                  <DoubleAnimation Storyboard.TargetName="g" To="1" Duration="0:0:0.22" EasingFunction="{StaticResource Out}"
                    Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"/>
                </Storyboard></BeginStoryboard></Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="g" Property="Opacity" Value="0.35"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="IconBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Width" Value="36"/><Setter Property="Padding" Value="0"/>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="{DynamicResource Accent}"/>
      <Setter Property="Foreground" Value="{DynamicResource OnAccent}"/>
    </Style>
    <Style x:Key="Glyph" TargetType="Path">
      <Setter Property="Width" Value="24"/><Setter Property="Height" Value="24"/><Setter Property="Stretch" Value="None"/>
      <Setter Property="Stroke" Value="{DynamicResource Text}"/><Setter Property="StrokeThickness" Value="2"/>
      <Setter Property="StrokeStartLineCap" Value="Round"/><Setter Property="StrokeEndLineCap" Value="Round"/>
      <Setter Property="StrokeLineJoin" Value="Round"/>
      <Setter Property="RenderTransformOrigin" Value="0.5,0.5"/>
      <Setter Property="LayoutTransform"><Setter.Value><ScaleTransform ScaleX="0.75" ScaleY="0.75"/></Setter.Value></Setter>
    </Style>

    <Style x:Key="Switch" TargetType="ToggleButton">
      <Setter Property="Width" Value="42"/><Setter Property="Height" Value="26"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusPill}"/>
      <Setter Property="WindowChrome.IsHitTestVisibleInChrome" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Grid Background="Transparent">
              <Border Background="{DynamicResource Fill}" CornerRadius="13"/>
              <Border x:Name="on" Background="{DynamicResource Accent}" CornerRadius="13" Opacity="0"/>
              <Ellipse x:Name="dot" Width="20" Height="20" Margin="3,0,0,0" HorizontalAlignment="Left" VerticalAlignment="Center"
                       Fill="#FFFFFFFF" Effect="{DynamicResource KnobShadow}">
                <Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform>
              </Ellipse>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Trigger.EnterActions><BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="on" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.16"/>
                  <DoubleAnimation Storyboard.TargetName="dot" To="16" Duration="0:0:0.22" EasingFunction="{StaticResource Out}"
                    Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)"/>
                </Storyboard></BeginStoryboard></Trigger.EnterActions>
                <Trigger.ExitActions><BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="on" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.16"/>
                  <DoubleAnimation Storyboard.TargetName="dot" To="0" Duration="0:0:0.22" EasingFunction="{StaticResource Out}"
                    Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)"/>
                </Storyboard></BeginStoryboard></Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.35"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Knob" TargetType="Thumb">
      <Setter Property="IsHitTestVisible" Value="False"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Width" Value="20"/><Setter Property="Height" Value="20"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Grid>
              <Ellipse Fill="{DynamicResource Knob}" Effect="{DynamicResource KnobShadow}"/>
              <Ellipse Stroke="{DynamicResource KnobEdge}" StrokeThickness="1"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Step" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Width" Value="14"/>
      <Setter Property="Height" Value="20"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Delay" Value="400"/>
      <Setter Property="Interval" Value="70"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RepeatButton">
            <Border Background="Transparent">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Blank" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/><Setter Property="IsHitTestVisible" Value="False"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate></Setter.Value></Setter>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="OverridesDefaultStyle" Value="True"/>
      <Setter Property="MinWidth" Value="0"/>
      <Setter Property="Width" Value="8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource Blank}"/></Track.DecreaseRepeatButton>
              <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource Blank}"/></Track.IncreaseRepeatButton>
              <Track.Thumb>
                <Thumb>
                  <Thumb.Template><ControlTemplate TargetType="Thumb">
                    <Border CornerRadius="2" Margin="2,2,2,2" Background="{DynamicResource Muted}"/>
                  </ControlTemplate></Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Storyboard x:Key="KnobHover">
      <DoubleAnimation Storyboard.TargetName="knob" To="1.15" Duration="0:0:0.2" EasingFunction="{StaticResource Out}"
        Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"/>
      <DoubleAnimation Storyboard.TargetName="knob" To="1.15" Duration="0:0:0.2" EasingFunction="{StaticResource Out}"
        Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"/>
    </Storyboard>
    <Storyboard x:Key="KnobGrab">
      <DoubleAnimation Storyboard.TargetName="knob" To="1.35" Duration="0:0:0.12" EasingFunction="{StaticResource Out}"
        Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"/>
      <DoubleAnimation Storyboard.TargetName="knob" To="1.35" Duration="0:0:0.12" EasingFunction="{StaticResource Out}"
        Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"/>
    </Storyboard>
    <Storyboard x:Key="KnobRest">
      <DoubleAnimation Storyboard.TargetName="knob" To="1" Duration="0:0:0.28" EasingFunction="{StaticResource Out}"
        Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"/>
      <DoubleAnimation Storyboard.TargetName="knob" To="1" Duration="0:0:0.28" EasingFunction="{StaticResource Out}"
        Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"/>
    </Storyboard>

    <Style x:Key="Band" TargetType="Slider">
      <Setter Property="Orientation" Value="Vertical"/>
      <Setter Property="Minimum" Value="0"/><Setter Property="Maximum" Value="100"/>
      <Setter Property="SmallChange" Value="1"/><Setter Property="LargeChange" Value="5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Slider">
            <Grid Background="Transparent">
              <Border Width="2" CornerRadius="1" Background="{DynamicResource Fill}" HorizontalAlignment="Center" Margin="0,10"/>
              <Track x:Name="PART_Track" Orientation="Vertical" Width="20" HorizontalAlignment="Center">
                <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource Blank}"/></Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource Blank}"/></Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb x:Name="knob" Style="{StaticResource Knob}" RenderTransformOrigin="0.5,0.5">
                    <Thumb.RenderTransform><ScaleTransform/></Thumb.RenderTransform>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Trigger.EnterActions><BeginStoryboard Storyboard="{StaticResource KnobHover}"/></Trigger.EnterActions>
                <Trigger.ExitActions><BeginStoryboard Storyboard="{StaticResource KnobRest}"/></Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsMouseCaptured" Value="True">
                <Trigger.EnterActions><BeginStoryboard Storyboard="{StaticResource KnobGrab}"/></Trigger.EnterActions>
                <Trigger.ExitActions><BeginStoryboard Storyboard="{StaticResource KnobRest}"/></Trigger.ExitActions>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Range" TargetType="Slider">
      <Setter Property="Height" Value="22"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="IsMoveToPointEnabled" Value="True"/>
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusPill}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Slider">
            <Grid Background="Transparent">
              <Border Height="4" CornerRadius="2" Background="{DynamicResource Fill}" VerticalAlignment="Center" Margin="10,0"/>
              <Track x:Name="PART_Track">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="Slider.DecreaseLarge" Focusable="False">
                    <RepeatButton.Template><ControlTemplate TargetType="RepeatButton">
                      <Grid Background="Transparent">
                        <Border Height="4" CornerRadius="2" Background="{DynamicResource AccentLine}" VerticalAlignment="Center" Margin="10,0,-10,0"/>
                      </Grid>
                    </ControlTemplate></RepeatButton.Template>
                  </RepeatButton>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="Slider.IncreaseLarge" Focusable="False">
                    <RepeatButton.Template><ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate></RepeatButton.Template>
                  </RepeatButton>
                </Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb Width="20" Height="20" Focusable="False">
                    <Thumb.Template><ControlTemplate TargetType="Thumb">
                      <Grid>
                        <Ellipse Fill="{DynamicResource Knob}" Effect="{DynamicResource KnobShadow}"/>
                        <Ellipse Stroke="{DynamicResource KnobEdge}" StrokeThickness="1"/>
                      </Grid>
                    </ControlTemplate></Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Tone" TargetType="Slider">
      <Setter Property="Height" Value="22"/>
      <Setter Property="Minimum" Value="-100"/><Setter Property="Maximum" Value="100"/>
      <Setter Property="SmallChange" Value="1"/><Setter Property="LargeChange" Value="10"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusPill}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Slider">
            <Grid Background="Transparent">
              <Border Height="4" CornerRadius="2" Background="{DynamicResource Fill}" VerticalAlignment="Center" Margin="10,0"/>
              <Track x:Name="PART_Track">
                <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource Blank}"/></Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource Blank}"/></Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb x:Name="knob" Style="{StaticResource Knob}" RenderTransformOrigin="0.5,0.5">
                    <Thumb.RenderTransform><ScaleTransform/></Thumb.RenderTransform>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Trigger.EnterActions><BeginStoryboard Storyboard="{StaticResource KnobHover}"/></Trigger.EnterActions>
                <Trigger.ExitActions><BeginStoryboard Storyboard="{StaticResource KnobRest}"/></Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsMouseCaptured" Value="True">
                <Trigger.EnterActions><BeginStoryboard Storyboard="{StaticResource KnobGrab}"/></Trigger.EnterActions>
                <Trigger.ExitActions><BeginStoryboard Storyboard="{StaticResource KnobRest}"/></Trigger.ExitActions>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="MenuItem" TargetType="ButtonBase">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="Padding" Value="10,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusItem}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ButtonBase">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="11" Padding="{TemplateBinding Padding}"
                    TextElement.Foreground="{TemplateBinding Foreground}">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource Hover}"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.7"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.35"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Input" TargetType="TextBox">
      <Setter Property="Height" Value="36"/>
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="CaretBrush" Value="{DynamicResource Text}"/>
      <Setter Property="SelectionBrush" Value="{DynamicResource AccentLine}"/>
      <Setter Property="SelectionOpacity" Value="0.35"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="b" Background="{DynamicResource Hover}" BorderBrush="{DynamicResource Line}" BorderThickness="1"
                    CornerRadius="11" Padding="8,0">
              <ScrollViewer x:Name="PART_ContentHost" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{DynamicResource AccentLine}"/></Trigger>
              <Trigger Property="Tag" Value="error"><Setter TargetName="b" Property="BorderBrush" Value="{DynamicResource Red}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid x:Name="RootGrid">
    <Grid x:Name="PaintedBg">
      <Rectangle Fill="{DynamicResource WBase}"/>
      <Rectangle Fill="{DynamicResource GlowA}"/>
      <Rectangle Fill="{DynamicResource GlowB}"/>
    </Grid>

    <Grid x:Name="Shell" Margin="20" RenderTransformOrigin="0.5,0.5">
      <Grid.RenderTransform><ScaleTransform/></Grid.RenderTransform>
      <Grid.RowDefinitions>
        <RowDefinition Height="40"/><RowDefinition Height="18"/><RowDefinition Height="*"/>
      </Grid.RowDefinitions>

      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="6,0,0,0">
          <TextBlock Text="Lumen" FontFamily="Segoe UI Variable Display, Segoe UI" FontSize="20" FontWeight="SemiBold" VerticalAlignment="Center"/>
          <ToggleButton x:Name="PowerBtn" Style="{StaticResource Switch}" Margin="18,1,0,0" VerticalAlignment="Center"
                        ToolTip="Automatic brightness" AutomationProperties.Name="Automatic brightness"/>
          <TextBlock x:Name="StatusText" Margin="10,1,0,0" VerticalAlignment="Center" FontSize="13" MaxWidth="210" TextTrimming="CharacterEllipsis"
                     Foreground="{DynamicResource Muted}" Text="Starting"/>
        </StackPanel>

        <Border Grid.Column="1" Height="36" CornerRadius="18" Padding="14,0" VerticalAlignment="Center"
                Background="{DynamicResource Capsule}">
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <Path Style="{StaticResource Glyph}" Stroke="{DynamicResource Muted}" VerticalAlignment="Center"
                  Data="M12,8 A4,4 0 1 0 12,16 A4,4 0 1 0 12,8 M12,2 V4 M12,20 V22 M4.93,4.93 L6.34,6.34 M17.66,17.66 L19.07,19.07 M2,12 H4 M20,12 H22 M4.93,19.07 L6.34,17.66 M17.66,6.34 L19.07,4.93"/>
            <TextBlock x:Name="BarLux" Margin="7,0,0,1" VerticalAlignment="Center" FontWeight="SemiBold" Typography.NumeralAlignment="Tabular" Text="-"
                       AutomationProperties.Name="Ambient light in lux"/>
            <TextBlock Style="{StaticResource Small}" Text="lx" Margin="4,1,0,0" VerticalAlignment="Center"/>
            <Rectangle Width="1" Height="16" Fill="{DynamicResource Line}" Margin="14,0"/>
            <Path Style="{StaticResource Glyph}" Stroke="{DynamicResource Muted}" VerticalAlignment="Center"
                  Data="M4,5 H20 A1,1 0 0 1 21,6 V16 A1,1 0 0 1 20,17 H4 A1,1 0 0 1 3,16 V6 A1,1 0 0 1 4,5 Z M9,21 H15 M12,17 V21"/>
            <TextBlock x:Name="BarBr" Margin="7,0,0,1" VerticalAlignment="Center" FontWeight="SemiBold" Typography.NumeralAlignment="Tabular" Text="-"
                       AutomationProperties.Name="Screen brightness in percent"/>
            <TextBlock Style="{StaticResource Small}" Text="%" Margin="3,1,0,0" VerticalAlignment="Center"/>
          </StackPanel>
        </Border>

        <StackPanel Grid.Column="2" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <Button x:Name="DrawerBtn" Style="{StaticResource IconBtn}" ToolTip="History and settings" AutomationProperties.Name="History and settings">
            <Path Style="{StaticResource Glyph}" Data="M6,4 H18 A2,2 0 0 1 20,6 V18 A2,2 0 0 1 18,20 H6 A2,2 0 0 1 4,18 V6 A2,2 0 0 1 6,4 Z M14.5,4 V20"/>
          </Button>
          <Button x:Name="ThemeBtn" Style="{StaticResource IconBtn}" Margin="8,0,0,0" ToolTip="Switch theme" AutomationProperties.Name="Switch theme">
            <Grid>
              <Path x:Name="Moon" Style="{StaticResource Glyph}" Data="M21,12.79 A9,9 0 1 1 11.21,3 A7,7 0 0 0 21,12.79 Z">
                <Path.RenderTransform><TransformGroup><ScaleTransform/><RotateTransform/></TransformGroup></Path.RenderTransform>
              </Path>
              <Path x:Name="Sun" Style="{StaticResource Glyph}"
                    Data="M12,8 A4,4 0 1 0 12,16 A4,4 0 1 0 12,8 M12,2 V4 M12,20 V22 M4.93,4.93 L6.34,6.34 M17.66,17.66 L19.07,19.07 M2,12 H4 M20,12 H22 M4.93,19.07 L6.34,17.66 M17.66,6.34 L19.07,4.93">
                <Path.RenderTransform><TransformGroup><ScaleTransform/><RotateTransform/></TransformGroup></Path.RenderTransform>
              </Path>
            </Grid>
          </Button>
          <Button x:Name="MinBtn" Style="{StaticResource IconBtn}" Margin="8,0,0,0" ToolTip="Minimize" AutomationProperties.Name="Minimize">
            <Path Style="{StaticResource Glyph}" Data="M6,12 H18"/>
          </Button>
          <Button x:Name="CloseBtn" Style="{StaticResource IconBtn}" Margin="8,0,0,0" ToolTip="Hide to tray" AutomationProperties.Name="Hide window to tray">
            <Path Style="{StaticResource Glyph}" Data="M7,7 L17,17 M17,7 L7,17"/>
          </Button>
        </StackPanel>
      </Grid>

      <ContentControl x:Name="HeroCard" Grid.Row="2" Style="{StaticResource Card}" Padding="24,22,24,22">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="36"/><RowDefinition Height="16"/><RowDefinition Height="20"/>
            <RowDefinition Height="*"/><RowDefinition Height="26"/><RowDefinition Height="37"/><RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <Grid>
            <Button x:Name="ProfileBtn" Style="{StaticResource Btn}" HorizontalAlignment="Left" ToolTip="Curve profiles">
              <StackPanel Orientation="Horizontal">
                <TextBlock x:Name="ProfileName" MaxWidth="220" TextTrimming="CharacterEllipsis" FontWeight="SemiBold"/>
                <Path Data="M1,1 L5,5 L9,1" Width="10" Height="6" Margin="9,2,0,0" VerticalAlignment="Center" StrokeThickness="1.6"
                      StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"
                      Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/>
              </StackPanel>
            </Button>
            <TextBlock x:Name="HintText" Style="{StaticResource Small}" HorizontalAlignment="Right" VerticalAlignment="Center"
                       Text="Sliders set the brightness for each light level. The dot shows the current reading."/>
          </Grid>

          <Grid Grid.Row="2" Margin="36,0,0,0"><UniformGrid x:Name="ValueRow" Rows="1"/></Grid>
          <Grid Grid.Row="3">
            <Canvas x:Name="AxisCanvas" Width="36" HorizontalAlignment="Left"/>
            <Grid Margin="36,0,0,0">
              <Canvas x:Name="PlotCanvas" ClipToBounds="False"/>
              <UniformGrid x:Name="BandRow" Rows="1"/>
              <Canvas x:Name="LiveCanvas" IsHitTestVisible="False"/>
            </Grid>
          </Grid>
          <Grid Grid.Row="4">
            <TextBlock Style="{StaticResource Small}" Text="lx" VerticalAlignment="Bottom" Width="28" TextAlignment="Right" HorizontalAlignment="Left"/>
            <Grid Margin="36,0,0,0"><UniformGrid x:Name="LuxRow" Rows="1" VerticalAlignment="Bottom"/></Grid>
          </Grid>

          <Rectangle Grid.Row="5" Height="1" Fill="{DynamicResource Line}" VerticalAlignment="Center"/>

          <Grid Grid.Row="6">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <UniformGrid x:Name="ToneRow" Rows="1" Margin="-10,0,0,0"/>
            <Button x:Name="ToneReset" Grid.Column="1" Style="{StaticResource IconBtn}" Margin="10,0,0,0" VerticalAlignment="Bottom"
                    ToolTip="Reset tone" AutomationProperties.Name="Reset tone">
              <Path Style="{StaticResource Glyph}" Data="M1,4 V10 H7 M3.51,15 A9,9 0 1 0 5.64,5.64 L1,10"/>
            </Button>
          </Grid>

          <ContentControl x:Name="Toast" Grid.RowSpan="3" Style="{StaticResource MenuCard}" Tag="22" Padding="18,4,4,4"
                          HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,-4,0,0"
                          Visibility="Collapsed" Opacity="0" RenderTransformOrigin="1,0">
            <ContentControl.RenderTransform><ScaleTransform ScaleX="0.96" ScaleY="0.96"/></ContentControl.RenderTransform>
            <StackPanel Orientation="Horizontal">
              <TextBlock x:Name="ToastText" VerticalAlignment="Center" MaxWidth="420" TextWrapping="Wrap" Margin="0,6"/>
              <Button x:Name="ToastAction" Style="{StaticResource Primary}" Margin="14,0,0,0" VerticalAlignment="Center" Visibility="Collapsed"/>
              <Button x:Name="ToastClose" Style="{StaticResource Btn}" Content="Close" Margin="8,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
          </ContentControl>
        </Grid>
      </ContentControl>

      <Grid x:Name="MenuLayer" Grid.RowSpan="3" Visibility="Collapsed">
        <Border x:Name="MenuScrim" Background="Transparent" WindowChrome.IsHitTestVisibleInChrome="True"/>
        <ContentControl x:Name="MenuCard" Style="{StaticResource MenuCard}" Width="272" HorizontalAlignment="Left" VerticalAlignment="Top"
                        RenderTransformOrigin="0,0" Opacity="0">
          <ContentControl.RenderTransform><ScaleTransform ScaleX="0.96" ScaleY="0.96"/></ContentControl.RenderTransform>
          <Grid>
            <StackPanel x:Name="MenuList">
              <ScrollViewer MaxHeight="207" VerticalScrollBarVisibility="Auto" Focusable="False">
                <StackPanel x:Name="ProfileList"/>
              </ScrollViewer>
              <Border Height="1" Margin="10,6" Background="{DynamicResource Line}"/>
              <StackPanel x:Name="ActionList"/>
            </StackPanel>
            <StackPanel x:Name="NameForm" Visibility="Collapsed" Margin="6,4,6,6">
              <TextBlock x:Name="NameTitle" Style="{StaticResource Label}"/>
              <TextBox x:Name="NameBox" Style="{StaticResource Input}" Margin="0,8,0,0" MaxLength="30" AutomationProperties.Name="Profile name"/>
              <TextBlock x:Name="NameError" Style="{StaticResource Small}" Foreground="{DynamicResource Red}" TextWrapping="Wrap"
                         Margin="0,6,0,0" Visibility="Collapsed"/>
              <Grid Margin="0,12,0,0">
                <Button x:Name="NameCancel" Style="{StaticResource Btn}" Content="Cancel" HorizontalAlignment="Left"/>
                <Button x:Name="NameSave" Style="{StaticResource Primary}" Content="Save" HorizontalAlignment="Right"/>
              </Grid>
            </StackPanel>
          </Grid>
        </ContentControl>
      </Grid>
    </Grid>

    <Grid x:Name="DrawerLayer" Visibility="Collapsed">
      <Rectangle x:Name="DrawerScrim" Fill="{DynamicResource Scrim}" Opacity="0" Margin="0,58,0,0" WindowChrome.IsHitTestVisibleInChrome="True">
        <Rectangle.OpacityMask>
          <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
            <GradientStop Color="#00000000" Offset="0"/><GradientStop Color="#FF000000" Offset="0.04"/>
          </LinearGradientBrush>
        </Rectangle.OpacityMask>
      </Rectangle>
      <ContentControl x:Name="Drawer" Style="{StaticResource MenuCard}" Tag="26" Padding="22,18,22,22" Width="360"
                      HorizontalAlignment="Right" Margin="12,78,12,12">
        <ContentControl.RenderTransform><TranslateTransform X="400"/></ContentControl.RenderTransform>
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <Grid>
            <TextBlock Text="History and settings" FontSize="16" FontWeight="SemiBold" VerticalAlignment="Center"/>
            <Button x:Name="DrawerClose" Style="{StaticResource IconBtn}" HorizontalAlignment="Right" ToolTip="Close panel" AutomationProperties.Name="Close panel">
              <Path Style="{StaticResource Glyph}" Data="M7,7 L17,17 M17,7 L7,17"/>
            </Button>
          </Grid>

          <StackPanel Grid.Row="1" Margin="0,16,0,0">
            <Grid>
              <TextBlock Style="{StaticResource Label}" Text="Ambient light" VerticalAlignment="Bottom" Margin="0,0,0,4"/>
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                <TextBlock x:Name="LuxValue" Style="{StaticResource Value}" Text="-"/>
                <TextBlock Style="{StaticResource Small}" Text="lx" Margin="5,0,0,4" VerticalAlignment="Bottom"/>
              </StackPanel>
            </Grid>
            <Canvas x:Name="LuxChart" Height="84" Margin="0,6,0,0"/>
          </StackPanel>

          <StackPanel Grid.Row="2" Margin="0,16,0,0">
            <Grid>
              <TextBlock Style="{StaticResource Label}" Text="Screen brightness" VerticalAlignment="Bottom" Margin="0,0,0,4"/>
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                <TextBlock x:Name="BrValue" Style="{StaticResource Value}" Text="-"/>
                <TextBlock Style="{StaticResource Small}" Text="%" Margin="5,0,0,4" VerticalAlignment="Bottom"/>
              </StackPanel>
            </Grid>
            <Canvas x:Name="BrChart" Height="84" Margin="0,6,0,0"/>
            <Grid Margin="36,4,0,0">
              <TextBlock Style="{StaticResource Small}" Text="3 min ago"/>
              <TextBlock Style="{StaticResource Small}" Text="now" HorizontalAlignment="Right"/>
            </Grid>
          </StackPanel>

          <Rectangle Grid.Row="3" Height="1" Fill="{DynamicResource Line}" Margin="0,18,0,16"/>

          <StackPanel Grid.Row="4">
            <Grid>
              <TextBlock Text="Transition speed"/>
              <TextBlock x:Name="SpeedText" Style="{StaticResource Small}" HorizontalAlignment="Right" VerticalAlignment="Bottom" Text="medium"/>
            </Grid>
            <Slider x:Name="SpeedSlider" Style="{StaticResource Range}" Minimum="1" Maximum="5" SmallChange="1" LargeChange="1"
                    IsSnapToTickEnabled="True" TickFrequency="1" Margin="0,8,0,0" AutomationProperties.Name="Brightness transition speed"/>
            <Grid Margin="0,16,0,0">
              <TextBlock Text="Start at sign-in" VerticalAlignment="Center"/>
              <ToggleButton x:Name="AutostartBox" Style="{StaticResource Switch}" HorizontalAlignment="Right"
                            AutomationProperties.Name="Start at sign-in"/>
            </Grid>
          </StackPanel>

          <TextBlock Grid.Row="5" Style="{StaticResource Small}" TextWrapping="Wrap" LineHeight="17" Margin="0,16,0,0" VerticalAlignment="Top"
                     Text="Turn off automatic brightness in Windows, otherwise the two will keep correcting each other."/>

          <Grid Grid.Row="6" Margin="0,12,0,0">
            <Button x:Name="WinSettingsBtn" Style="{StaticResource Btn}" Content="Display settings" HorizontalAlignment="Left"/>
            <Button x:Name="QuitBtn" Style="{StaticResource Btn}" Content="Quit" HorizontalAlignment="Right"/>
          </Grid>
        </Grid>
      </ContentControl>
    </Grid>
  </Grid>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Parse($Xaml)
function Find($Name) {
    return $window.FindName($Name)
}

$inv = [Globalization.CultureInfo]::InvariantCulture
function N([double]$v) {
    return $v.ToString('0.##', $inv)
}
function ToColor([string]$hex) {
    return [Windows.Media.Color][Windows.Media.ColorConverter]::ConvertFromString($hex)
}
$Motion = [Windows.SystemParameters]::ClientAreaAnimation -and -not $RenderTo
function Dur([double]$ms) {
    if (-not $Motion) {
        $ms = 0
    }
    return New-Object Windows.Duration ([TimeSpan]::FromMilliseconds($ms))
}
$EaseOut = New-Object Windows.Media.Animation.CubicEase
$EaseOut.EasingMode = 'EaseOut'
function Animate($Target, $Property, [double]$To, [double]$Ms) {
    if (-not $Motion -or $Ms -le 0) {
        $Target.BeginAnimation($Property, $null)
        $Target.SetValue($Property, $To)
        return
    }
    $a = New-Object Windows.Media.Animation.DoubleAnimation
    $a.To = $To
    $a.Duration = Dur $Ms
    $a.EasingFunction = $EaseOut
    $Target.BeginAnimation($Property, $a)
}
function After([double]$Ms, [scriptblock]$Do) {
    $t = New-Object Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds($Ms)
    $t.Tag = $Do
    $t.Add_Tick({
        param($sender, $e)
        $sender.Stop()
        & $sender.Tag
    })
    $t.Start()
}

$cfg = Read-Config (-not $RenderTo)
$Active = Find-Profile $cfg $cfg.Default
$Theme = $cfg.Theme
if ($RenderTo) {
    $Theme = $RenderTheme
}
if (-not $Theme) {
    $Theme = 'dark'
    try {
        $v = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop
        if ($v.AppsUseLightTheme -eq 1) {
            $Theme = 'light'
        }
    } catch { }
}

function New-Gradient([string]$From, [string]$To, [double]$X1, [double]$Y1, [double]$X2, [double]$Y2) {
    $g = [Windows.Media.LinearGradientBrush]::new((ToColor $From), (ToColor $To), [Windows.Point]::new($X1, $Y1), [Windows.Point]::new($X2, $Y2))
    $g.Freeze()
    return $g
}
function New-Glow([string]$Color, [double]$CX, [double]$CY, [double]$RX, [double]$RY) {
    $c = ToColor $Color
    $c0 = $c
    $c0.A = 0
    $g = [Windows.Media.RadialGradientBrush]::new($c, $c0)
    $g.Center = [Windows.Point]::new($CX, $CY)
    $g.GradientOrigin = $g.Center
    $g.RadiusX = $RX
    $g.RadiusY = $RY
    $g.Freeze()
    return $g
}
function Set-ThemeResources([string]$Name) {
    $t = $Themes[$Name]
    foreach ($k in $BrushKeys) {
        $b = [Windows.Media.SolidColorBrush]::new((ToColor $t[$k]))
        $b.Freeze()
        $window.Resources[$k] = $b
    }
    $window.Resources['EdgeStroke'] = New-Gradient $t.EdgeHi $t.EdgeLo 0 0 1 1
    $window.Resources['Area'] = New-Gradient $t.AreaHi $t.AreaLo 0 0 0 1
    $window.Resources['GlowA'] = New-Glow $t.GlowA 0.1 0.0 0.8 0.95
    $window.Resources['GlowB'] = New-Glow $t.GlowB 0.98 1.0 0.7 0.8
    $card = [Windows.Media.Effects.DropShadowEffect]::new()
    $card.Color = 'Black'
    $card.Direction = 270
    $card.ShadowDepth = 14
    $card.BlurRadius = 44
    $card.Opacity = $t.Shadow
    $card.Freeze()
    $window.Resources['CardShadow'] = $card
    $knob = [Windows.Media.Effects.DropShadowEffect]::new()
    $knob.Color = 'Black'
    $knob.Direction = 270
    $knob.ShadowDepth = 1.5
    $knob.BlurRadius = 6
    $knob.Opacity = $t.KnobShadow
    $knob.Freeze()
    $window.Resources['KnobShadow'] = $knob
}
Set-ThemeResources $Theme
function Use($Element, $Property, [string]$Key) {
    $Element.SetResourceReference($Property, $Key)
}

$shell = Find 'Shell'

function Set-IconState($Icon, [double]$Opacity, [double]$Scale, [double]$Angle, [double]$Ms) {
    $scaleTransform = $Icon.RenderTransform.Children[0]
    $rotateTransform = $Icon.RenderTransform.Children[1]
    Animate $Icon ([Windows.UIElement]::OpacityProperty) $Opacity $Ms
    Animate $scaleTransform ([Windows.Media.ScaleTransform]::ScaleXProperty) $Scale $Ms
    Animate $scaleTransform ([Windows.Media.ScaleTransform]::ScaleYProperty) $Scale $Ms
    Animate $rotateTransform ([Windows.Media.RotateTransform]::AngleProperty) $Angle $Ms
}

function Update-ThemeIcon([double]$Ms) {
    $moon = Find 'Moon'
    $sun = Find 'Sun'
    $show = $moon
    $hide = $sun
    if ($Theme -eq 'dark') {
        $show = $sun
        $hide = $moon
    }
    Set-IconState $show 1.0 1.0 0.0 $Ms
    Set-IconState $hide 0.0 0.4 90.0 $Ms
}

function Set-Theme([string]$Name, [bool]$Animated) {
    $script:Theme = $Name
    if ($Animated -and $Motion -and $window.IsVisible) {
        Animate $shell ([Windows.UIElement]::OpacityProperty) 0 90
        Update-ThemeIcon 260
        After 100 {
            Set-ThemeResources $Theme
            Set-WindowFrame
            Animate $shell ([Windows.UIElement]::OpacityProperty) 1 240
        }
    } else {
        Set-ThemeResources $Name
        Update-ThemeIcon 0
        Set-WindowFrame
    }
}

$NativeOk = $false
if (-not $RenderTo) {
    try {
        Add-Type -Namespace Lumen -Name Native -MemberDefinition @'
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
[DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
[DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] public static extern IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr value);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
'@
        Add-Type -AssemblyName System.Drawing
        $NativeOk = $true
    } catch { }
}

function Set-WindowFrame {
    if (-not $NativeOk -or $RenderTo) {
        return
    }
    try {
        $h = (New-Object Windows.Interop.WindowInteropHelper $window).Handle
        if ($h -eq [IntPtr]::Zero) {
            return
        }
        $dark = 0
        if ($Theme -eq 'dark') {
            $dark = 1
        }
        [void][Lumen.Native]::DwmSetWindowAttribute($h, 20, [ref]$dark, 4)
    } catch { }
}

function Initialize-Frame {
    if (-not $NativeOk) {
        return
    }
    try {
        $h = (New-Object Windows.Interop.WindowInteropHelper $window).Handle
        $style = [Lumen.Native]::GetWindowLongPtr($h, -16).ToInt64()
        [void][Lumen.Native]::SetWindowLongPtr($h, -16, [IntPtr]($style -band (-bnot 0x80000L)))
        [void][Lumen.Native]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 0, 0, 0x37)
        $round = 2
        [void][Lumen.Native]::DwmSetWindowAttribute($h, 33, [ref]$round, 4)
        Set-WindowFrame
    } catch { }
}
$window.Add_SourceInitialized({ Initialize-Frame })

$FrostOn = $true
try {
    $FrostOn = ((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name EnableTransparency -ErrorAction Stop).EnableTransparency -ne 0)
} catch { }
function Update-Frost($Card, $Source) {
    if (-not $FrostOn) {
        return
    }
    $clip = $Card.Template.FindName('FrostClip', $Card)
    $fill = $Card.Template.FindName('FrostFill', $Card)
    if ($null -eq $clip -or $Card.ActualWidth -le 0) {
        return
    }
    $w = $Card.ActualWidth
    $h = $Card.ActualHeight
    $r = [double]$Card.Tag
    $pad = 52.0
    $origin = $Card.TranslatePoint([Windows.Point]::new(0, 0), [Windows.Media.VisualTreeHelper]::GetParent($Source))
    $t = $Card.RenderTransform
    if ($t -is [Windows.Media.TranslateTransform]) {
        $origin.X -= $t.X
        $origin.Y -= $t.Y
    }
    $brush = [Windows.Media.VisualBrush]::new($Source)
    $brush.Stretch = 'None'
    $brush.AlignmentX = 'Left'
    $brush.AlignmentY = 'Top'
    $brush.ViewboxUnits = 'Absolute'
    $brush.Viewbox = [Windows.Rect]::new($origin.X - $pad, $origin.Y - $pad, $w + 2 * $pad, $h + 2 * $pad)
    $fill.Fill = $brush
    $clip.Clip = [Windows.Media.RectangleGeometry]::new([Windows.Rect]::new(0, 0, $w, $h), $r, $r)
    $clip.Visibility = 'Visible'
    $Card.Template.FindName('FrostTint', $Card).Visibility = 'Visible'
}

$Knob = 20.0
$Values = Get-TonedValues $Active.Values $Active.Tone
$Sliders = @()
$ValueLabels = @()
$LuxLabels = @()
$bandRow = Find 'BandRow'
$valueRow = Find 'ValueRow'
$luxRow = Find 'LuxRow'
$plot = Find 'PlotCanvas'
$live = Find 'LiveCanvas'
$axis = Find 'AxisCanvas'
$Drag = @{ Slider = $null; Offset = 0.0 }
$Suppress = $false
$RingOn = $false

function Get-PlotY([double]$Pct, [double]$H) {
    return $Knob / 2 + (1 - $Pct / 100) * ($H - $Knob)
}
function Get-PctFromY([double]$Y, [double]$H) {
    if ($H -le $Knob) {
        return 0
    }
    $p = (1 - ($Y - $Knob / 2) / ($H - $Knob)) * 100
    return [int][Math]::Round([Math]::Min([double]100, [Math]::Max([double]0, [double]$p)))
}

function New-StepButton([int]$Index, [int]$Delta) {
    $arrow = New-Object Windows.Shapes.Path
    if ($Delta -gt 0) {
        $arrow.Data = [Windows.Media.Geometry]::Parse('M0,3 L3,0 L6,3')
        $name = 'Increase brightness at {0} lx' -f $BandLux[$Index]
    } else {
        $arrow.Data = [Windows.Media.Geometry]::Parse('M0,0 L3,3 L6,0')
        $name = 'Decrease brightness at {0} lx' -f $BandLux[$Index]
    }
    $arrow.StrokeThickness = 1.4
    $arrow.Opacity = 0.8
    $arrow.StrokeStartLineCap = 'Round'
    $arrow.StrokeEndLineCap = 'Round'
    $arrow.StrokeLineJoin = 'Round'
    Use $arrow ([Windows.Shapes.Shape]::StrokeProperty) 'Muted'
    $button = New-Object Windows.Controls.Primitives.RepeatButton
    $button.Style = $window.Resources['Step']
    $button.Content = $arrow
    $button.Tag = @{
        Index = $Index
        Delta = $Delta
    }
    $button.ToolTip = $name
    [Windows.Automation.AutomationProperties]::SetName($button, $name)
    $button.Add_Click({
        param($sender, $e)
        $slider = $Sliders[$sender.Tag.Index]
        $next = $slider.Value + $sender.Tag.Delta
        if ($next -ge 0 -and $next -le 100) {
            $slider.Value = $next
        }
    })
    $button.Add_MouseEnter({
        param($sender, $e)
        Use $sender.Content ([Windows.Shapes.Shape]::StrokeProperty) 'Text'
    })
    $button.Add_MouseLeave({
        param($sender, $e)
        Use $sender.Content ([Windows.Shapes.Shape]::StrokeProperty) 'Muted'
    })
    return $button
}

for ($i = 0; $i -lt $BandLux.Length; $i++) {
    $lbl = New-Object Windows.Controls.TextBlock
    $lbl.TextAlignment = 'Center'
    $lbl.VerticalAlignment = 'Center'
    $lbl.Width = 36
    $lbl.FontWeight = 'SemiBold'
    $lbl.FontSize = 13
    [Windows.Documents.Typography]::SetNumeralAlignment($lbl, 'Tabular')
    $cell = New-Object Windows.Controls.StackPanel
    $cell.Orientation = 'Horizontal'
    $cell.HorizontalAlignment = 'Center'
    [void]$cell.Children.Add((New-StepButton $i -1))
    [void]$cell.Children.Add($lbl)
    [void]$cell.Children.Add((New-StepButton $i 1))
    [void]$valueRow.Children.Add($cell)
    $ValueLabels += $lbl

    $s = New-Object Windows.Controls.Slider
    $s.Style = $window.Resources['Band']
    $s.Value = $Values[$i]
    $s.Tag = $i
    [Windows.Automation.AutomationProperties]::SetName($s, ('Brightness at {0} lx' -f $BandLux[$i]))
    [void]$bandRow.Children.Add($s)
    $Sliders += $s

    $lx = New-Object Windows.Controls.TextBlock
    $lx.Style = $window.Resources['Small']
    $lx.TextAlignment = 'Center'
    $lx.Text = [string][int]$BandLux[$i]
    [void]$luxRow.Children.Add($lx)
    $LuxLabels += $lx

    $s.Add_PreviewMouseLeftButtonDown({
            param($sender, $e)
            $y = $e.GetPosition($sender).Y
            $h = $sender.ActualHeight
            $knobY = Get-PlotY $sender.Value $h
            if ([Math]::Abs($y - $knobY) -le 15) {
                $Drag.Offset = $y - $knobY
            }
            else {
                $Drag.Offset = 0
                $sender.Value = Get-PctFromY $y $h
            }
            $Drag.Slider = $sender
            $script:RingOn = $false
            [void]$sender.Focus()
            [void]$sender.CaptureMouse()
            $e.Handled = $true
        })
    $s.Add_PreviewMouseMove({
            param($sender, $e)
            if ($Drag.Slider -eq $sender -and $sender.IsMouseCaptured) {
                $sender.Value = Get-PctFromY ($e.GetPosition($sender).Y - $Drag.Offset) $sender.ActualHeight
            }
        })
    $s.Add_PreviewMouseLeftButtonUp({
            param($sender, $e)
            if ($Drag.Slider -eq $sender) {
                $Drag.Slider = $null
                $sender.ReleaseMouseCapture()
                $e.Handled = $true
            }
        })
    $s.Add_LostMouseCapture({
        param($sender, $e)
        if ($Drag.Slider -eq $sender) {
            $Drag.Slider = $null
        }
    })
    $s.Add_ValueChanged({
            param($sender, $e)
            $i = [int]$sender.Tag
            $v = [int][Math]::Round($sender.Value)
            if ($sender.Value -ne $v) {
                $sender.Value = $v
                return
            }
            $Values[$i] = $v
            Update-Band $i
            Update-Curve
            if (-not $Suppress) {
                Save-ManualEdit $i
            }
        })
    $s.Add_GotKeyboardFocus({
            param($sender, $e)
            $script:RingOn = ([Windows.Input.InputManager]::Current.MostRecentInputDevice -is [Windows.Input.KeyboardDevice])
            Update-FocusRing
        })
    $s.Add_PreviewKeyDown({
        param($sender, $e)
        $script:RingOn = $true
        Update-FocusRing
    })
    $s.Add_LostKeyboardFocus({
        param($sender, $e)
        Update-FocusRing
    })
}

function Update-Band([int]$i) {
    $ValueLabels[$i].Text = ('{0}%' -f $Values[$i])
}

$gridLines = @()
foreach ($p in 0, 25, 50, 75, 100) {
    $ln = New-Object Windows.Shapes.Line
    Use $ln ([Windows.Shapes.Shape]::StrokeProperty) 'Line'
    $ln.StrokeThickness = 1
    $ln.SnapsToDevicePixels = $true
    [void]$plot.Children.Add($ln)
    $t = New-Object Windows.Controls.TextBlock
    $t.Style = $window.Resources['Small']
    $t.Width = 28
    $t.TextAlignment = 'Right'
    if ($p % 50 -eq 0) {
        $t.Text = [string]$p
    }
    [Windows.Documents.Typography]::SetNumeralAlignment($t, 'Tabular')
    [void]$axis.Children.Add($t)
    $gridLines += @{
        Value = $p
        Line = $ln
        Label = $t
    }
}
$areaPath = New-Object Windows.Shapes.Path
Use $areaPath ([Windows.Shapes.Shape]::FillProperty) 'Area'
[void]$plot.Children.Add($areaPath)
$curvePath = New-Object Windows.Shapes.Path
Use $curvePath ([Windows.Shapes.Shape]::StrokeProperty) 'AccentLine'
$curvePath.StrokeThickness = 2.5
$curvePath.StrokeLineJoin = 'Round'
$curvePath.StrokeStartLineCap = 'Round'
$curvePath.StrokeEndLineCap = 'Round'
[void]$plot.Children.Add($curvePath)

$liveLine = New-Object Windows.Shapes.Line
Use $liveLine ([Windows.Shapes.Shape]::StrokeProperty) 'Muted'
$liveLine.StrokeThickness = 1
$liveDash = New-Object Windows.Media.DoubleCollection
$liveDash.Add(4)
$liveDash.Add(4)
$liveLine.StrokeDashArray = $liveDash
$liveLine.Visibility = 'Collapsed'
[void]$live.Children.Add($liveLine)
$liveDot = New-Object Windows.Shapes.Ellipse
$liveDot.Width = 14
$liveDot.Height = 14
Use $liveDot ([Windows.Shapes.Shape]::FillProperty) 'AccentLine'
Use $liveDot ([Windows.Shapes.Shape]::StrokeProperty) 'Knob'
$liveDot.StrokeThickness = 2.5
$liveDot.Visibility = 'Collapsed'
[void]$live.Children.Add($liveDot)
$focusRing = New-Object Windows.Shapes.Ellipse
$focusRing.Width = 32
$focusRing.Height = 32
Use $focusRing ([Windows.Shapes.Shape]::StrokeProperty) 'Focus'
$focusRing.StrokeThickness = 2
$focusRing.Visibility = 'Collapsed'
[void]$live.Children.Add($focusRing)

function Get-ColumnX([double]$Position) {
    $w = $bandRow.ActualWidth / $BandLux.Length
    return $w * ($Position + 0.5)
}

function Update-Curve {
    $h = $bandRow.ActualHeight
    $w = $bandRow.ActualWidth
    if ($h -le $Knob -or $w -le 0) {
        return
    }
    foreach ($g in $gridLines) {
        $y = [Math]::Round((Get-PlotY $g.Value $h)) + 0.5
        $g.Line.X1 = 0
        $g.Line.X2 = $w
        $g.Line.Y1 = $y
        $g.Line.Y2 = $y
        [Windows.Controls.Canvas]::SetTop($g.Label, $y - 9)
    }
    $pts = @()
    for ($i = 0; $i -lt $Values.Length; $i++) {
        $pts += ('{0},{1}' -f (N (Get-ColumnX $i)), (N (Get-PlotY $Values[$i] $h)))
    }
    $line = 'M ' + ($pts -join ' L ')
    $curvePath.Data = [Windows.Media.Geometry]::Parse($line)
    $base = N (Get-PlotY 0 $h)
    $areaPath.Data = [Windows.Media.Geometry]::Parse(('{0} L {1},{2} L {3},{2} Z' -f $line, (N (Get-ColumnX ($Values.Length - 1))), $base, (N (Get-ColumnX 0))))
    Update-FocusRing
}

function Update-FocusRing {
    $focused = $null
    foreach ($s in $Sliders) {
        if ($s.IsKeyboardFocused) {
            $focused = $s
        }
    }
    if ($null -eq $focused -or -not $RingOn -or $bandRow.ActualHeight -le $Knob) {
        $focusRing.Visibility = 'Collapsed'
        return
    }
    $i = [int]$focused.Tag
    [Windows.Controls.Canvas]::SetLeft($focusRing, (Get-ColumnX $i) - 16)
    [Windows.Controls.Canvas]::SetTop($focusRing, (Get-PlotY $Values[$i] $bandRow.ActualHeight) - 16)
    $focusRing.Visibility = 'Visible'
}

$ToneNames = 'Exposure', 'Contrast', 'Highlights', 'Shadows'
$ToneHelp = 'The whole curve brighter or darker', 'Difference between brightness in the dark and in full light',
'Screen brightness in strong light', 'Screen brightness in dim light'
$ToneSliders = @()
$ToneLabels = @()
$ToneFills = @()
$toneRow = Find 'ToneRow'

function Get-ValueFromX($Slider, [double]$X) {
    $w = $Slider.ActualWidth
    if ($w -le $Knob) {
        return $Slider.Value
    }
    $u = [Math]::Min([double]1, [Math]::Max([double]0, ($X - $Knob / 2) / ($w - $Knob)))
    return [Math]::Round($Slider.Minimum + $u * ($Slider.Maximum - $Slider.Minimum))
}
function Set-ToneLabel([int]$j, [int]$v) {
    $ToneLabels[$j].Text = Format-Tone $v
    $key = 'Muted'
    $weight = 'Normal'
    if ($v -ne 0) {
        $key = 'Text'
        $weight = 'SemiBold'
    }
    Use $ToneLabels[$j] ([Windows.Controls.TextBlock]::ForegroundProperty) $key
    $ToneLabels[$j].FontWeight = $weight
}
function Format-Tone([int]$v) {
    if ($v -gt 0) {
        return "+$v"
    }
    if ($v -lt 0) {
        return ([string][char]0x2212) + [Math]::Abs($v)
    }
    return '0'
}

for ($j = 0; $j -lt 4; $j++) {
    $panel = New-Object Windows.Controls.StackPanel
    $panel.Margin = New-Object Windows.Thickness 10, 0, 10, 0
    $head = New-Object Windows.Controls.Grid
    $name = New-Object Windows.Controls.TextBlock
    $name.Text = $ToneNames[$j]
    $name.FontSize = 13
    $val = New-Object Windows.Controls.TextBlock
    $val.Style = $window.Resources['Small']
    $val.HorizontalAlignment = 'Right'
    $val.VerticalAlignment = 'Bottom'
    [Windows.Documents.Typography]::SetNumeralAlignment($val, 'Tabular')
    [void]$head.Children.Add($name)
    [void]$head.Children.Add($val)
    $s = New-Object Windows.Controls.Slider
    $s.Style = $window.Resources['Tone']
    $s.Tag = $j
    $s.Value = $Active.Tone[$j]
    $s.ToolTip = $ToneHelp[$j]
    [Windows.Automation.AutomationProperties]::SetName($s, $ToneNames[$j])
    $wrap = New-Object Windows.Controls.Grid
    $wrap.Margin = New-Object Windows.Thickness 0, 6, 0, 0
    $fill = New-Object Windows.Controls.Border
    $fill.Height = 4
    $fill.CornerRadius = New-Object Windows.CornerRadius 2
    $fill.Width = 0
    $fill.HorizontalAlignment = 'Left'
    $fill.VerticalAlignment = 'Center'
    $fill.IsHitTestVisible = $false
    Use $fill ([Windows.Controls.Border]::BackgroundProperty) 'AccentLine'
    [void]$wrap.Children.Add($fill)
    [void]$wrap.Children.Add($s)
    $zero = New-Object Windows.Controls.Border
    $zero.Width = 2
    $zero.Height = 5
    $zero.CornerRadius = New-Object Windows.CornerRadius 1
    $zero.HorizontalAlignment = 'Center'
    $zero.Margin = New-Object Windows.Thickness 0, 1, 0, 0
    Use $zero ([Windows.Controls.Border]::BackgroundProperty) 'Muted'
    [void]$panel.Children.Add($head)
    [void]$panel.Children.Add($wrap)
    [void]$panel.Children.Add($zero)
    [void]$toneRow.Children.Add($panel)
    $ToneSliders += $s
    $ToneLabels += $val
    $ToneFills += $fill
    Set-ToneLabel $j $Active.Tone[$j]
    $s.Add_SizeChanged({
        param($sender, $e)
        Update-ToneFill ([int]$sender.Tag)
    })

    $s.Add_PreviewMouseLeftButtonDown({
            param($sender, $e)
            if ($e.ClickCount -ge 2) {
                $sender.Value = 0
                $e.Handled = $true
                return
            }
            $x = $e.GetPosition($sender).X
            $span = $sender.Maximum - $sender.Minimum
            $knobX = $Knob / 2 + ($sender.Value - $sender.Minimum) / $span * ($sender.ActualWidth - $Knob)
            if ([Math]::Abs($x - $knobX) -le 15) {
                $Drag.Offset = $x - $knobX
            }
            else {
                $Drag.Offset = 0
                $sender.Value = Get-ValueFromX $sender $x
            }
            $Drag.Slider = $sender
            [void]$sender.Focus()
            [void]$sender.CaptureMouse()
            $e.Handled = $true
        })
    $s.Add_PreviewMouseMove({
            param($sender, $e)
            if ($Drag.Slider -eq $sender -and $sender.IsMouseCaptured) {
                $sender.Value = Get-ValueFromX $sender ($e.GetPosition($sender).X - $Drag.Offset)
            }
        })
    $s.Add_PreviewMouseLeftButtonUp({
            param($sender, $e)
            if ($Drag.Slider -eq $sender) {
                $Drag.Slider = $null
                $sender.ReleaseMouseCapture()
                $e.Handled = $true
            }
        })
    $s.Add_LostMouseCapture({
        param($sender, $e)
        if ($Drag.Slider -eq $sender) {
            $Drag.Slider = $null
        }
    })
    $s.Add_ValueChanged({
            param($sender, $e)
            $j = [int]$sender.Tag
            $v = [int][Math]::Round($sender.Value)
            if ($sender.Value -ne $v) {
                $sender.Value = $v
                return
            }
            Set-ToneLabel $j $v
            Update-ToneFill $j
            if ($Suppress) {
                return
            }
            if (-not (Enter-Editable)) {
                return
            }
            $Active.Tone[$j] = $v
            Show-Effective
            Update-ToneReset
            Push-Values
        })
}

function Update-ToneFill([int]$j) {
    $s = $ToneSliders[$j]
    $w = $s.ActualWidth
    if ($w -le $Knob) {
        return
    }
    $center = $w / 2
    $knobX = $Knob / 2 + ($s.Value - $s.Minimum) / ($s.Maximum - $s.Minimum) * ($w - $Knob)
    $ToneFills[$j].Margin = New-Object Windows.Thickness ([Math]::Min([double]$center, [double]$knobX)), 0, 0, 0
    $ToneFills[$j].Width = [Math]::Abs($knobX - $center)
}

function Update-ToneReset {
    (Find 'ToneReset').IsEnabled = (($Active.Tone -join ',') -ne '0,0,0,0')
}

function Sync-ToneSliders {
    $script:Suppress = $true
    for ($j = 0; $j -lt 4; $j++) {
        $ToneSliders[$j].Value = $Active.Tone[$j]
        Set-ToneLabel $j $Active.Tone[$j]
    }
    $script:Suppress = $false
    Update-ToneReset
}

function Show-Effective {
    $eff = Get-TonedValues $Active.Values $Active.Tone
    $script:Suppress = $true
    for ($i = 0; $i -lt $Sliders.Length; $i++) {
        $Sliders[$i].Value = $eff[$i]
    }
    $script:Suppress = $false
    Update-Curve
}

(Find 'ToneReset').Add_Click({
        $Active.Tone = [int[]](0, 0, 0, 0)
        Sync-ToneSliders
        Show-Effective
        Push-Values
    })

function Get-ProfileNames([string]$Except) {
    $names = @()
    foreach ($p in $cfg.Profiles) {
        if ($p.Name -ne $Except) {
            $names += $p.Name
        }
    }
    return , [string[]]$names
}
function Get-FreeName([string]$Wanted) {
    return Get-UniqueName $Wanted (Get-ProfileNames '')
}
function Update-ProfileButton {
    (Find 'ProfileName').Text = $Active.Name
    [Windows.Automation.AutomationProperties]::SetName((Find 'ProfileBtn'), ('Profile: {0}' -f $Active.Name))
}

function Enter-Editable {
    if (-not $Active.Locked) {
        return $true
    }
    if ($cfg.Profiles.Count -ge $MaxProfiles) {
        Sync-ToneSliders
        Show-Effective
        Show-Toast ('You already have {0} profiles. Delete one to edit a built-in profile.' -f $MaxProfiles)
        return $false
    }
    $source = $Active.Name
    $copy = New-ProfileObject (Get-FreeName ('{0} copy' -f $source)) $Active.Values $Active.Tone $false
    [void]$cfg.Profiles.Add($copy)
    if ($cfg.Default -eq $source) {
        $cfg.Default = $copy.Name
    }
    $script:Active = $copy
    Update-ProfileButton
    return $true
}

function Save-ManualEdit([int]$Index) {
    if (-not (Enter-Editable)) {
        return
    }
    $position = $Index / [double]($BandLux.Length - 1)
    $Active.Values[$Index] = Get-BaseForTarget $Values[$Index] $Active.Tone $position $Active.Values[$Index]
    $reached = Get-TonedValue $Active.Values[$Index] $Active.Tone $position
    if ($reached -ne $Values[$Index]) {
        $script:Suppress = $true
        $Sliders[$Index].Value = $reached
        $script:Suppress = $false
    }
    Push-Values
}

function Select-Profile($Profile) {
    $script:Active = $Profile
    Update-ProfileButton
    Sync-ToneSliders
    Show-Effective
    Push-Values
}

$menuLayer = Find 'MenuLayer'
$menuCard = Find 'MenuCard'
$heroCard = Find 'HeroCard'
$menuList = Find 'MenuList'
$nameForm = Find 'NameForm'
$profileList = Find 'ProfileList'
$actionList = Find 'ActionList'
$NameMode = 'new'
$Undo = $null

function New-MenuButton([string]$Text) {
    $b = New-Object Windows.Controls.Button
    $b.Style = $window.Resources['MenuItem']
    $b.Content = $Text
    $b.Padding = New-Object Windows.Thickness 36, 8, 10, 8
    return $b
}

function Build-MenuList {
    $profileList.Children.Clear()
    $actionList.Children.Clear()
    foreach ($p in $cfg.Profiles) {
        $b = New-Object Windows.Controls.Button
        $b.Style = $window.Resources['MenuItem']
        $b.Tag = $p
        $row = New-Object Windows.Controls.Grid
        foreach ($w in 'Auto', '*', 'Auto') {
            $cd = New-Object Windows.Controls.ColumnDefinition
            if ($w -eq '*') {
                $cd.Width = New-Object Windows.GridLength 1, 'Star'
            } else {
                $cd.Width = [Windows.GridLength]::Auto
            }
            $row.ColumnDefinitions.Add($cd)
        }
        $tick = New-Object Windows.Shapes.Path
        $tick.Data = [Windows.Media.Geometry]::Parse('M3,9.5 L7,13.5 L15,5')
        $tick.Width = 18
        $tick.Height = 18
        $tick.StrokeThickness = 2
        $tick.StrokeLineJoin = 'Round'
        $tick.StrokeStartLineCap = 'Round'
        $tick.StrokeEndLineCap = 'Round'
        Use $tick ([Windows.Shapes.Shape]::StrokeProperty) 'Text'
        $isActive = ($p.Name -eq $Active.Name)
        if (-not $isActive) {
            $tick.Visibility = 'Hidden'
        }
        $nm = New-Object Windows.Controls.TextBlock
        $nm.Text = $p.Name
        $nm.TextTrimming = 'CharacterEllipsis'
        $nm.Margin = New-Object Windows.Thickness 8, 0, 8, 0
        [Windows.Controls.Grid]::SetColumn($nm, 1)
        [void]$row.Children.Add($tick)
        [void]$row.Children.Add($nm)
        $label = $p.Name
        if ($isActive) {
            $label += ', selected'
        }
        if ($p.Name -eq $cfg.Default) {
            $tag = New-Object Windows.Controls.TextBlock
            $tag.Style = $window.Resources['Small']
            $tag.Text = 'default'
            $tag.VerticalAlignment = 'Center'
            [Windows.Controls.Grid]::SetColumn($tag, 2)
            [void]$row.Children.Add($tag)
            $label += ', default'
        }
        $b.Content = $row
        [Windows.Automation.AutomationProperties]::SetName($b, $label)
        $b.Add_Click({
            param($sender, $e)
            Select-Profile $sender.Tag
            Close-Menu
        })
        [void]$profileList.Children.Add($b)
    }
    $b = New-MenuButton 'Save as new profile'
    $b.Add_Click({ Open-NameForm 'new' })
    [void]$actionList.Children.Add($b)
    $b = New-MenuButton 'Rename'
    $b.IsEnabled = -not $Active.Locked
    $b.Add_Click({ Open-NameForm 'rename' })
    [void]$actionList.Children.Add($b)
    $b = New-MenuButton 'Set as default'
    $b.IsEnabled = ($Active.Name -ne $cfg.Default)
    $b.Add_Click({
            $cfg.Default = $Active.Name
            Request-Save
            Build-MenuList
            [void]$profileList.Children[0].Focus()
        })
    [void]$actionList.Children.Add($b)
    $b = New-MenuButton 'Delete profile'
    $b.IsEnabled = -not $Active.Locked
    Use $b ([Windows.Controls.Control]::ForegroundProperty) 'Red'
    $b.Add_Click({
        Remove-ActiveProfile
        Close-Menu
    })
    [void]$actionList.Children.Add($b)
}

function Open-Menu {
    Build-MenuList
    $nameForm.Visibility = 'Collapsed'
    $menuList.Visibility = 'Visible'
    $btn = Find 'ProfileBtn'
    $pt = $btn.TranslatePoint([Windows.Point]::new(0, $btn.ActualHeight), $shell)
    $menuCard.Margin = New-Object Windows.Thickness $pt.X, ($pt.Y + 8), 0, 0
    $menuLayer.Visibility = 'Visible'
    $menuLayer.UpdateLayout()
    Update-Frost $menuCard $heroCard
    Animate $menuCard ([Windows.UIElement]::OpacityProperty) 1 160
    Animate $menuCard.RenderTransform ([Windows.Media.ScaleTransform]::ScaleXProperty) 1 200
    Animate $menuCard.RenderTransform ([Windows.Media.ScaleTransform]::ScaleYProperty) 1 200
    foreach ($c in $profileList.Children) {
        if ($c.Tag.Name -eq $Active.Name) {
            $c.BringIntoView()
            [void]$c.Focus()
        }
    }
}

function Close-Menu {
    if ($menuLayer.Visibility -ne 'Visible') {
        return
    }
    Animate $menuCard ([Windows.UIElement]::OpacityProperty) 0 120
    Animate $menuCard.RenderTransform ([Windows.Media.ScaleTransform]::ScaleXProperty) 0.96 120
    Animate $menuCard.RenderTransform ([Windows.Media.ScaleTransform]::ScaleYProperty) 0.96 120
    [void](Find 'ProfileBtn').Focus()
    After 130 {
        if ($menuCard.Opacity -lt 0.05) {
            $menuLayer.Visibility = 'Collapsed'
        }
    }
}

function Set-NameError([string]$Text) {
    $err = Find 'NameError'
    $box = Find 'NameBox'
    if ($Text -eq '') {
        $err.Visibility = 'Collapsed'
        $box.Tag = $null
    }
    else {
        $err.Text = $Text
        $err.Visibility = 'Visible'
        $box.Tag = 'error'
    }
}

function Open-NameForm([string]$Mode) {
    $script:NameMode = $Mode
    $box = Find 'NameBox'
    if ($Mode -eq 'rename') {
        (Find 'NameTitle').Text = 'Rename profile'
        $box.Text = $Active.Name
    }
    else {
        (Find 'NameTitle').Text = 'New profile from the current curve'
        $box.Text = Get-FreeName 'My profile'
    }
    Set-NameError ''
    $menuList.Visibility = 'Collapsed'
    $nameForm.Visibility = 'Visible'
    [void]$box.Focus()
    $box.SelectAll()
}

function Save-Name {
    $box = Find 'NameBox'
    $name = $box.Text.Trim()
    $except = ''
    if ($NameMode -eq 'rename') {
        $except = $Active.Name
    }
    $problem = Get-NameProblem $name (Get-ProfileNames $except)
    if ($problem -ne '') {
        Set-NameError $problem
        [void]$box.Focus()
        return
    }
    if ($NameMode -eq 'rename') {
        if ($cfg.Default -eq $Active.Name) {
            $cfg.Default = $name
        }
        $Active.Name = $name
    } else {
        if ($cfg.Profiles.Count -ge $MaxProfiles) {
            Set-NameError ('You already have {0} profiles. Delete one to add a new one.' -f $MaxProfiles)
            return
        }
        $copy = New-ProfileObject $name $Active.Values $Active.Tone $false
        [void]$cfg.Profiles.Add($copy)
        $script:Active = $copy
    }
    Update-ProfileButton
    Request-Save
    Close-Menu
}

function Remove-ActiveProfile {
    if ($Active.Locked) {
        return
    }
    $gone = $Active
    $index = 0
    for ($i = 0; $i -lt $cfg.Profiles.Count; $i++) {
        if ($cfg.Profiles[$i].Name -eq $gone.Name) {
            $index = $i
        }
    }
    $wasDefault = ($cfg.Default -eq $gone.Name)
    $cfg.Profiles.RemoveAt($index)
    if ($wasDefault) {
        $cfg.Default = $FallbackProfile
    }
    $script:Undo = @{
        Profile = $gone
        Index = $index
        WasDefault = $wasDefault
    }
    Select-Profile (Find-Profile $cfg $cfg.Default)
    Show-Toast ('Profile "{0}" deleted.' -f $gone.Name) 'Text' 'Undo' { Restore-Profile }
}

function Restore-Profile {
    if ($null -eq $Undo) {
        return
    }
    $p = $Undo.Profile
    $p.Name = Get-FreeName $p.Name
    $cfg.Profiles.Insert([Math]::Min($Undo.Index, $cfg.Profiles.Count), $p)
    if ($Undo.WasDefault) {
        $cfg.Default = $p.Name
    }
    $script:Undo = $null
    Select-Profile $p
    Hide-Toast
}

(Find 'ProfileBtn').Add_Click({
    if ($menuLayer.Visibility -eq 'Visible') {
        Close-Menu
    } else {
        Open-Menu
    }
})
(Find 'MenuScrim').Add_MouseLeftButtonDown({ Close-Menu })
$menuCard.Add_SizeChanged({
    if ($menuLayer.Visibility -eq 'Visible') {
        Update-Frost $menuCard $heroCard
    }
})
(Find 'NameCancel').Add_Click({ Close-Menu })
(Find 'NameSave').Add_Click({ Save-Name })
(Find 'NameBox').Add_TextChanged({ Set-NameError '' })
(Find 'NameBox').Add_KeyDown({
    param($sender, $e)
    if ($e.Key -eq 'Return') {
        Save-Name
        $e.Handled = $true
    }
})
$menuLayer.Add_PreviewKeyDown({
    param($sender, $e)
    if ($e.Key -eq 'Escape') {
        Close-Menu
        $e.Handled = $true
    }
})

$Engine = $null
$State = @{
    Lux = [double]::NaN
    Applied = -1
    Target = -1
    Status = 'starting'
    Error = ''
    External = 0
}
$saveTimer = New-Object Windows.Threading.DispatcherTimer
$saveTimer.Interval = [TimeSpan]::FromMilliseconds(700)
$saveTimer.Add_Tick({
        $saveTimer.Stop()
        if ($RenderTo) {
            return
        }
        try {
            Save-Config $cfg
        } catch {
            Show-Toast "Could not save the settings: $($_.Exception.Message)"
        }
    })
function Request-Save {
    $saveTimer.Stop()
    $saveTimer.Start()
}

function Push-Values {
    if ($null -ne $Engine) {
        $Engine.Shared.Values = [int[]]$Values.Clone()
        $Engine.Shared.Version = $Engine.Shared.Version + 1
    }
    Request-Save
}

$toast = Find 'Toast'
$hint = Find 'HintText'
$ToastBlock = $null
$toastTimer = New-Object Windows.Threading.DispatcherTimer
$toastTimer.Interval = [TimeSpan]::FromSeconds(8)
$toastTimer.Add_Tick({
    $toastTimer.Stop()
    Hide-Toast
})
function Show-Toast([string]$Text, [string]$ColorKey = 'Orange', [string]$ActionText = '', [scriptblock]$Action = $null) {
    $txt = Find 'ToastText'
    $txt.Text = $Text
    Use $txt ([Windows.Controls.TextBlock]::ForegroundProperty) $ColorKey
    $act = Find 'ToastAction'
    $script:ToastBlock = $Action
    $toastTimer.Stop()
    if ($null -ne $Action) {
        $act.Content = $ActionText
        $act.Visibility = 'Visible'
        $toastTimer.Start()
    }
    else {
        $act.Visibility = 'Collapsed'
    }
    $toast.Visibility = 'Visible'
    Animate $hint ([Windows.UIElement]::OpacityProperty) 0 150
    Animate $toast ([Windows.UIElement]::OpacityProperty) 1 250
    Animate $toast.RenderTransform ([Windows.Media.ScaleTransform]::ScaleXProperty) 1 250
    Animate $toast.RenderTransform ([Windows.Media.ScaleTransform]::ScaleYProperty) 1 250
}
function Hide-Toast {
    $toastTimer.Stop()
    Animate $hint ([Windows.UIElement]::OpacityProperty) 1 200
    Animate $toast ([Windows.UIElement]::OpacityProperty) 0 200
    Animate $toast.RenderTransform ([Windows.Media.ScaleTransform]::ScaleXProperty) 0.96 200
    Animate $toast.RenderTransform ([Windows.Media.ScaleTransform]::ScaleYProperty) 0.96 200
    After 220 {
        if ($toast.Opacity -lt 0.05) {
            $toast.Visibility = 'Collapsed'
        }
    }
}
(Find 'ToastClose').Add_Click({ Hide-Toast })
(Find 'ToastAction').Add_Click({
    if ($null -ne $ToastBlock) {
        & $ToastBlock
    }
})

$History = @{ Lux = New-Object 'System.Collections.Generic.List[double]'; Br = New-Object 'System.Collections.Generic.List[double]' }
$HistoryMax = 180
function New-Chart($Canvas, [string[]]$Ticks) {
    $c = @{
        Canvas = $Canvas
        Lines = @()
        Labels = @()
    }
    foreach ($tk in $Ticks) {
        $ln = New-Object Windows.Shapes.Line
        Use $ln ([Windows.Shapes.Shape]::StrokeProperty) 'Line'
        $ln.StrokeThickness = 1
        $ln.SnapsToDevicePixels = $true
        [void]$Canvas.Children.Add($ln)
        $t = New-Object Windows.Controls.TextBlock
        $t.Style = $window.Resources['Small']
        $t.Text = $tk
        $t.Width = 32
        $t.TextAlignment = 'Right'
        [Windows.Documents.Typography]::SetNumeralAlignment($t, 'Tabular')
        [void]$Canvas.Children.Add($t)
        $c.Lines += $ln
        $c.Labels += $t
    }
    $p = New-Object Windows.Shapes.Polyline
    Use $p ([Windows.Shapes.Shape]::StrokeProperty) 'AccentLine'
    $p.StrokeThickness = 2
    $p.StrokeLineJoin = 'Round'
    $p.StrokeStartLineCap = 'Round'
    $p.StrokeEndLineCap = 'Round'
    [void]$Canvas.Children.Add($p)
    $c.Line = $p
    return $c
}
$luxChart = New-Chart (Find 'LuxChart') @('10000', '1000', '100', '10', '0')
$brChart = New-Chart (Find 'BrChart') @('100', '50', '0')

function Update-Chart($Chart, $Data, [string]$Scale) {
    $cv = $Chart.Canvas
    $w = $cv.ActualWidth
    $h = $cv.ActualHeight
    if ($w -le 40 -or $h -le 10) {
        return
    }
    $left = 36.0
    $top = 6.0
    $bottom = $h - 6
    $n = $Chart.Lines.Count
    for ($i = 0; $i -lt $n; $i++) {
        $y = [Math]::Round($top + ($bottom - $top) * $i / ($n - 1)) + 0.5
        $l = $Chart.Lines[$i]
        $l.X1 = $left
        $l.X2 = $w
        $l.Y1 = $y
        $l.Y2 = $y
        [Windows.Controls.Canvas]::SetTop($Chart.Labels[$i], $y - 9)
    }
    $pts = New-Object Windows.Media.PointCollection
    $count = $Data.Count
    for ($i = 0; $i -lt $count; $i++) {
        if ($Scale -eq 'lux') {
            $u = Convert-LuxToUnit $Data[$i]
        } else {
            $u = Convert-PercentToUnit $Data[$i]
        }
        $x = $w - ($count - 1 - $i) * ($w - $left) / ($HistoryMax - 1)
        $pts.Add((New-Object Windows.Point $x, ($bottom - $u * ($bottom - $top))))
    }
    $Chart.Line.Points = $pts
}
function Convert-LuxToUnit([double]$Lux) {
    $positive = [Math]::Max([double]0, $Lux)
    return [Math]::Min([double]1, [Math]::Log10($positive + 1) / 4)
}
function Convert-PercentToUnit([double]$Percent) {
    $unit = $Percent / 100
    return [Math]::Min([double]1, [Math]::Max([double]0, $unit))
}

$StatusCopy = @{
    'starting'   = @('Starting', 'Muted')
    'ok'         = @('Running', 'Muted')
    'paused'     = @('Paused', 'Text')
    'no-sensor'  = @('No ambient light sensor found', 'Red')
    'no-reading' = @('Light sensor returns no readings', 'Red')
    'no-display' = @('No display with brightness control', 'Orange')
    'error'      = @('Error, retrying shortly', 'Red')
}
$lastStatus = ''
$lastNear = ''
function Update-Live {
    $status = $State.Status
    if ($status -ne $lastStatus) {
        $script:lastStatus = $status
        $copy = $StatusCopy[$status]
        if ($null -eq $copy) {
            $copy = $StatusCopy['starting']
        }
        (Find 'StatusText').Text = $copy[0]
        Use (Find 'StatusText') ([Windows.Controls.TextBlock]::ForegroundProperty) $copy[1]
        $dim = 1.0
        if ($status -eq 'paused') {
            $dim = 0.45
            $liveDot.Fill = [Windows.Media.Brushes]::Transparent
            Use $liveDot ([Windows.Shapes.Shape]::StrokeProperty) 'AccentLine'
            $liveDot.StrokeThickness = 2
        } else {
            Use $liveDot ([Windows.Shapes.Shape]::FillProperty) 'AccentLine'
            Use $liveDot ([Windows.Shapes.Shape]::StrokeProperty) 'Knob'
            $liveDot.StrokeThickness = 2.5
        }
        Animate $curvePath ([Windows.UIElement]::OpacityProperty) $dim 200
        Animate $areaPath ([Windows.UIElement]::OpacityProperty) $dim 200
    }
    $tip = $null
    if ($status -eq 'error' -and $State.Error) {
        $tip = $State.Error
    }
    elseif ($status -ne 'ok' -and $status -ne 'paused' -and $status -ne 'starting' -and $null -ne $StatusCopy[$status]) {
        $tip = $StatusCopy[$status][0]
    }
    if ((Find 'StatusText').ToolTip -ne $tip) {
        (Find 'StatusText').ToolTip = $tip
    }
    $lux = $State.Lux
    $luxText = '-'
    $brText = '-'
    if (-not [double]::IsNaN($lux)) {
        $luxText = ([Math]::Round($lux)).ToString('0')
    }
    if ($State.Applied -ge 0) {
        $brText = [string]$State.Applied
    }
    (Find 'LuxValue').Text = $luxText
    (Find 'BarLux').Text = $luxText
    (Find 'BrValue').Text = $brText
    (Find 'BarBr').Text = $brText

    $h = $bandRow.ActualHeight
    if ([double]::IsNaN($lux) -or $State.Applied -lt 0 -or $h -le $Knob) {
        $liveDot.Visibility = 'Collapsed'
        $liveLine.Visibility = 'Collapsed'
        return
    }
    $pos = Get-BandPosition $lux
    $near = '{0}-{1}' -f [Math]::Floor($pos), [Math]::Ceiling($pos)
    if ($near -ne $lastNear) {
        $script:lastNear = $near
        for ($i = 0; $i -lt $LuxLabels.Length; $i++) {
            $key = 'Muted'
            if ($i -eq [Math]::Floor($pos) -or $i -eq [Math]::Ceiling($pos)) {
                $key = 'Text'
            }
            Use $LuxLabels[$i] ([Windows.Controls.TextBlock]::ForegroundProperty) $key
        }
    }
    $x = Get-ColumnX $pos
    $y = Get-PlotY $State.Applied $h
    $liveLine.X1 = $x
    $liveLine.X2 = $x
    $liveLine.Y1 = Get-PlotY 100 $h
    $liveLine.Y2 = Get-PlotY 0 $h
    if ($liveDot.Visibility -ne 'Visible') {
        [Windows.Controls.Canvas]::SetLeft($liveDot, $x - 7)
        [Windows.Controls.Canvas]::SetTop($liveDot, $y - 7)
        $liveDot.Visibility = 'Visible'
        $liveLine.Visibility = 'Visible'
    } else {
        Animate $liveDot ([Windows.Controls.Canvas]::LeftProperty) ($x - 7) 220
        Animate $liveDot ([Windows.Controls.Canvas]::TopProperty) ($y - 7) 220
    }
}

function Add-History {
    if (-not [double]::IsNaN($State.Lux) -and $State.Applied -ge 0) {
        $History.Lux.Add($State.Lux)
        $History.Br.Add($State.Applied)
        while ($History.Lux.Count -gt $HistoryMax) {
            $History.Lux.RemoveAt(0)
            $History.Br.RemoveAt(0)
        }
    }
    Show-Charts
}
function Show-Charts {
    if ($drawerLayer.Visibility -ne 'Visible') {
        return
    }
    Update-Chart $luxChart $History.Lux 'lux'
    Update-Chart $brChart $History.Br 'percent'
}
(Find 'LuxChart').Add_SizeChanged({ Show-Charts })

$drawerLayer = Find 'DrawerLayer'
$drawer = Find 'Drawer'
$drawerScrim = Find 'DrawerScrim'
function Open-Drawer {
    $drawerLayer.Visibility = 'Visible'
    $drawerLayer.UpdateLayout()
    Update-Frost $drawer $shell
    Animate $drawerScrim ([Windows.UIElement]::OpacityProperty) 1 220
    Animate $drawer.RenderTransform ([Windows.Media.TranslateTransform]::XProperty) 0 340
    Show-Charts
    [void](Find 'DrawerClose').Focus()
}
function Close-Drawer {
    if ($drawerLayer.Visibility -ne 'Visible') {
        return
    }
    Animate $drawerScrim ([Windows.UIElement]::OpacityProperty) 0 200
    Animate $drawer.RenderTransform ([Windows.Media.TranslateTransform]::XProperty) 400 240
    [void](Find 'DrawerBtn').Focus()
    After 250 {
        if ($drawer.RenderTransform.X -gt 390) {
            $drawerLayer.Visibility = 'Collapsed'
        }
    }
}
(Find 'DrawerBtn').Add_Click({
    if ($drawerLayer.Visibility -eq 'Visible' -and $drawer.RenderTransform.X -lt 200) {
        Close-Drawer
    } else {
        Open-Drawer
    }
})
(Find 'DrawerClose').Add_Click({ Close-Drawer })
$drawerScrim.Add_MouseLeftButtonDown({ Close-Drawer })
$drawer.Add_SizeChanged({
    if ($drawerLayer.Visibility -eq 'Visible') {
        Update-Frost $drawer $shell
    }
})

$SpeedNames = 'very slow', 'slow', 'medium', 'fast', 'very fast'
$speedSlider = Find 'SpeedSlider'
$speedSlider.Value = $cfg.Speed
(Find 'SpeedText').Text = $SpeedNames[$cfg.Speed - 1]
$speedSlider.Add_ValueChanged({
        $cfg.Speed = [int]$speedSlider.Value
        (Find 'SpeedText').Text = $SpeedNames[$cfg.Speed - 1]
        if ($null -ne $Engine) {
            $Engine.Shared.Speed = $cfg.Speed
        }
        Request-Save
    })

$powerBtn = Find 'PowerBtn'
$powerBtn.IsChecked = $cfg.Enabled
$onPower = {
    $cfg.Enabled = [bool]$powerBtn.IsChecked
    if ($null -ne $Engine) {
        $Engine.Shared.Enabled = $cfg.Enabled
        $Engine.Shared.Version = $Engine.Shared.Version + 1
    }
    Request-Save
}
$powerBtn.Add_Checked($onPower)
$powerBtn.Add_Unchecked($onPower)

(Find 'ThemeBtn').Add_Click({
        $next = 'dark'
        if ($Theme -eq 'dark') {
            $next = 'light'
        }
        Set-Theme $next $true
        $cfg.Theme = $next
        Request-Save
    })

$StartupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'Lumen.lnk'
function Test-Autostart {
    if (-not (Test-Path -LiteralPath $StartupLink)) {
        return $false
    }
    try {
        $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($StartupLink)
        return $lnk.Arguments.Contains('"' + $ScriptPath + '"')
    } catch {
        return $false
    }
}
$autostart = Find 'AutostartBox'
$autostart.IsChecked = (Test-Autostart)
$AutoBusy = $false
$onAutostart = {
    if ($AutoBusy) {
        return
    }
    try {
        if ($autostart.IsChecked) {
            $sh = New-Object -ComObject WScript.Shell
            $lnk = $sh.CreateShortcut($StartupLink)
            $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Hidden' -f $ScriptPath
            $lnk.WorkingDirectory = $Root
            $lnk.WindowStyle = 7
            $lnk.Description = 'Lumen'
            $lnk.Save()
        } elseif (Test-Path -LiteralPath $StartupLink) {
            Remove-Item -LiteralPath $StartupLink -Force
        }
    } catch {
        $script:AutoBusy = $true
        $autostart.IsChecked = (Test-Autostart)
        $script:AutoBusy = $false
        Show-Toast "Could not change the startup setting: $($_.Exception.Message)"
    }
}
$autostart.Add_Checked($onAutostart)
$autostart.Add_Unchecked($onAutostart)

(Find 'WinSettingsBtn').Add_Click({
        try {
            Start-Process 'ms-settings:display'
        } catch {
            Show-Toast 'Could not open the display settings.'
        }
    })
(Find 'MinBtn').Add_Click({ $window.WindowState = 'Minimized' })
(Find 'CloseBtn').Add_Click({ $window.Hide() })
$window.Add_PreviewKeyDown({
        param($sender, $e)
        if ($e.Key -eq 'Escape' -and $drawerLayer.Visibility -eq 'Visible') {
            Close-Drawer
            $e.Handled = $true
        }
        if ($e.Key -eq 'System' -and $e.SystemKey -eq 'F4') {
            $window.Hide()
            $e.Handled = $true
        }
    })

$rootGrid = Find 'RootGrid'
$bandRow.Add_SizeChanged({
    Update-Curve
    Update-Live
})

for ($i = 0; $i -lt $Values.Length; $i++) {
    Update-Band $i
}
Update-ProfileButton
Update-ToneReset
Set-Theme $Theme $false

if ($RenderTo) {
    $State.Lux = 158
    $State.Applied = 52
    $State.Target = 55
    $State.Status = 'ok'
    $rnd = New-Object Random 7
    for ($i = 0; $i -lt $HistoryMax; $i++) {
        $lx = 5.0
        if ($i -gt 60) {
            $lx = 150 + $rnd.Next(0, 16)
        }
        if ($i -gt 140) {
            $lx = 158
        }
        $History.Lux.Add($lx)
        $History.Br.Add([Math]::Round((Get-CurveValue $Values $lx)))
    }
    [void]$cfg.Profiles.Add((New-ProfileObject 'Evening lamp' ([int[]](26, 28, 36, 44, 50, 57, 66, 80, 86, 90)) ([int[]](0, 0, 0, 0)) $false))
    [void]$cfg.Profiles.Add((New-ProfileObject 'Daytime work' ([int[]](15, 18, 30, 45, 55, 66, 80, 96, 100, 100)) ([int[]](10, 20, 0, -15)) $false))
    $cfg.Default = 'Evening lamp'
    $root = $window.Content
    $size = New-Object Windows.Size 940, 680
    $root.Measure($size)
    $root.Arrange((New-Object Windows.Rect $size))
    $root.UpdateLayout()
    if ($RenderState -ne 'default') {
        Select-Profile $cfg.Profiles[3]
    }
    if ($RenderState -eq 'paused') {
        $State.Status = 'paused'
    }
    if ($RenderState -eq 'nosensor') {
        $State.Status = 'no-reading'
        $State.Lux = [double]::NaN
        $State.Applied = -1
    }
    Update-Curve
    Update-Live
    Add-History
    $root.UpdateLayout()
    if ($RenderState -eq 'menumany') {
        foreach ($n in 'Office', 'Cafe', 'Train', 'Balcony', 'Home cinema', 'Reading', 'Coding', 'Photos', 'Presentation') {
            [void]$cfg.Profiles.Add((New-ProfileObject $n $BuiltIn['Windows'] ([int[]](0, 0, 0, 0)) $false))
        }
    }
    if ($RenderState -eq 'menu' -or $RenderState -eq 'menumany' -or $RenderState -eq 'form') {
        Open-Menu
    }
    if ($RenderState -eq 'form') {
        Open-NameForm 'new'
        (Find 'NameBox').Text = 'Daytime work'
        Set-NameError 'A profile with this name already exists.'
    }
    for ($j = 0; $j -lt 4; $j++) {
        Update-ToneFill $j
    }
    if ($RenderState -eq 'drawer') {
        Open-Drawer
        $root.UpdateLayout()
        Show-Charts
    }
    if ($RenderState -eq 'toast') {
        Show-Toast 'Profile "Evening lamp" deleted.' 'Text' 'Undo' { }
    }
    $root.UpdateLayout()
    $bg = New-Object Windows.Media.DrawingVisual
    $dc = $bg.RenderOpen()
    $dc.DrawRectangle($window.Resources['WBase'], $null, (New-Object Windows.Rect $size))
    $dc.Close()
    $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap ([int](940 * $RenderScale)), ([int](680 * $RenderScale)), (96 * $RenderScale), (96 * $RenderScale), ([Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($bg)
    $rtb.Render($root)
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $fs = [IO.File]::Create($RenderTo)
    try {
        $enc.Save($fs)
    } finally {
        $fs.Close()
    }
    "saved $RenderTo"
    exit 0
}

$created = $false
$mutex = New-Object Threading.Mutex $true, 'Local\Lumen.Instance', ([ref]$created)
$showEvent = New-Object Threading.EventWaitHandle $false, 'AutoReset', 'Local\Lumen.Show'
$quitEvent = New-Object Threading.EventWaitHandle $false, 'AutoReset', 'Local\Lumen.Quit'
if (-not $created) {
    [void]$showEvent.Set()
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

function New-TrayIcon {
    $light = $false
    try {
        $v = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name SystemUsesLightTheme -ErrorAction Stop
        $light = ($v.SystemUsesLightTheme -eq 1)
    } catch { }
    $col = [Drawing.Color]::White
    if ($light) {
        $col = [Drawing.Color]::FromArgb(29, 29, 31)
    }
    $bmp = New-Object Drawing.Bitmap 32, 32
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $pen = New-Object Drawing.Pen $col, 3
    $pen.StartCap = 'Round'
    $pen.EndCap = 'Round'
    $brush = New-Object Drawing.SolidBrush $col
    $g.FillEllipse($brush, 10, 10, 12, 12)
    for ($a = 0; $a -lt 8; $a++) {
        $r = $a * [Math]::PI / 4
        $g.DrawLine($pen, [single](16 + 10 * [Math]::Cos($r)), [single](16 + 10 * [Math]::Sin($r)), [single](16 + 13.5 * [Math]::Cos($r)), [single](16 + 13.5 * [Math]::Sin($r)))
    }
    $g.Dispose()
    $pen.Dispose()
    $brush.Dispose()
    $icon = [Drawing.Icon]::FromHandle($bmp.GetHicon())
    return $icon
}

$tray = New-Object Windows.Forms.NotifyIcon
$tray.Icon = New-TrayIcon
$tray.Text = $AppName
$menu = New-Object Windows.Forms.ContextMenuStrip
$miOpen = $menu.Items.Add('Open Lumen')
$miProfiles = New-Object Windows.Forms.ToolStripMenuItem 'Profile'
[void]$menu.Items.Add($miProfiles)
$miPause = $menu.Items.Add('Pause')
[void]$menu.Items.Add('-')
$miQuit = $menu.Items.Add('Quit')
$tray.ContextMenuStrip = $menu
$tray.Visible = $true

$Notice = ''
if ($cfg.Problem -ne '') {
    try {
        Copy-Item -LiteralPath $ConfigPath -Destination $BackupPath -Force
    } catch { }
    if ($cfg.Problem -eq 'corrupt') {
        $Notice = 'The settings file was damaged, so the defaults were loaded. Old file: settings.backup.json.'
    }
    else {
        $Notice = 'Some profiles in the settings file were invalid and were skipped. Old file: settings.backup.json.'
    }
}

function Show-Window {
    $window.Show()
    if ($window.WindowState -eq 'Minimized') {
        $window.WindowState = 'Normal'
    }
    [void]$window.Activate()
    if ($Notice -ne '') {
        Show-Toast $Notice
        $script:Notice = ''
    }
}
$Stopped = $false
function Stop-All {
    if ($Stopped) {
        return
    }
    $script:Stopped = $true
    try {
        $saveTimer.Stop()
        Save-Config $cfg
    } catch { }
    try {
        $tray.Visible = $false
        $tray.Dispose()
    } catch { }
    if ($null -ne $Engine) {
        Stop-Engine $Engine
    }
    try {
        $mutex.ReleaseMutex()
    } catch { }
}
function Quit-App {
    $script:Quitting = $true
    Stop-All
    $app.Shutdown()
}
$Quitting = $false
$miOpen.Add_Click({ Show-Window })
$tray.Add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq 'Left') {
        Show-Window
    }
})
$miPause.Add_Click({ $powerBtn.IsChecked = -not $powerBtn.IsChecked })
$menu.Add_Opening({
        if ($powerBtn.IsChecked) {
            $miPause.Text = 'Pause'
        } else {
            $miPause.Text = 'Resume'
        }
        $miProfiles.DropDownItems.Clear()
        foreach ($p in $cfg.Profiles) {
            $it = New-Object Windows.Forms.ToolStripMenuItem $p.Name
            $it.Checked = ($p.Name -eq $Active.Name)
            $it.Tag = $p
            $it.Add_Click({
                param($sender, $e)
                Select-Profile $sender.Tag
            })
            [void]$miProfiles.DropDownItems.Add($it)
        }
    })
$miQuit.Add_Click({ Quit-App })
(Find 'QuitBtn').Add_Click({ Quit-App })

$window.Add_Closing({
        param($sender, $e)
        if (-not $Quitting) {
            $e.Cancel = $true
            $window.Hide()
        }
    })

$Engine = Start-Engine $Values $cfg.Speed $cfg.Enabled $false

$externalSeen = 0
$externalTimes = New-Object 'System.Collections.Generic.List[datetime]'
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(200)
$timer.Add_Tick({
        $s = $Engine.Shared
        $State.Lux = $s.Lux
        $State.Applied = $s.Applied
        $State.Target = $s.Target
        $State.Status = $s.Status
        $State.Error = $s.Error
        if ($quitEvent.WaitOne(0)) {
            Quit-App
            return
        }
        if ($showEvent.WaitOne(0)) {
            Show-Window
        }

        if ($s.External -ne $externalSeen) {
            $script:externalSeen = $s.External
            $externalTimes.Add([datetime]::Now)
            while ($externalTimes.Count -gt 0 -and ([datetime]::Now - $externalTimes[0]).TotalSeconds -gt 60) {
                $externalTimes.RemoveAt(0)
            }
            if ($externalTimes.Count -ge 3 -and $window.IsVisible) {
                $externalTimes.Clear()
                Show-Toast 'Something else is changing the screen brightness. Turn off automatic brightness in Windows display settings.'
            }
        }
        if ($window.IsVisible) {
            Update-Live
        }
    })
$timer.Start()

$histTimer = New-Object Windows.Threading.DispatcherTimer
$histTimer.Interval = [TimeSpan]::FromSeconds(1)
$histTimer.Add_Tick({ Add-History })
$histTimer.Start()

$app = New-Object Windows.Application
$app.ShutdownMode = 'OnExplicitShutdown'
$app.Add_DispatcherUnhandledException({
        param($sender, $e)
        $e.Handled = $true
        try {
            Show-Toast ('Something went wrong: {0}' -f $e.Exception.Message)
        } catch { }
    })

$area = [Windows.SystemParameters]::WorkArea
$fit = Get-FitScale $window.Width $window.Height $area.Width $area.Height
if ($fit -lt 1) {
    $rootGrid.LayoutTransform = New-Object Windows.Media.ScaleTransform $fit, $fit
    $window.Width = $window.Width * $fit
    $window.Height = $window.Height * $fit
}
if ($Motion) {
    $shell.Opacity = 0
    $shell.RenderTransform.ScaleX = 0.985
    $shell.RenderTransform.ScaleY = 0.985
    $window.Add_ContentRendered({
            Animate $shell ([Windows.UIElement]::OpacityProperty) 1 260
            Animate $shell.RenderTransform ([Windows.Media.ScaleTransform]::ScaleXProperty) 1 300
            Animate $shell.RenderTransform ([Windows.Media.ScaleTransform]::ScaleYProperty) 1 300
        })
}
if (-not $Hidden) {
    Show-Window
}
try {
    [void]$app.Run()
} finally {
    Stop-All
}
