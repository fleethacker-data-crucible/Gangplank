import { test } from 'node:test';
import assert from 'node:assert/strict';
import { stripHtmlComments } from './gen-icons.mjs';

test('HTML comments are removed, including ones a single pass would re-form', () => {
  assert.equal(stripHtmlComments('<svg><!-- logo --><path d="M0"/></svg>'), '<svg><path d="M0"/></svg>');
  assert.equal(stripHtmlComments('<!-- a -->keep<!-- b -->'), 'keep');
  assert.equal(stripHtmlComments('before <!-- unterminated'), 'before ');
  assert.equal(stripHtmlComments('a<!--unclosed <path d="1"/>'), 'a');
  assert.equal(stripHtmlComments('<!<!--x-->-->'), '');

  const cases = [
    ['a<!-- x -->b', 'ab'],
    ['a<!-->b', 'ab'],
    ['a<!--->b', 'ab'],
    ['a<!-- x --!>b', 'ab'],
    ['a<!--unclosed <path d="1"/>', 'a'],
    ['<!<!---->-->x', 'x'],
    ['<<!-- -->!--<path/>-->y', 'y'],
    ['<path d="1"/>', '<path d="1"/>'],
  ];
  for (const [input, expected] of cases) assert.equal(stripHtmlComments(input), expected, input);
});
