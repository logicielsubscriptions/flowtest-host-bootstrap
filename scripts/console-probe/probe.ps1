<#
    console-probe - does a Windows container deliver console control events to
    its entrypoint process?

    The order execution server dies about 45 seconds after launch if it does not
    own its console: its log shows "Signal Handler Activated: SIGINT" then
    "shutting down Order/Execution Server daemon". On the HOST that is explained
    - the parent console goes away and the child is signalled.

    In a container the engine is the entrypoint process with no interactive
    console at all. That question does not need the engine to answer it: it
    needs ANY process that registers the same handler and reports what arrives.

    ANSWERED 2026-08-31 on the flow-test host: this probe registered its handler
    successfully ("handler registered: True") and received NOTHING in 120s, in
    all four container shapes. The runtime does not send console control events
    unprompted.

    Three outcomes, all informative:

      survives, no events    the runtime sends nothing unprompted. The OE's death
                             was the HOST parent console, which a container does
                             not have - the engine should be fine.
      event at ~45s          the constraint reproduces in a container. Now we
                             know before an engine image exists.
      dies, no event         something else kills it, and console handling was
                             never the problem.
#>

$ErrorActionPreference = 'Stop'
$seconds = if ($env:PROBE_SECONDS) { [int]$env:PROBE_SECONDS } else { 300 }

Write-Host "console-probe starting; will run for $seconds seconds"

# The handler lives entirely in C#, and that is deliberate.
#
# Windows invokes a console control handler on a NEW OS THREAD that it creates
# for the purpose. Calling back into a PowerShell scriptblock from an arbitrary
# native thread is unreliable - it can deadlock or throw, and either would look
# like the process dying from the console event we are trying to observe. That
# would be the worst possible failure: a false positive on the exact question
# being asked.
#
# C# has no such problem. Console.WriteLine is thread-safe, and the handler
# records what happened in a static field the PowerShell loop can read.
#
# It returns false - "not handled" - so the default action still occurs. We are
# here to OBSERVE the behaviour, not suppress it; suppressing would tell us an
# event arrived but not whether it is fatal.
# NO -UsingNamespace HERE. Add-Type -MemberDefinition already emits `using
# System;` around the generated class, so passing -UsingNamespace System made it
# a duplicate and the compile failed with
#     error CS0105: The using directive for 'System' appeared previously
# Add-Type surfaces that as a terminating error, so the probe died inside
# Add-Type before registering anything. Every variant then exited 1 in ~12s with
# no console event - which reads exactly like "something else is killing it",
# the one outcome that sends you looking in the wrong place. The member
# definition below is fully qualified (System.DateTime, System.Console), so the
# parameter bought nothing even when it worked.
Add-Type -Namespace FlowTest -Name ConsoleProbe -MemberDefinition @'
    public delegate bool Handler(uint ctrlType);

    [System.Runtime.InteropServices.DllImport("Kernel32", SetLastError = true)]
    private static extern bool SetConsoleCtrlHandler(Handler handler, bool add);

    // Held in a static so the garbage collector cannot free the delegate while
    // Windows still holds a pointer to it. Without this the process crashes at
    // the moment of the event, for a reason that looks nothing like the thing
    // being tested.
    private static Handler _kept;
    private static System.DateTime _started;

    public static string LastEvent = "";

    public static bool Install() {
        _started = System.DateTime.UtcNow;
        _kept = new Handler(OnCtrl);
        return SetConsoleCtrlHandler(_kept, true);
    }

    private static bool OnCtrl(uint ctrlType) {
        string name;
        switch (ctrlType) {
            case 0: name = "CTRL_C_EVENT"; break;
            case 1: name = "CTRL_BREAK_EVENT"; break;
            case 2: name = "CTRL_CLOSE_EVENT"; break;
            case 5: name = "CTRL_LOGOFF_EVENT"; break;
            case 6: name = "CTRL_SHUTDOWN_EVENT"; break;
            default: name = "UNKNOWN_" + ctrlType; break;
        }
        int elapsed = (int)(System.DateTime.UtcNow - _started).TotalSeconds;
        LastEvent = name;
        System.Console.WriteLine("CONSOLE_EVENT " + name + " at " + elapsed + "s");
        System.Console.Out.Flush();
        return false;
    }
'@

$registered = [FlowTest.ConsoleProbe]::Install()
Write-Host "handler registered: $registered"
if (-not $registered) {
    # A finding in its own right: no console means no handler, which would tell
    # us the engine's own handler never installs either.
    Write-Host 'NOTE: SetConsoleCtrlHandler returned false - this process has no console.'
}

$started = Get-Date
$elapsed = 0
while ($elapsed -lt $seconds) {
    Start-Sleep -Seconds 5
    $elapsed = [int]((Get-Date) - $started).TotalSeconds
    Write-Host "alive ${elapsed}s"
}

Write-Host "SURVIVED $seconds seconds; last console event: '$([FlowTest.ConsoleProbe]::LastEvent)'"
