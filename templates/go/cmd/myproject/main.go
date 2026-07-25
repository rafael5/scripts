// Command myproject is the entry point for the myproject application.
//
// Keep this file thin: parse flags, set up logging and signal handling,
// then delegate to the internal package. Logic that is worth testing
// belongs in internal/myproject, not here.
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/rafael5/myproject/internal/myproject"
)

// version is overridden at build time:
//
//	go build -ldflags="-X main.version=$(git describe --tags --always --dirty)"
var version = "dev"

func main() {
	if err := run(os.Args[1:], os.Stderr); err != nil {
		slog.Error("fatal", "err", err)
		os.Exit(1)
	}
}

// run is split out from main so tests can drive it with a buffer in place
// of os.Stderr and assert on output without forking a process.
func run(args []string, logDest io.Writer) error {
	fs := flag.NewFlagSet("myproject", flag.ContinueOnError)
	showVersion := fs.Bool("version", false, "print version and exit")
	logJSON := fs.Bool("log-json", false, "emit JSON logs (default: text)")
	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("parse flags: %w", err)
	}

	if *showVersion {
		fmt.Println(version)
		return nil
	}

	var handler slog.Handler
	opts := &slog.HandlerOptions{Level: slog.LevelInfo}
	if *logJSON {
		handler = slog.NewJSONHandler(logDest, opts)
	} else {
		handler = slog.NewTextHandler(logDest, opts)
	}
	slog.SetDefault(slog.New(handler))

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	slog.Info("starting", "version", version)
	if err := myproject.Run(ctx); err != nil {
		return fmt.Errorf("run: %w", err)
	}
	slog.Info("done")
	return nil
}
