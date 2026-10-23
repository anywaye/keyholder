package registry

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The environment contract, unchanged from the Ruby original: the same
// variable names, the same defaults, the same preference for a mounted file.

func TestLoadConfigReadsTheDocumentedEnvironment(t *testing.T) {
	clearEnv(t)

	t.Setenv(EnvBoxURL, "https://box.svc.anywaye.test")
	t.Setenv(EnvGitHubAppID, "123456")
	t.Setenv(EnvGitHubInstallationID, "987654")
	t.Setenv(EnvGitHubAPIURL, "https://api.github.test/")
	t.Setenv(EnvRegistryHost, "ghcr.example.com")
	t.Setenv(EnvPort, "9292")

	config, err := LoadConfig()
	if err != nil {
		t.Fatalf("the documented environment should load: %v", err)
	}
	if config.BoxURL != "https://box.svc.anywaye.test" {
		t.Errorf("box url: got %q", config.BoxURL)
	}
	if config.GitHubAppID != "123456" || config.GitHubInstallationID != "987654" {
		t.Errorf("the App's ids: got %q / %q", config.GitHubAppID, config.GitHubInstallationID)
	}
	if config.GitHubAPIURL != "https://api.github.test/" {
		t.Errorf("api url is carried verbatim, the client trims it: got %q", config.GitHubAPIURL)
	}
	if config.RegistryHost != "ghcr.example.com" {
		t.Errorf("registry host: got %q", config.RegistryHost)
	}
	if config.Port != "9292" {
		t.Errorf("port: got %q", config.Port)
	}
}

func TestLoadConfigDefaultsThePortAndTheRegistryHost(t *testing.T) {
	clearEnv(t)
	t.Setenv(EnvBoxURL, "https://box.svc.anywaye.test")

	config, err := LoadConfig()
	if err != nil {
		t.Fatalf("a minimal environment should load: %v", err)
	}
	if config.Port != DefaultPort {
		t.Errorf("port: got %q, want the default %q", config.Port, DefaultPort)
	}
	if NewExchange(NewBox(config.BoxURL), unavailableAuthority{}, config.RegistryHost).registryHost() != DefaultRegistryHost {
		t.Errorf("registry host: got %q, want the default %q", config.RegistryHost, DefaultRegistryHost)
	}
}

func TestLoadConfigRefusesWithoutABoxURL(t *testing.T) {
	clearEnv(t)

	_, err := LoadConfig()
	if err == nil {
		t.Fatal("a service that cannot reach box cannot spend a capability: this must refuse")
	}
	if !strings.Contains(err.Error(), EnvBoxURL) {
		t.Errorf("the refusal should name the variable: %v", err)
	}
}

func TestLoadConfigRefusesAPortThatIsNotAPort(t *testing.T) {
	clearEnv(t)
	t.Setenv(EnvBoxURL, "https://box.svc.anywaye.test")
	t.Setenv(EnvPort, "nine thousand")

	if _, err := LoadConfig(); err == nil {
		t.Fatal("PORT=not-a-port must be a startup failure, not a listen error later")
	}
}

// The key arrives as a mounted file — a projected secret — or, failing that, as
// the PEM itself in the environment. The file is preferred: a value in an
// environment is readable by anything that can read /proc for the process.
func TestTheAppKeyPrefersAMountedFileOverTheEnvironment(t *testing.T) {
	clearEnv(t)
	keyPath := filepath.Join(t.TempDir(), "app-key.pem")
	if err := os.WriteFile(keyPath, []byte(testKeyPEM()), 0o600); err != nil {
		t.Fatalf("cannot write the key: %v", err)
	}

	config := Config{
		GitHubAppKeyFile: keyPath,
		GitHubAppKey:     "the-wrong-key-in-the-environment",
	}
	pem, err := config.AppKeyPEM()
	if err != nil {
		t.Fatalf("the mounted key should be read: %v", err)
	}
	if !strings.Contains(pem, "RSA PRIVATE KEY") {
		t.Errorf("the mounted file should win, got %q", pem)
	}

	// And an unreadable file is a refusal, not a fallback to the environment.
	if _, err := (Config{GitHubAppKeyFile: filepath.Join(t.TempDir(), "absent.pem")}).AppKeyPEM(); err == nil {
		t.Error("an unreadable key file must be an error")
	}
}

func TestNewTokenMinterRefusesRatherThanDyingOnAMisconfiguredAuthority(t *testing.T) {
	clearEnv(t)
	t.Setenv(EnvBoxURL, "https://box.svc.anywaye.test")

	config, err := LoadConfig()
	if err != nil {
		t.Fatalf("the environment should load: %v", err)
	}
	minter, err := NewTokenMinter(config)
	if err == nil {
		t.Fatal("a service with no App key must be told so at startup")
	}
	if _, ok := minter.(unavailableAuthority); !ok {
		t.Errorf("the minter should refuse every mint, got %T", minter)
	}
}

// clearEnv wipes the service's own variables so a test that intends a minimal
// environment is testing a minimal environment and not the developer's shell.
func clearEnv(t *testing.T) {
	t.Helper()
	for _, name := range []string{
		EnvBoxURL, EnvGitHubAppID, EnvGitHubAppKey, EnvGitHubAppKeyFile,
		EnvGitHubInstallationID, EnvGitHubAPIURL, EnvRegistryHost, EnvPort,
	} {
		t.Setenv(name, "")
		_ = os.Unsetenv(name)
	}
}
