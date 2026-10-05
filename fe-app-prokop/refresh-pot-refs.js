// Refreshes only the "#:" source references of the .pot from
// locales/calls.json (run `yarn locales:extract-calls` first): entries,
// their order, the header and the translations stay as they are, unlike
// `yarn locales:actualize`, which rebuilds the files. Writes
// locales/prokop.pot and its copy in luci-app-prokop/po/templates, and
// refuses when anything but "#:" lines would change.
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const dir = path.dirname(fileURLToPath(import.meta.url));
const potPaths = [
  path.join(dir, 'locales/prokop.pot'),
  path.join(dir, '../luci-app-prokop/po/templates/prokop.pot'),
];
const calls = JSON.parse(
  fs.readFileSync(path.join(dir, 'locales/calls.json'), 'utf8'),
);
const places = new Map(calls.map((item) => [item.key, item.places]));

const isRef = (line) => line.startsWith('#:');
const withoutRefs = (text) =>
  text
    .split('\n')
    .filter((line) => !isRef(line))
    .join('\n');

function msgidOf(lines) {
  let msgid = null;
  let inMsgid = false;
  for (const line of lines) {
    if (line.startsWith('msgid ')) {
      msgid = JSON.parse(line.slice(6));
      inMsgid = true;
    } else if (inMsgid && line.startsWith('"')) {
      msgid += JSON.parse(line);
    } else {
      inMsgid = false;
    }
  }
  return msgid;
}

const source = fs.readFileSync(potPaths[0], 'utf8');
const unused = [];
const refreshed = source
  .split('\n\n')
  .map((block) => {
    const rest = block.split('\n').filter((line) => !isRef(line));
    const msgid = msgidOf(rest);
    if (!msgid) return block;
    if (!places.has(msgid)) unused.push(msgid);
    // References first, as generate-pot.js writes them.
    return [
      ...(places.get(msgid) || []).map((ref) => `#: ${ref}`),
      ...rest,
    ].join('\n');
  })
  .join('\n\n');

if (withoutRefs(refreshed) !== withoutRefs(source)) {
  console.error('❌ Refusing: more than the "#:" lines would change');
  process.exit(1);
}
for (const file of potPaths) fs.writeFileSync(file, refreshed, 'utf8');
for (const msgid of unused) console.warn(`⚠️ No call site: ${msgid}`);
console.log(`✅ Refreshed the references of ${potPaths.length} .pot files`);
