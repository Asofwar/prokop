"use strict";
// Loads a LuCI class file the way LuCI's own loader does (luci.js
// compileClass, the same in 24.10, 25.12 and master): the "require"
// directives are read with LuCI's scanner, which accepts them in either
// quote style, one per line or on one line, and stops at the first other
// string; then the source runs as the body of
// function(window, document, L, <aliases>) and a returned class is
// instantiated.
//
//   loadClass(source, resolve, { window, document, L })
// resolve(dep) returns the instance for a dependency ("baseclass",
// "view.prokop.main"). Returns { depends: [[dep, alias]...], instance }.

const requirematch = /^require[ \t]+(\S+)(?:[ \t]+as[ \t]+([a-zA-Z_]\S*))?$/;
const strictmatch = /^use[ \t]+strict$/;

function scanRequires(source) {
  const depends = [];
  for (let i = 0, off = -1, prev = -1, quote = -1, comment = -1, esc = false; i < source.length; i++) {
    const chr = source.charCodeAt(i);
    if (esc) {
      esc = false;
    } else if (comment != -1) {
      if ((comment == 47 && chr == 10) || (comment == 42 && prev == 42 && chr == 47)) comment = -1;
    } else if ((chr == 42 || chr == 47) && prev == 47) {
      comment = chr;
    } else if (chr == 92) {
      esc = true;
    } else if (chr == quote) {
      const s = source.substring(off, i);
      const m = requirematch.exec(s);
      if (m) {
        depends.push([m[1], m[2] || m[1].replace(/[^a-zA-Z0-9_]/g, "_")]);
      } else if (!strictmatch.exec(s)) {
        break;
      }
      off = -1;
      quote = -1;
    } else if (quote == -1 && (chr == 34 || chr == 39)) {
      off = i + 1;
      quote = chr;
    }
    prev = chr;
  }
  return depends;
}

function loadClass(source, resolve, env = {}) {
  const depends = scanRequires(source);
  const names = ["window", "document", "L", ...depends.map(([, alias]) => alias)];
  const values = [env.window, env.document, env.L, ...depends.map(([dep]) => resolve(dep))];
  // eslint-disable-next-line no-new-func
  const factory = new Function(...names, source);
  const exported = factory(...values);
  if (typeof exported !== "function") throw new Error("the class file returns no class");
  return { depends, instance: new exported() };
}

// LuCI's baseclass.extend, enough for a module: the properties land on the
// prototype of the returned class.
const baseclass = {
  extend(properties) {
    function Class() {}
    Object.assign(Class.prototype, properties);
    return Class;
  },
};

module.exports = { scanRequires, loadClass, baseclass };
