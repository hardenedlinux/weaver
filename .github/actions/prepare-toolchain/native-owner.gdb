# Failure-only observation. Pass every signal through to the unchanged process.
set pagination off
set confirm off
set debuginfod enabled off
set print frame-arguments none
set follow-fork-mode parent
handle all nostop noprint pass
handle SIGPIPE stop print pass
set $weaver_sigpipe_events = 0
catch signal SIGPIPE
commands
  silent
  set $weaver_sigpipe_events = $weaver_sigpipe_events + 1
  if $weaver_sigpipe_events <= 16
    printf "WEAVER-NATIVE-SIGPIPE event=%d\n", $weaver_sigpipe_events
    thread
    bt 24
    if $weaver_sigpipe_events == 1
      thread apply all bt 24
    end
  end
  continue
end
run
