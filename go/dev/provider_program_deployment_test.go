//go:build integration && schemeintegration && !windows

package dev

import (
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/config"
)

type configuredAuthority struct {
	Epoch    uint64            `json:"epoch"`
	Identity v1.SourceIdentity `json:"identity"`
}
type configuredProducer struct {
	Name      string              `json:"name"`
	Authority configuredAuthority `json:"authority"`
	Original  config.Bundle       `json:"original"`
}
type configuredCatalog struct {
	Producers []configuredProducer `json:"producers"`
}

func configuredCatalogPath(t testing.TB, f *fixture, bundle config.Bundle) string {
	t.Helper()
	// These values bind eligibility; actual mTLS/credential authentication
	// and the ledger's source floor remain mandatory at each source RPC.
	cert, err := x509.ParseCertificate(f.pki.source.Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	leaf, key, credential := sha256.Sum256(cert.Raw), sha256.Sum256(cert.RawSubjectPublicKeyInfo), sha256.Sum256([]byte(adminToken))
	identity := v1.SourceIdentity{CertificateSHA256: hex.EncodeToString(leaf[:]), PublicKeySHA256: hex.EncodeToString(key[:]), CredentialSHA256: hex.EncodeToString(credential[:])}
	data, err := json.Marshal(configuredCatalog{Producers: []configuredProducer{{Name: "approved-control", Authority: configuredAuthority{Identity: identity}, Original: bundle}}})
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(f.directory, "approved-catalog.json")
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestProviderControlCompiledProgramRevocationAndRestart(t *testing.T) {
	exerciseControlPolicies(t, "json", nil, controlPolicySources{producer: "approved-control", configure: func(t *testing.T, f *fixture, bundle config.Bundle) {
		path := configuredCatalogPath(t, f, bundle)
		f.stop(t)
		f.env = append(f.env, "WEAVER_GOVERNANCE_CATALOG="+path)
		f.start(t)
	}})
}

func TestProviderControlCompiledProgramRequiresRealInstallation(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	path := configuredCatalogPath(t, f, controlBundle(t, f))
	f.stop(t)
	// The application is linked and initialized, but deliberately does not
	// register its producer. No mock readiness response or forced exit is used.
	cmd := exec.Command(serverBinary)
	cmd.Env = append(append(os.Environ(), f.env...), "WEAVER_GOVERNANCE_CATALOG="+path, "WEAVER_TEST_SKIP_PROGRAM_INSTALL=1")
	started := time.Now()
	output, err := cmd.CombinedOutput()
	if err == nil || time.Since(started) > 3*time.Second {
		t.Fatalf("missing installation did not refuse naturally within startup gate: %v %s", err, output)
	}
	if !strings.Contains(string(output), "governance initialization failed") || strings.Contains(string(output), "stage=listeners-bound") {
		t.Fatalf("uninstalled application reached serving or failed elsewhere: %s", output)
	}
	if f.primary.Load() != 0 || f.backup.Load() != 0 {
		t.Fatal("initialization refusal sent provider traffic")
	}
}
