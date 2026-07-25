import { strict as assert } from 'node:assert';
import { describe, it } from 'node:test';
import { greet } from './index.ts';

describe('greet', () => {
  // Table-driven test — the canonical Node + Go + Python idiom.
  // Add a row, get a new test case. Each row is one assertion's worth
  // of state, including the failure message context.
  const cases: ReadonlyArray<{
    readonly name: string;
    readonly input: Parameters<typeof greet>;
    readonly expected: string;
  }> = [
    {
      name: 'plain name',
      input: ['Ada'],
      expected: 'Hello, Ada!',
    },
    {
      name: 'name with title option',
      input: ['Lovelace', { title: 'Dr.' }],
      expected: 'Hello, Dr. Lovelace!',
    },
    {
      name: 'undefined title falls back to no prefix',
      input: ['Ada', {}],
      expected: 'Hello, Ada!',
    },
  ];

  for (const tc of cases) {
    it(tc.name, () => {
      assert.equal(greet(...tc.input), tc.expected);
    });
  }

  it('throws on empty name', () => {
    assert.throws(() => greet(''), /name must not be empty/);
  });
});
