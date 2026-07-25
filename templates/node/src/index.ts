/**
 * myproject — replace this comment with a one-line package summary.
 *
 * Library entry point. Re-export the public API; keep implementation
 * in sibling modules so consumers can tree-shake what they don't use.
 */

export interface GreetOptions {
  /** Honorific to prepend (e.g. "Dr."). Optional. */
  readonly title?: string;
}

/**
 * Build a greeting for a given name.
 *
 * The function is intentionally trivial — it exists to demonstrate the
 * test idiom (table-driven, `node:test`, type-safe options object) so
 * a new clone of this template has something green to start from.
 */
export function greet(name: string, options: GreetOptions = {}): string {
  if (name.length === 0) {
    throw new Error('greet: name must not be empty');
  }
  const prefix = options.title ? `${options.title} ` : '';
  return `Hello, ${prefix}${name}!`;
}
