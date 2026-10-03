// Set by prokop.js when the session cannot load the Prokop UCI package, i.e.
// the LuCI role only has the read-only Prokop ACL group.
let readonlyMode = false;

export function setReadonlyMode(value: boolean) {
  readonlyMode = value;
}

export function isReadonlyMode() {
  return readonlyMode;
}
