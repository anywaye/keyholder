// Command keyholder is the registry-credential exchange.
//
// It trades a box-bound, purpose-bound registry.pull capability for ONE
// short-lived, pull-only dockerconfigjson for ghcr.io, and it holds the fleet's
// only registry source material. There is no database and no cache: the
// capability is box's row, and the credential is minted per request and never
// written anywhere.
//
// Usage:
//
//	REGISTRY_BOX_URL=https://box.svc.anywaye.test \
//	REGISTRY_GITHUB_APP_ID=123456 \
//	REGISTRY_GITHUB_APP_KEY_FILE=/var/run/secrets/anywaye/app-key.pem \
//	REGISTRY_GITHUB_INSTALLATION_ID=987654 \
//	keyholder
//
// The full environment contract is internal/registry/config.go, and it is the
// same contract the Ruby implementation read.
package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/anywaye/keyholder/internal/registry"
)

func main() {
	if err := run(); err != nil {
		// A startup failure is a startup failure: the process is no use to
		// anyone, so it says why and exits.
		log.Printf("keyholder: %v", err)
		os.Exit(1)
	}
}

func run() error {
	config, err := registry.LoadConfig()
	if err != nil {
		return err
	}

	// The authority is built once, here. A misconfigured one produces a minter
	// that refuses every request with `503 authority_error`, so the service
	// still serves — and never crashes at request time, and never mints a
	// half-built credential.
	minter, authorityErr := registry.NewTokenMinter(config)
	if authorityErr != nil {
		log.Printf("keyholder: the registry authority is misconfigured; every exchange will answer 503 authority_error: %v", authorityErr)
	}

	exchange := registry.NewExchange(registry.NewBox(config.BoxURL), minter, config.RegistryHost)
	app := registry.NewApp(exchange, logSink())

	server := &http.Server{
		Addr:              ":" + config.Port,
		Handler:           app.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		// No WriteTimeout on the response body: a box pulling a credential is
		// one small JSON document, but a slow client must not turn into a
		// truncated credential.
		IdleTimeout: 60 * time.Second,
	}

	// Graceful shutdown, so a rolling deploy does not cut an in-flight
	// exchange in half and leave a capability spent for nothing.
	shutdown := make(chan os.Signal, 1)
	signal.Notify(shutdown, syscall.SIGINT, syscall.SIGTERM)
	serverErrors := make(chan error, 1)
	go func() {
		log.Printf("keyholder: listening on %s", server.Addr)
		serverErrors <- server.ListenAndServe()
	}()

	select {
	case err := <-serverErrors:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-shutdown:
		log.Printf("keyholder: shutting down")
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := server.Shutdown(ctx); err != nil {
			return fmt.Errorf("shutdown: %w", err)
		}
		return nil
	}
}

// logSink is where the service writes its outcome lines: stdout, the way the
// Ruby original wrote them. It is the ONLY reference to stdout in this
// repository, and it is a destination for the log, not a print of a value —
// see the negative control in the credential-safety suite.
func logSink() *os.File { return os.Stdout }
