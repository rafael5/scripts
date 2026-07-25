package myproject

import "context"

// Version is the package version. Bump it on releases.
const Version = "0.1.0"

// Run is the top-level entry point invoked by cmd/myproject.
//
// Replace the body with the application's actual behavior. Accepting a
// context.Context as the first argument is the Go convention for any
// function that does I/O, blocks, or may need cancellation.
func Run(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	// TODO: implement.
	return nil
}
