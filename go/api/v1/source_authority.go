// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package v1

import (
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"errors"
	"math"
	"strings"
)

// SourceIdentity commits actual certificate/key/role-credential bytes. It is not
// a caller-supplied subject, a Kubernetes identity, or a process incarnation.
type SourceIdentity struct {
	CertificateSHA256 string `json:"certificate_sha256"`
	PublicKeySHA256   string `json:"public_key_sha256"`
	CredentialSHA256  string `json:"credential_sha256"`
}

func digestText(value string) bool {
	decoded, err := hex.DecodeString(value)
	return err == nil && len(decoded) == 32 && value == strings.ToLower(value) && value != strings.Repeat("0", 64)
}
func domainDigest(domain string, value json.RawMessage) (string, error) {
	scope, err := json.Marshal(domain)
	if err != nil {
		return "", err
	}
	data, err := json.Marshal([2]json.RawMessage{scope, value})
	if err != nil {
		return "", err
	}
	hash := sha256.Sum256(data)
	return hex.EncodeToString(hash[:]), nil
}
func (i SourceIdentity) Digest() (string, error) {
	if !digestText(i.CertificateSHA256) || !digestText(i.PublicKeySHA256) || !digestText(i.CredentialSHA256) {
		return "", errors.New("source identity digest")
	}
	encoded, err := json.Marshal(i)
	if err != nil {
		return "", err
	}
	return domainDigest("weaver.source-identity.v1", encoded)
}

type SourceRotation struct {
	OperationID          string
	ExpectedEpoch        uint64
	NextCertificate      []byte
	NextCredentialSHA256 string
}

func (r SourceRotation) Identity() (SourceIdentity, error) {
	if len(r.NextCertificate) == 0 || len(r.NextCertificate) > 16384 || !digestText(r.NextCredentialSHA256) {
		return SourceIdentity{}, errors.New("source certificate/credential bounds")
	}
	cert, err := x509.ParseCertificate(r.NextCertificate)
	if err != nil {
		return SourceIdentity{}, err
	}
	leaf, key := sha256.Sum256(r.NextCertificate), sha256.Sum256(cert.RawSubjectPublicKeyInfo)
	return SourceIdentity{hex.EncodeToString(leaf[:]), hex.EncodeToString(key[:]), r.NextCredentialSHA256}, nil
}
func (r SourceRotation) Digest() (string, error) {
	if len(r.OperationID) == 0 || len(r.OperationID) > 128 || r.ExpectedEpoch > math.MaxInt64 {
		return "", errors.New("source rotation bounds")
	}
	for _, c := range []byte(r.OperationID) {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.ContainsRune("._:-", rune(c))) {
			return "", errors.New("source rotation identity")
		}
	}
	identity, err := r.Identity()
	if err != nil {
		return "", err
	}
	command := struct {
		OperationID   string         `json:"operation_id"`
		ExpectedEpoch uint64         `json:"expected_epoch"`
		Next          SourceIdentity `json:"next"`
	}{r.OperationID, r.ExpectedEpoch, identity}
	encoded, err := json.Marshal(command)
	if err != nil {
		return "", err
	}
	return domainDigest("weaver.source-rotation.v1", encoded)
}
