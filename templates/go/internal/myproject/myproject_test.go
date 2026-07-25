package myproject

import (
	"context"
	"errors"
	"testing"
)

func TestVersion(t *testing.T) {
	t.Parallel()
	if Version == "" {
		t.Fatal("Version must not be empty")
	}
}

func TestRun_respectsCanceledContext(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	err := Run(ctx)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("Run with canceled ctx: got %v, want context.Canceled", err)
	}
}

// Table-driven test — copy this pattern for new tests.
// Each subtest is independent and runs in parallel.
func TestRun_table(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name    string
		ctxFn   func() (context.Context, context.CancelFunc)
		wantErr error
	}{
		{
			name:    "fresh context succeeds",
			ctxFn:   func() (context.Context, context.CancelFunc) { return context.WithCancel(context.Background()) },
			wantErr: nil,
		},
		{
			name: "canceled context returns context.Canceled",
			ctxFn: func() (context.Context, context.CancelFunc) {
				ctx, cancel := context.WithCancel(context.Background())
				cancel()
				return ctx, func() {}
			},
			wantErr: context.Canceled,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			ctx, cancel := tc.ctxFn()
			defer cancel()

			err := Run(ctx)
			if !errors.Is(err, tc.wantErr) {
				t.Errorf("Run: got err=%v, want=%v", err, tc.wantErr)
			}
		})
	}
}
