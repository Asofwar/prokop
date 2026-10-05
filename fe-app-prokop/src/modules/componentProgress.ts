'use strict';
'require baseclass';

// LuCI module view.prokop.component_progress: the progress panels of the
// component cards (Settings → Components, updates.js). Kept out of main.js,
// which every Prokop page loads. It must not import a module with state of
// main.js (the store, the services, the router clock): this bundle would get
// its own copy (src/modules/tests/bundles.test.js checks its inputs).

export {
  patchComponentProgress,
  renderComponentProgress,
} from '../prokop/tabs/updates/componentProgress';
