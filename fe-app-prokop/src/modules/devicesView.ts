'use strict';
'require baseclass';

// LuCI module view.prokop.devices_view: the table of Monitoring → Devices
// (page/monitoring.js). Kept out of main.js, which every Prokop page loads.
// It must not import a module with state of main.js (the store, the
// services, the router clock): this bundle would get its own copy
// (src/modules/tests/bundles.test.js checks its inputs).

export { renderDevicesPanel } from '../prokop/tabs/monitoring/devicesView';
