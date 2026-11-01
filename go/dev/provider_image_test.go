//go:build integration && !windows

package dev

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"math/rand"
	"os"
	"path/filepath"
	"testing"
	"testing/quick"
)

// Transfer the built artifact to test-owned read-only custody. This function
// never executes the image, changes its bytes or warms a server. The same
// startup/cleanup deadlines apply to the first actual launch.
func publishProviderImage(sourcePath, targetPath string) (digest string, result error) {
	entry, err := os.Lstat(sourcePath)
	if err != nil {
		return "", err
	}
	if !entry.Mode().IsRegular() || entry.Mode().Perm()&0111 == 0 {
		return "", errors.New("provider build image is not a regular executable")
	}
	source, err := os.Open(sourcePath)
	if err != nil {
		return "", err
	}
	defer func() { result = errors.Join(result, source.Close()) }()
	before, err := source.Stat()
	if err != nil {
		return "", err
	}
	if !os.SameFile(entry, before) {
		return "", errors.New("provider build image changed before capture")
	}
	target, err := os.OpenFile(targetPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return "", err
	}
	defer func() {
		if result != nil {
			_ = os.Remove(targetPath)
		}
	}()
	hash := sha256.New()
	n, copyError := io.Copy(io.MultiWriter(target, hash), source)
	modeError := target.Chmod(0500)
	syncError, closeError := target.Sync(), target.Close()
	if err = errors.Join(copyError, modeError, syncError, closeError); err != nil {
		return "", err
	}
	after, err := os.Stat(sourcePath)
	if err != nil {
		return "", err
	}
	if !os.SameFile(before, after) || before.Size() != after.Size() || n != before.Size() || !before.ModTime().Equal(after.ModTime()) {
		return "", errors.New("provider build image changed during capture")
	}
	image, err := os.Open(targetPath)
	if err != nil {
		return "", err
	}
	verified := sha256.New()
	_, readError := io.Copy(verified, image)
	if err = errors.Join(readError, image.Close()); err != nil {
		return "", err
	}
	digest = hex.EncodeToString(hash.Sum(nil))
	if hex.EncodeToString(verified.Sum(nil)) != digest {
		return "", errors.New("provider image changed after publication")
	}
	return digest, nil
}

func TestProviderImageCustodySeparatesLaterBuildWrites(t *testing.T) {
	directory := t.TempDir()
	sequence := 0
	property := func(original, later []byte) bool {
		sequence++
		source := filepath.Join(directory, fmt.Sprintf("build-%d", sequence))
		target := filepath.Join(directory, fmt.Sprintf("image-%d", sequence))
		if err := os.WriteFile(source, original, 0700); err != nil {
			t.Log(err)
			return false
		}
		if _, err := publishProviderImage(source, target); err != nil {
			t.Log(err)
			return false
		}
		if err := os.WriteFile(source, later, 0700); err != nil {
			t.Log(err)
			return false
		}
		captured, err := os.ReadFile(target)
		if err != nil {
			t.Log(err)
			return false
		}
		from, err := os.Stat(source)
		if err != nil {
			t.Log(err)
			return false
		}
		to, err := os.Stat(target)
		if err != nil {
			t.Log(err)
			return false
		}
		if _, err := publishProviderImage(source, target); err == nil {
			return false
		}
		return bytes.Equal(captured, original) && to.Mode().Perm() == 0500 && !os.SameFile(from, to)
	}
	if err := quick.Check(property, &quick.Config{MaxCount: 64, Rand: rand.New(rand.NewSource(293))}); err != nil {
		t.Fatal(err)
	}
}
