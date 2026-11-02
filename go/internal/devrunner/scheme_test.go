package devrunner

import (
	"context"
	"encoding/json"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"testing/quick"
)

func schemeMetadataFixture(t testing.TB, source string) {
	t.Helper()
	for _, name := range []string{"init.ss", "build.ss", "gerbil.pkg"} {
		if err := os.WriteFile(filepath.Join(source, name), []byte("original metadata\n"), 0600); err != nil {
			t.Fatal(err)
		}
	}
}

func schemeGitFixture(t testing.TB, directory string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", directory, "-c", "user.name=Weaver Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=" + t.TempDir()}, args...)...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v %s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

func TestPooRevisionFollowsInheritedCoreDeclaration(t *testing.T) {
	directory := t.TempDir()
	file := filepath.Join(directory, "gerbil.pkg")
	wanted := strings.Repeat("a", 40)
	for _, data := range []string{`(depend: ("github.com/tao3k/gerbil-poo@` + wanted + `"))`, `(depend: ())`, `(depend: ("github.com/tao3k/gerbil-poo@` + wanted + `" "github.com/tao3k/gerbil-poo@` + strings.Repeat("b", 40) + `"))`} {
		if err := os.WriteFile(file, []byte(data), 0600); err != nil {
			t.Fatal(err)
		}
		actual, err := DeclaredPooRevision(directory)
		if strings.Count(data, "gerbil-poo@") == 1 {
			if err != nil || actual != wanted {
				t.Fatal("inherited exact revision lost")
			}
		} else if err == nil {
			t.Fatal("missing or ambiguous inherited revision admitted")
		}
	}
}

func TestLinkedSchemeCurrentnessRejectsSourceChange(t *testing.T) {
	source := t.TempDir()
	poo := t.TempDir()
	schemeMetadataFixture(t, source)
	for _, name := range []string{"core", "modules"} {
		if err := os.Mkdir(filepath.Join(source, name), 0700); err != nil {
			t.Fatal(err)
		}
	}
	file := filepath.Join(source, "modules", "governor.ss")
	if err := os.WriteFile(file, []byte("(export native-governor)"), 0600); err != nil {
		t.Fatal(err)
	}
	heads := map[string]string{}
	for directory, name := range map[string]string{source: "agentic-ai-lab", filepath.Join(source, "core"): "gebril-yuanxu", poo: "gerbil-poo"} {
		schemeGitFixture(t, directory, "init", "-q")
		schemeGitFixture(t, directory, "commit", "--allow-empty", "-qm", "original source")
		heads[name] = schemeGitFixture(t, directory, "rev-parse", "HEAD")
	}
	hashes, err := schemeSourceHashes(source, poo)
	if err != nil {
		t.Fatal(err)
	}
	receipt := filepath.Join(t.TempDir(), "environment.json")
	data, _ := json.Marshal(schemeLinkReceipt{SourceRoot: source, SourceHashes: hashes, SourceHeads: heads, PooSource: poo})
	if err = os.WriteFile(receipt, data, 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("WEAVER_SCHEME_LINK_RECEIPT", "untrusted-global-receipt")
	settings := map[string]string{"WEAVER_SCHEME_LINK_RECEIPT": receipt, "WEAVER_SCHEME_AGENTIC_SOURCE": source, "WEAVER_SCHEME_POO_SOURCE": poo}
	digest, err := schemeSourceDigest(hashes)
	if err != nil {
		t.Fatal(err)
	}
	original := Receipt{LinkedSourceHeads: maps.Clone(heads), LinkedSourceSHA256: digest}
	if result := schemeSourceCurrentness(context.Background(), t.TempDir(), "before", settings, original); result.Status != "PASS" {
		t.Fatal(result)
	}
	if err = os.WriteFile(file, []byte("(export changed-governor)"), 0600); err != nil {
		t.Fatal(err)
	}
	if result := schemeSourceCurrentness(context.Background(), t.TempDir(), "after", settings, original); result.Status != "FAIL" || !strings.Contains(result.Error, "modules/governor.ss") {
		t.Fatal("changed linked source accepted")
	}
	forgedHashes, err := schemeSourceHashes(source, poo)
	if err != nil {
		t.Fatal(err)
	}
	forged, err := json.Marshal(schemeLinkReceipt{SourceRoot: source, PooSource: poo, SourceHeads: heads, SourceHashes: forgedHashes})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(receipt, forged, 0600); err != nil {
		t.Fatal(err)
	}
	if result := schemeSourceCurrentness(context.Background(), t.TempDir(), "forged-receipt", settings, original); result.Status != "FAIL" || !strings.Contains(result.Error, "independently retained") {
		t.Fatal("coordinated source/receipt rewrite replaced the original cut")
	}
	if err := os.WriteFile(receipt, data, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(file, []byte("(export native-governor)"), 0600); err != nil {
		t.Fatal(err)
	}
	schemeGitFixture(t, filepath.Join(source, "core"), "commit", "--allow-empty", "-qm", "same bytes new source identity")
	if result := schemeSourceCurrentness(context.Background(), t.TempDir(), "changed-head", settings, original); result.Status != "FAIL" || !strings.Contains(result.Error, "source revision changed") {
		t.Fatal("source identity replacement with identical bytes accepted")
	}
}

func TestLinkedSchemeAliasesIncludePooRoot(t *testing.T) {
	source, poo, links := t.TempDir(), t.TempDir(), t.TempDir()
	schemeMetadataFixture(t, source)
	for _, name := range []string{"modules", "core"} {
		if err := os.Mkdir(filepath.Join(source, name), 0700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(poo, "object.ss"), []byte("(export object)"), 0600); err != nil {
		t.Fatal(err)
	}
	for name, target := range map[string]string{"source": source, "poo": poo} {
		if err := os.Symlink(target, filepath.Join(links, name)); err != nil {
			t.Fatal(err)
		}
	}
	direct, err := schemeSourceHashes(source, poo)
	if err != nil {
		t.Fatal(err)
	}
	aliased, err := schemeSourceHashes(filepath.Join(links, "source"), filepath.Join(links, "poo"))
	if err != nil || !maps.Equal(direct, aliased) || aliased["gerbil-poo/object.ss"] == "" {
		t.Fatalf("symlink omitted inherited POO source: %v %v", aliased, err)
	}
}

func TestPropertySchemeMetadataAndPolicyAssetsCannotChangeUnderReceipt(t *testing.T) {
	paths := []string{"init.ss", "build.ss", "gerbil.pkg", ".gitmodules", "core/gerbil.pkg",
		"modules/policy.cedar", "modules/schema.cedarschema", "modules/schema.json", "modules/config.yaml", "modules/config.yml"}
	property := func(index uint8, content string) bool {
		source := t.TempDir()
		schemeMetadataFixture(t, source)
		for _, name := range []string{"core", "modules"} {
			if err := os.Mkdir(filepath.Join(source, name), 0700); err != nil {
				t.Fatal(err)
			}
		}
		path := filepath.Join(source, paths[int(index)%len(paths)])
		if err := os.WriteFile(path, []byte("before"), 0600); err != nil {
			t.Fatal(err)
		}
		before, err := schemeSourceHashes(source, "")
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("after:"+content), 0600); err != nil {
			t.Fatal(err)
		}
		after, err := schemeSourceHashes(source, "")
		return err == nil && !maps.Equal(before, after)
	}
	if err := quick.Check(property, &quick.Config{MaxCount: 200}); err != nil {
		t.Fatal(err)
	}
}

func TestSchemeNestedAliasesAndMissingMetadataCannotEscapeCapture(t *testing.T) {
	for _, name := range []string{"init.ss", "modules/alias.ss", "modules/alias-directory", "core/alias.ss"} {
		t.Run(name, func(t *testing.T) {
			source := t.TempDir()
			schemeMetadataFixture(t, source)
			for _, directory := range []string{"core", "modules"} {
				if err := os.Mkdir(filepath.Join(source, directory), 0700); err != nil {
					t.Fatal(err)
				}
			}
			target := filepath.Join(t.TempDir(), "outside.ss")
			if err := os.WriteFile(target, []byte("outside closure"), 0600); err != nil {
				t.Fatal(err)
			}
			alias := filepath.Join(source, name)
			if name == "init.ss" {
				if err := os.Remove(alias); err != nil {
					t.Fatal(err)
				}
			}
			if strings.HasSuffix(name, "directory") {
				target = filepath.Dir(target)
			}
			if err := os.Symlink(target, alias); err != nil {
				t.Fatal(err)
			}
			if _, err := schemeSourceHashes(source, ""); err == nil {
				t.Fatal("nested source alias accepted")
			}
			if err := os.Remove(alias); err != nil {
				t.Fatal(err)
			}
			if err := os.Remove(filepath.Join(source, "gerbil.pkg")); err != nil {
				t.Fatal(err)
			}
			if _, err := schemeSourceHashes(source, ""); err == nil {
				t.Fatal("missing package declaration accepted")
			}
		})
	}
}

func TestSchemePreparationFailureIsRetainedWithoutStartingTests(t *testing.T) {
	root, _ := verificationInputsFixture(t)
	t.Setenv("WEAVER_CONTROL_SCHEME_COMPILER", "")
	t.Setenv("WEAVER_SCHEME_LINK_RECEIPT", "untrusted-global-receipt")
	var output strings.Builder
	path, err := Run(context.Background(), Config{Root: root, Mode: "check-scheme", GoBinary: filepath.Join(root, "must-not-start")}, &output)
	if err == nil {
		t.Fatal("preparation failure accepted")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var receipt Receipt
	if err := json.Unmarshal(data, &receipt); err != nil {
		t.Fatal(err)
	}
	if receipt.Status != "FAIL" || len(receipt.Stages) != 1 || receipt.Stages[0].Name != "scheme-preparation" ||
		receipt.Stages[0].OutputSHA256 == "" || receipt.Stages[0].Log != "" ||
		!strings.Contains(receipt.Stages[0].FailureTail, "explicit Scheme compiler") || len(receipt.Inputs) == 0 {
		t.Fatalf("preparation failure was hidden or tests started: %+v", receipt)
	}
}

func TestInstalledSchemeHeadsRejectMixedCore(t *testing.T) {
	prefix := t.TempDir()
	heads := map[string]string{}
	git := func(directory string, args ...string) string {
		return schemeGitFixture(t, directory, args...)
	}
	for _, name := range []string{"gebril-yuanxu", "gerbil-poo"} {
		directory := filepath.Join(prefix, "pkg", "github.com", "tao3k", name)
		if err := os.MkdirAll(directory, 0700); err != nil {
			t.Fatal(err)
		}
		git(directory, "init", "-q")
		git(directory, "commit", "--allow-empty", "-qm", "original source")
		heads[name] = git(directory, "rev-parse", "HEAD")
	}
	if err := checkInstalledSchemeHeads(context.Background(), prefix, heads); err != nil {
		t.Fatal(err)
	}
	core := filepath.Join(prefix, "pkg", "github.com", "tao3k", "gebril-yuanxu")
	git(core, "commit", "--allow-empty", "-qm", "transitive replacement")
	if err := checkInstalledSchemeHeads(context.Background(), prefix, heads); err == nil || !strings.Contains(err.Error(), "gebril-yuanxu") {
		t.Fatalf("mixed installed/source cohort accepted: %v", err)
	}
}

func TestSingleGoModuleRootNeedsNoWorkspace(t *testing.T) {
	root := t.TempDir()
	module := filepath.Join(root, "go")
	if err := os.MkdirAll(filepath.Join(module, "cmd"), 0700); err != nil {
		t.Fatal(err)
	}
	for path, data := range map[string]string{"Cargo.toml": "[workspace]\n", "go/go.mod": "module example.test/control\n"} {
		if err := os.WriteFile(filepath.Join(root, path), []byte(data), 0600); err != nil {
			t.Fatal(err)
		}
	}
	actual, err := FindRoot(filepath.Join(module, "cmd"))
	if err != nil || actual != root {
		t.Fatalf("single-module project root: %q %v", actual, err)
	}
}
