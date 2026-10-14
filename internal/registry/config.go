package registry

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
)

// The environment contract, unchanged from the Ruby original. Every name below
// is the same name, and every one of them is read exactly once at startup so a
// misconfigured service answers "authority_error" rather than a surprise at
// request time.
const (
	EnvBoxURL               = "REGISTRY_BOX_URL"
	EnvGitHubAppID          = "REGISTRY_GITHUB_APP_ID"
	EnvGitHubAppKeyFile     = "REGISTRY_GITHUB_APP_KEY_FILE"
	EnvGitHubAppKey         = "REGISTRY_GITHUB_APP_KEY"
	EnvGitHubInstallationID = "REGISTRY_GITHUB_INSTALLATION_ID"
	EnvGitHubAPIURL         = "REGISTRY_GITHUB_API_URL"
	EnvRegistryHost         = "REGISTRY_REGISTRY_HOST"
	EnvPort                 = "PORT"
)

// DefaultPort is 9292, the port the Ruby service listened on.
const DefaultPort = "9292"

// Config is the whole environment, resolved.
type Config struct {
	BoxURL               string
	GitHubAppID          string
	GitHubAppKeyFile     string
	GitHubAppKey         string
	GitHubInstallationID string
	GitHubAPIURL         string
	RegistryHost         string
	Port                 string
}

// LoadConfig reads the environment.
//
// REGISTRY_BOX_URL is required and a missing one is fatal at startup: a service
// that cannot reach box cannot spend the capability that is the whole reason it
// is called, so there is nothing honest to serve.
//
// The authority is treated differently on purpose. A missing or unparseable App
// key produces a minter that REFUSES (503 authority_error) rather than a
// process that will not boot: the operator gets an answer that names the
// failure, a box gets a refusal it can retry, and no half-built credential is
// ever minted. See NewTokenMinter.
func LoadConfig() (Config, error) {
	config := Config{
		BoxURL:               strings.TrimSpace(os.Getenv(EnvBoxURL)),
		GitHubAppID:          strings.TrimSpace(os.Getenv(EnvGitHubAppID)),
		GitHubAppKeyFile:     strings.TrimSpace(os.Getenv(EnvGitHubAppKeyFile)),
		GitHubAppKey:         os.Getenv(EnvGitHubAppKey),
		GitHubInstallationID: strings.TrimSpace(os.Getenv(EnvGitHubInstallationID)),
		GitHubAPIURL:         strings.TrimSpace(os.Getenv(EnvGitHubAPIURL)),
		RegistryHost:         strings.TrimSpace(os.Getenv(EnvRegistryHost)),
		Port:                 strings.TrimSpace(os.Getenv(EnvPort)),
	}
	if config.BoxURL == "" {
		return config, fmt.Errorf("%s is not set", EnvBoxURL)
	}
	if config.Port == "" {
		config.Port = DefaultPort
	}
	if _, err := strconv.Atoi(config.Port); err != nil {
		return config, fmt.Errorf("%s is not a port: %q", EnvPort, config.Port)
	}
	return config, nil
}

// AppKeyPEM is the App's private key, preferring a mounted file.
//
// A file is preferred because a value in an environment is readable by anything
// that can read /proc for the process; a mounted file is not, and the content is
// only ever in this process's memory. The environment variable is the fallback
// for a deployment that has no volume yet.
func (c Config) AppKeyPEM() (string, error) {
	if c.GitHubAppKeyFile != "" {
		pem, err := os.ReadFile(c.GitHubAppKeyFile)
		if err != nil {
			return "", fmt.Errorf("%s could not be read: %w", c.GitHubAppKeyFile, err)
		}
		return string(pem), nil
	}
	return c.GitHubAppKey, nil
}

// NewTokenMinter builds the credential minter from the environment.
//
// It never fails. A misconfigured authority returns a minter that refuses every
// mint with the misconfiguration that caused it, so the service serves
// `503 authority_error` at request time instead of dying at boot or — worse —
// minting from a half-built authority. The error is returned so the caller can
// say so at startup; it is not fatal.
func NewTokenMinter(config Config) (TokenMinter, error) {
	pem, err := config.AppKeyPEM()
	if err != nil {
		return unavailableAuthority{&AuthorityError{Kind: "misconfigured", Message: err.Error()}}, err
	}
	authority, err := NewAuthority(pem, config.GitHubAppID, config.GitHubInstallationID, config.GitHubAPIURL)
	if err != nil {
		var authorityErr *AuthorityError
		if ok := asAuthorityError(err, &authorityErr); ok {
			return unavailableAuthority{authorityErr}, authorityErr
		}
		return unavailableAuthority{&AuthorityError{Kind: "misconfigured", Message: err.Error()}}, err
	}
	return authority, nil
}

func asAuthorityError(err error, target **AuthorityError) bool {
	return errors.As(err, target)
}

// unavailableAuthority is the minter a misconfigured environment gets: it holds
// the reason and answers it, forever, to every request. It is what makes a
// missing App key a refusal rather than a crash.
type unavailableAuthority struct{ err *AuthorityError }

func (u unavailableAuthority) InstallationToken(_ context.Context) (*Minted, error) {
	return nil, u.err
}
