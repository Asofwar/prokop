import { buildSync } from 'esbuild';
import { fileURLToPath } from 'url';
import path from 'path';
import { describe, expect, it } from 'vitest';

// The LuCI modules besides main.js (tsup.config.ts) are bundled on their
// own: whatever they import is copied into them. A copy of a module with
// state (the store, the services, the router clock, the global styles)
// would be a second, empty instance next to main.js's, and a barrel import
// (icons/index.ts, helpers/index.ts) drags in every tab with its side
// effects. So each module may bundle only the files listed here; a new
// import has to be checked and added on purpose.
const root = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  '../../..',
);

const allowed = {
  'src/modules/componentProgress.ts': [
    'src/helpers/asText.ts',
    'src/helpers/isPageHidden.ts',
    'src/prokop/tabs/updates/componentProgress.ts',
  ],
  'src/modules/devicesView.ts': [
    'src/helpers/asText.ts',
    'src/helpers/prettyBytes.ts',
    'src/helpers/svgEl.ts',
    'src/icons/renderSearchIcon24.ts',
    'src/prokop/tabs/monitoring/devices.ts',
    'src/prokop/tabs/monitoring/devicesView.ts',
    'src/prokop/ui/status.ts',
    'src/prokop/ui/time.ts',
  ],
};

function bundledInputs(entry) {
  const result = buildSync({
    absWorkingDir: root,
    entryPoints: [entry],
    bundle: true,
    format: 'esm',
    minify: true,
    write: false,
    metafile: true,
    outfile: 'out.js',
  });
  const [output] = Object.values(result.metafile.outputs);
  return Object.entries(output.inputs)
    .filter(([file, input]) => file !== entry && input.bytesInOutput > 0)
    .map(([file]) => file)
    .sort();
}

describe('LuCI modules outside main.js', () => {
  for (const [entry, files] of Object.entries(allowed)) {
    it(`${entry} bundles only stateless files`, () => {
      expect(bundledInputs(entry)).toEqual(files);
    });
  }

  it('main.js no longer carries what the page modules render', () => {
    const inputs = bundledInputs('src/main.ts');
    expect(inputs).not.toContain(
      'src/prokop/tabs/updates/componentProgress.ts',
    );
    expect(inputs).not.toContain('src/prokop/tabs/monitoring/devicesView.ts');
  });
});
