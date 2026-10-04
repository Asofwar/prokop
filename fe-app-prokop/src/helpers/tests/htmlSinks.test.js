// Guard for FE-1/FE-2/FE-3: LuCI's E(tag, attrs, children), ui.showModal and
// ui.addNotification parse a bare string as HTML. Only literals and _()
// translations may be passed that way; everything else goes through asText()
// in TypeScript or an array in the hand-written LuCI views.
import { parse } from '@babel/parser';
import traverseModule from '@babel/traverse';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import ts from 'typescript';
import { describe, expect, it } from 'vitest';

const ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  '../../..',
);
const VIEW_DIR = path.resolve(
  ROOT,
  '../luci-app-prokop/htdocs/luci-static/resources/view/prokop',
);

function htmlSinkArguments(call) {
  const callee = call.expression;
  if (ts.isIdentifier(callee) && callee.text === 'E') {
    return call.arguments.length >= 3 ? [call.arguments[2]] : [];
  }
  if (
    ts.isPropertyAccessExpression(callee) &&
    ts.isIdentifier(callee.expression) &&
    callee.expression.text === 'ui'
  ) {
    if (callee.name.text === 'showModal') return call.arguments.slice(0, 1);
    if (callee.name.text === 'addNotification')
      return call.arguments.slice(0, 2);
  }
  return [];
}

function mayBeString(type) {
  if (type.isUnion()) return type.types.some(mayBeString);
  return Boolean(
    type.flags &
      (ts.TypeFlags.StringLike |
        ts.TypeFlags.NumberLike |
        ts.TypeFlags.Any |
        ts.TypeFlags.Unknown),
  );
}

function isTrustedTsExpression(expression) {
  let value = expression;
  while (ts.isParenthesizedExpression(value) || ts.isAsExpression(value))
    value = value.expression;
  return (
    ts.isStringLiteral(value) ||
    ts.isNoSubstitutionTemplateLiteral(value) ||
    ts.isNumericLiteral(value) ||
    ts.isArrayLiteralExpression(value) ||
    (ts.isCallExpression(value) &&
      ts.isIdentifier(value.expression) &&
      value.expression.text === '_')
  );
}

function typeScriptViolations() {
  const config = ts.getParsedCommandLineOfConfigFile(
    path.join(ROOT, 'tsconfig.json'),
    {},
    { ...ts.sys, onUnRecoverableConfigFileDiagnostic: () => {} },
  );
  if (!config) throw new Error('tsconfig.json not readable');
  const program = ts.createProgram(config.fileNames, config.options);
  const checker = program.getTypeChecker();
  const violations = [];
  for (const file of program.getSourceFiles()) {
    const name = path.relative(ROOT, file.fileName);
    if (!name.startsWith('src/') || /\.test\.|\/tests\//.test(name)) continue;
    const visit = (node) => {
      if (ts.isCallExpression(node)) {
        for (const argument of htmlSinkArguments(node)) {
          if (isTrustedTsExpression(argument)) continue;
          if (!mayBeString(checker.getTypeAtLocation(argument))) continue;
          const { line } = file.getLineAndCharacterOfPosition(
            argument.getStart(file),
          );
          violations.push(`${name}:${line + 1} ${argument.getText(file)}`);
        }
      }
      ts.forEachChild(node, visit);
    };
    visit(file);
  }
  return violations;
}

// CommonJS default export: a function under vitest's interop, or { default }.
const traverse = traverseModule.default ?? traverseModule;

// Expressions in the hand-written views that are known to produce nodes or
// arrays, reviewed for FE-3.
const TRUSTED_JS_CALLS = new Set(['render']);

function isTrustedJsExpression(node) {
  if (!node) return true;
  switch (node.type) {
    case 'StringLiteral':
    case 'NumericLiteral':
    case 'NullLiteral':
    case 'ArrayExpression':
      return true;
    case 'TemplateLiteral':
      return node.expressions.length === 0;
    case 'ConditionalExpression':
      return (
        isTrustedJsExpression(node.consequent) &&
        isTrustedJsExpression(node.alternate)
      );
    case 'LogicalExpression':
      return (
        isTrustedJsExpression(node.left) && isTrustedJsExpression(node.right)
      );
    case 'CallExpression': {
      const callee = node.callee;
      if (callee.type === 'Identifier')
        return ['_', 'E', ...TRUSTED_JS_CALLS].includes(callee.name);
      // Array#map always yields an array.
      return (
        callee.type === 'MemberExpression' &&
        callee.property.type === 'Identifier' &&
        callee.property.name === 'map'
      );
    }
    default:
      return false;
  }
}

function javaScriptViolations() {
  const files = fs
    .readdirSync(VIEW_DIR, { recursive: true, encoding: 'utf8' })
    .filter((name) => name.endsWith('.js') && name !== 'main.js');
  const violations = [];
  for (const name of files) {
    const source = fs.readFileSync(path.join(VIEW_DIR, name), 'utf8');
    const ast = parse(source, {
      sourceType: 'script',
      allowReturnOutsideFunction: true,
    });
    const report = (node) =>
      violations.push(
        `${name}:${node.loc?.start.line} ${source.slice(node.start ?? 0, node.end ?? 0).slice(0, 80)}`,
      );
    traverse(ast, {
      CallExpression({ node }) {
        const callee = node.callee;
        let checked = [];
        if (callee.type === 'Identifier' && callee.name === 'E')
          checked = [node.arguments[2]];
        if (
          callee.type === 'MemberExpression' &&
          callee.object.type === 'Identifier' &&
          callee.property.type === 'Identifier'
        ) {
          const owner = callee.object.name;
          const method = callee.property.name;
          if (owner === 'dom' && (method === 'content' || method === 'append'))
            checked = [node.arguments[1]];
          if (owner === 'ui' && method === 'showModal')
            checked = [node.arguments[0]];
          if (owner === 'ui' && method === 'addNotification')
            checked = node.arguments.slice(0, 2);
        }
        for (const argument of checked)
          if (argument && !isTrustedJsExpression(argument)) report(argument);
      },
      AssignmentExpression({ node }) {
        const target = node.left;
        if (
          target.type === 'MemberExpression' &&
          target.property.type === 'Identifier' &&
          ['innerHTML', 'outerHTML'].includes(target.property.name) &&
          !isTrustedJsExpression(node.right) &&
          // Builds escaped markup (escapeHtml) for the annotated textarea.
          !(
            node.right.type === 'CallExpression' &&
            node.right.callee.type === 'Identifier' &&
            node.right.callee.name === 'renderAnnotatedTextareaOverlay'
          )
        )
          report(node.right);
      },
    });
  }
  return violations;
}

describe('LuCI HTML sinks', () => {
  it('TypeScript passes no non-literal string as HTML', () => {
    expect(typeScriptViolations()).toEqual([]);
  }, 120_000);

  it('hand-written LuCI views pass no non-literal string as HTML', () => {
    expect(javaScriptViolations()).toEqual([]);
  });
});
