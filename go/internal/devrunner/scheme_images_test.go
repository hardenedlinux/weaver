package devrunner

import (
	"testing"
)

func TestModuleRegistryRejectsAmbiguousAndEscapingIdentities(t *testing.T) {
	for _, body := range []string{"", "../escape\t/tmp/escape.o1", "/absolute\t/tmp/a.o1", "a//b\t/tmp/a.o1", "a\trelative.o1", "a\t/tmp/a.o1\na\t/tmp/other.o1", "a\t/tmp/a.o1\textra"} {
		if _, err := readModuleRegistry([]byte(body)); err == nil {
			t.Errorf("accepted malformed registry %q", body)
		}
	}
	modules, err := readModuleRegistry([]byte("core/runtime~0\t/tmp/runtime~0.o1\n"))
	if err != nil || modules["core/runtime~0"] != "/tmp/runtime~0.o1" {
		t.Fatal("valid phase identity rejected", err)
	}
}

func TestDynamicImagesRetainForeignAndMacroPreludeOwners(t *testing.T) {
	for _, source := range []string{`(c-declare "#include <weaver_policy.h>")`, `(c-lambda (int) int "function")`, `(macro-thread-end-condvar thread)`, `"macro-absent-obj"`} {
		if imageExclusion([]byte(source)) == "" {
			t.Errorf("lost compiler-option boundary for %s", source)
		}
	}
	if imageExclusion([]byte(`(define (identity value) value)`)) != "" {
		t.Fatal("pure generated module excluded")
	}
}
