package gatewayclient

import (
	"testing"

	"github.com/apache/arrow-go/v18/arrow/memory"
)

// Framework-generated command traces compare admission with an independent
// integer model. Free cannot launder allowance, and rejection cannot allocate.
func FuzzArrowAllocationBudget(f *testing.F) {
	f.Add([]byte{0, 64, 1, 32, 2, 0, 0, 1})
	f.Add([]byte{0, 255, 2, 0, 0, 255, 0, 2})
	f.Fuzz(func(t *testing.T, commands []byte) {
		if len(commands) > 128 {
			commands = commands[:128]
		}
		checked := memory.NewCheckedAllocator(memory.NewGoAllocator())
		a := &arrowAllocator{base: checked, limit: 256}
		var buffer []byte
		defer func() { a.Free(buffer); checked.AssertSize(t, 0) }()
		model := 0
		for i := 0; i+1 < len(commands); i += 2 {
			action, size := commands[i]%3, int(commands[i+1])
			if action == 2 {
				a.Free(buffer)
				buffer = nil
				if a.used != model {
					t.Fatal("free restored allowance")
				}
				continue
			}
			before := checked.CurrentAlloc()
			accepted := model+size <= 256
			var denied bool
			func() {
				defer func() {
					if failure := recover(); failure != nil {
						if _, ok := failure.(arrowAllocationLimit); !ok {
							panic(failure)
						}
						denied = true
					}
				}()
				if action == 0 {
					next := a.Allocate(size)
					a.Free(buffer)
					buffer = next
				} else {
					buffer = a.Reallocate(size, buffer)
				}
			}()
			if denied == accepted {
				t.Fatal("allocator disagrees with independent model")
			}
			if accepted {
				model += size
			} else if checked.CurrentAlloc() != before {
				t.Fatal("rejected command allocated memory")
			}
			if a.used != model || a.used > 256 {
				t.Fatal("cumulative allocation bound")
			}
		}
	})
}
