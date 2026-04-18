package main

import (
	"bufio"
	"crypto/tls"
	"log"
	"os"
	"path/filepath"
	"strings"

	"github.com/pocketbase/pocketbase"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/plugins/jsvm"
	"github.com/pocketbase/pocketbase/plugins/migratecmd"
)

// findAndLoadEnv traverses up from dir looking for .env.<id> and loads it into the environment.
func findAndLoadEnv(dir, id string) {
	filename := ".env." + id
	for {
		path := filepath.Join(dir, filename)
		f, err := os.Open(path)
		if err == nil {
			defer f.Close()
			scanner := bufio.NewScanner(f)
			for scanner.Scan() {
				line := strings.TrimSpace(scanner.Text())
				if line == "" || strings.HasPrefix(line, "#") {
					continue
				}
				key, val, ok := strings.Cut(line, "=")
				if !ok {
					continue
				}
				os.Setenv(strings.TrimSpace(key), strings.TrimSpace(val))
			}
			return
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			log.Fatalf("Error: %s not found in %s or any ancestor directory", filename, dir)
		}
		dir = parent
	}
}

func main() {
	// Parse --env flag before PocketBase initializes so env vars are available to all hooks.
	envID := "local"
	for _, arg := range os.Args[1:] {
		if strings.HasPrefix(arg, "--env=") {
			envID = strings.TrimPrefix(arg, "--env=")
		}
	}

	exe, err := os.Executable()
	if err != nil {
		log.Fatal(err)
	}
	startDir := filepath.Dir(exe)
	// When running via `go run`, the executable is in a temp dir; use cwd instead.
	if strings.HasPrefix(exe, os.TempDir()) {
		startDir, _ = os.Getwd()
	}
	findAndLoadEnv(startDir, envID)

	app := pocketbase.New()

	// Enable automigrate only during development (go run)
	isGoRun := strings.HasPrefix(os.Args[0], os.TempDir())

	jsvm.MustRegister(app, jsvm.Config{
		MigrationsDir: "pb_migrations",
	})

	migratecmd.MustRegister(app, app.RootCmd, migratecmd.Config{
		TemplateLang: migratecmd.TemplateLangJS,
		Automigrate:  isGoRun,
	})

	// Load custom TLS cert/key if env vars are set
	certFile := os.Getenv("PB_TLS_CERT")
	keyFile := os.Getenv("PB_TLS_KEY")
	if certFile != "" && keyFile != "" {
		app.OnServe().BindFunc(func(e *core.ServeEvent) error {
			cert, err := tls.LoadX509KeyPair(certFile, keyFile)
			if err != nil {
				return err
			}
			e.Server.TLSConfig = &tls.Config{
				Certificates: []tls.Certificate{cert},
			}
			return e.Next()
		})
	}

	if err := app.Start(); err != nil {
		log.Fatal(err)
	}
}
