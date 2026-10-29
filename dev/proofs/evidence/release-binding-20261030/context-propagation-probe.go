package main

import (
    "context"
    "fmt"
    "time"
)

// Isolated source-path probe: Go's coordinator filters ctx.Err() by equality
// with its derived fuzzCtx.Err(). It is not a replay of a fuzz failure.
func main() {
    const trials = 10000
    parentBeforeChild := 0
    all := time.Now()
    for i := 0; i < trials; i++ {
        parent, stop := context.WithTimeout(context.Background(), time.Microsecond)
        child, release := context.WithCancel(parent)
        <-parent.Done()
        if parent.Err() == context.DeadlineExceeded && child.Err() == nil {
            parentBeforeChild++
        }
        <-child.Done()
        release()
        stop()
    }
    fmt.Printf("trials=%d parent_deadline_before_child_error=%d elapsed=%s\n", trials, parentBeforeChild, time.Since(all))
}
